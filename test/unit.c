/* Unit tests for the C core: the pieces that can be exercised without a
 * library, a terminal or a Lua state. Built and run by `make unit`. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "core/config.h"
#include "core/log.h"
#include "core/md5.h"
#include "core/util.h"
#include "db/query.h"
#include "doc/doc.h"
#include "match/fold.h"
#include "match/fuzzy.h"
#include "tui/tui.h"
#include "version.h"

static int checks, fails;

static void ok(int cond, const char *what) {
  checks++;
  if (!cond) {
    fails++;
    printf("FAIL  %s\n", what);
  }
}

static void eq(const char *got, const char *want, const char *what) {
  checks++;
  if (!got || strcmp(got, want)) {
    fails++;
    printf("FAIL  %s\n      got  %s\n      want %s\n", what, got ? got : "(null)", want);
  }
}

/* ---- version ---- */

static void test_version(void) {
  char built[64];
  snprintf(built, sizeof built, "%d.%d.%d%s", LULIBRE_VERSION_MAJOR, LULIBRE_VERSION_MINOR,
           LULIBRE_VERSION_PATCH, LULIBRE_VERSION_PRE);
  eq(LULIBRE_VERSION, built, "the version string is built from its parts");
  ok(LULIBRE_VERSION_PRE[0] == '\0' || LULIBRE_VERSION_PRE[0] == '-',
     "a pre-release tag starts with a dash");
  ok(!strchr(LULIBRE_VERSION, ' '), "the version has no spaces");
}

/* ---- strings ---- */

static void test_util(void) {
  sbuf b = SBUF_INIT;
  sb_puts(&b, "ab");
  sb_putc(&b, 'c');
  sb_printf(&b, "%d-%s", 7, "x");
  eq(b.s, "abc7-x", "sbuf appends");
  ok(b.len == 6, "sbuf length");
  char *taken = sb_take(&b);
  eq(taken, "abc7-x", "sb_take hands over the text");
  ok(b.s == NULL && b.len == 0, "and leaves the buffer empty");
  free(taken);
  char *empty = sb_take(&b);
  eq(empty, "", "sb_take of nothing is an empty string");
  free(empty);

  eq(path_ext("/a/b.c/file.PDF"), "PDF", "path_ext");
  eq(path_ext("/a/b.c/file"), "", "path_ext: a dot in a folder name is not an extension");
  eq(path_ext("noext"), "", "path_ext: none");
  char *home = path_expand("~/x");
  ok(home[0] == '/' && strlen(home) > 3 && !strcmp(home + strlen(home) - 2, "/x"), "path_expand ~");
  free(home);
  char *plain = path_expand("/abs/~x");
  eq(plain, "/abs/~x", "path_expand leaves other paths alone");
  free(plain);
  ok(hash_fnv1a("a") != hash_fnv1a("b") && hash_fnv1a("a") == hash_fnv1a("a"), "fnv1a");
  char *s = xasprintf("%s/%d", "p", 3);
  eq(s, "p/3", "xasprintf");
  free(s);
}

/* ---- md5 ---- */

static void md5_of(const char *data, size_t n, char hex[33]) {
  struct md5 m;
  unsigned char out[16];
  md5_init(&m);
  /* in two pieces, to cross the update boundary */
  md5_update(&m, data, n / 3);
  md5_update(&m, data + n / 3, n - n / 3);
  md5_final(&m, out);
  for (int i = 0; i < 16; i++) snprintf(hex + 2 * i, 3, "%02x", out[i]);
}

static void test_md5(void) {
  char hex[33];
  md5_of("", 0, hex);
  eq(hex, "d41d8cd98f00b204e9800998ecf8427e", "md5 of nothing");
  md5_of("abc", 3, hex);
  eq(hex, "900150983cd24fb0d6963f7d28e17f72", "md5 abc");
  md5_of("message digest", 14, hex);
  eq(hex, "f96b697d7cb7938d525a2f31aaf161d0", "md5 RFC 1321 vector");
  const char *eighty = "12345678901234567890123456789012345678901234567890123456789012345678901234567890";
  md5_of(eighty, 80, hex);
  eq(hex, "57edf4a22be3c955ac49da2e2107b67a", "md5 across a block boundary");
  char big[56 + 64 + 1]; /* 55, 56, 63, 64: the padding edge cases */
  memset(big, 'a', sizeof big);
  static const struct { size_t n; const char *want; } edge[] = {
    {55, "ef1772b6dff9a122358552954ad0df65"}, {56, "3b0c8ac703f828b04c6c197006d17218"},
    {63, "b06521f39153d618550606be297466d5"}, {64, "014842d480b571495a4a0363793f7367"},
  };
  for (size_t i = 0; i < sizeof edge / sizeof edge[0]; i++) {
    md5_of(big, edge[i].n, hex);
    eq(hex, edge[i].want, "md5 at a padding boundary");
  }

  char path[] = "/tmp/lulibre-unit-XXXXXX";
  int fd = mkstemp(path);
  ok(fd >= 0, "temporary file");
  if (fd >= 0) {
    ok(write(fd, "abc", 3) == 3, "write");
    close(fd);
    ok(md5_file(path, hex) == 0, "md5_file reads the file");
    eq(hex, "900150983cd24fb0d6963f7d28e17f72", "md5_file");
    unlink(path);
    ok(md5_file(path, hex) != 0, "md5_file reports a missing file");
  }
}

/* ---- folding and fuzzy matching ---- */

static void test_match(void) {
  sbuf f = SBUF_INIT;
  fold_utf8(&f, "Erd\xc5\x91s \xc3\x89tale", 13);
  eq(f.s, "erdos etale", "fold: case and accents");
  sb_free(&f);
  const char *math = "SL\xe2\x82\x82(\xe2\x84\xa4) \xf0\x9d\x94\xbd\xe2\x82\x9a X\xc2\xb3 \xe2\x84\x93";
  fold_utf8(&f, math, strlen(math));
  eq(f.s, "sl2(z) fp x3 l", "fold: mathematics in Unicode as its plain letters");
  sb_free(&f);
  ok(fuzzy_score("grot", "grothendieck") > FUZZY_NONE / 2, "fuzzy: a prefix matches");
  ok(fuzzy_score("xyz", "grothendieck") <= FUZZY_NONE / 2, "fuzzy: absent letters do not");
  ok(fuzzy_score("alg", "algebra") > fuzzy_score("alg", "a long gap"), "fuzzy: adjacent letters score higher");
  ok(fuzzy_score("ct", "category theory") > fuzzy_score("ct", "factor"), "fuzzy: word starts score higher");
}

/* ---- options ---- */

static void test_config(void) {
  struct config c;
  char *err = NULL;
  config_init(&c);
  ok(c.pages == 6 && c.layout_pages == 2 && c.mouse == 1, "defaults: numbers");
  eq(c.repair_links, "ask", "defaults: a policy");
  eq(c.write_via, "auto", "defaults: write_via");
  ok(config_set(&c, "pages", "9", &err) == 0 && c.pages == 9, "set a number");
  ok(config_set(&c, "pages", "nine", &err) != 0, "a number option rejects text");
  free(err);
  err = NULL;
  ok(config_set(&c, "repair_links", "auto", &err) == 0, "set a policy");
  ok(config_set(&c, "repair_links", "sometimes", &err) != 0, "a policy rejects other words");
  ok(err && strstr(err, "auto|ask|never"), "and says which are allowed");
  free(err);
  err = NULL;
  ok(config_set(&c, "repair_links", "", &err) != 0, "nor the empty string");
  free(err);
  err = NULL;
  ok(config_set(&c, "no_such_option", "1", &err) != 0, "unknown options are refused");
  free(err);
  err = NULL;
  ok(config_set(&c, "sync_dir", "~/in", &err) == 0 && c.sync_dir[0] == '/', "paths are expanded");
  char *dir = config_dir_path(&c);
  ok(dir[0] == '/' && strstr(dir, "lulibre"), "the configuration directory has a default");
  free(dir);
  ok(config_set(&c, "config_dir", "/somewhere/else", &err) == 0, "and can be set");
  dir = config_dir_path(&c);
  eq(dir, "/somewhere/else", "which is then the one in effect");
  free(dir);
  size_t n;
  const struct opt_def *o = config_opts(&n);
  int bad = 0;
  for (size_t i = 0; i < n; i++) {
    struct config d;
    config_init(&d);
    char *e = NULL;
    /* every default must be a value its own option accepts */
    if (o[i].type != OPT_PATH && config_set(&d, o[i].name, o[i].def, &e)) bad++;
    free(e);
    if (!o[i].help || !o[i].help[0]) bad++;
    config_free(&d);
  }
  ok(bad == 0, "every option has help and a default it accepts itself");
  ok(o[0].group != NULL, "the first option opens a group");
  config_free(&c);
}

/* ---- the filter language ---- */

static int compiles(const char *filter, int scope, const char *needle) {
  struct query q;
  char *err = NULL;
  if (query_compile_in(filter, scope, &q, &err)) {
    free(err);
    return 0;
  }
  int found = needle ? strstr(q.where, needle) != NULL : 1;
  query_free(&q);
  return found;
}

static void test_query(void) {
  struct query q;
  char *err = NULL;
  ok(query_compile("", &q, &err) == 0, "the empty filter compiles");
  ok(strstr(q.where, "b.id > 0") != NULL, "and means the library");
  ok(q.nparams == 0, "with nothing to bind");
  query_free(&q);
  ok(compiles("", SCOPE_SYNC, "b.id < 0"), "a default scope can be given");
  ok(compiles("in:sync", SCOPE_LIBRARY, "b.id < 0"), "in:sync overrides it");
  ok(compiles("in:library", SCOPE_SYNC, "b.id > 0"), "in:library overrides it");
  ok(!compiles("in:all", SCOPE_LIBRARY, "b.id > 0") && compiles("in:all", SCOPE_LIBRARY, NULL),
     "in:all has no scope");
  ok(!compiles("in:nowhere", SCOPE_LIBRARY, NULL), "an unknown scope is an error");

  ok(query_compile("author:=\"A B\" -tag:x year:1990-1999", &q, &err) == 0, "a compound filter compiles");
  ok(q.nparams == 2, "its text values are bound, its numbers inlined");
  eq(q.params[0], "A B", "a quoted value keeps its space");
  ok(strstr(q.where, "NOT ") && strstr(q.where, "BETWEEN 1990 AND 1999"), "negation and ranges");
  query_free(&q);
  ok(compiles("a or b", SCOPE_LIBRARY, ") OR ("), "or starts an alternative");
  ok(compiles("title:~^The", SCOPE_LIBRARY, "lmatch("), "~ is a Lua pattern");
  ok(compiles("sort:-year", SCOPE_LIBRARY, NULL), "sort");
  ok(compiles("is:dupe is:missing has:doi no:tags", SCOPE_LIBRARY, NULL), "is, has, no");

  ok(query_compile("nosuchfield:x", &q, &err) != 0 && err && strstr(err, "unknown field"),
     "an unknown field is reported");
  free(err);
  err = NULL;
  ok(query_compile("title:\"unterminated", &q, &err) != 0, "an open quote is reported");
  free(err);
  err = NULL;
  ok(query_compile("year:soon", &q, &err) != 0, "a bad number is reported");
  free(err);
  err = NULL;
  ok(query_compile("is:nothing", &q, &err) != 0 && err && strstr(err, "missing"), "is: lists what it knows");
  free(err);
}

/* ---- the log ---- */

struct seen {
  int n, errors;
  char last[64];
  uint64_t first_seq;
};

static void see(const struct log_entry *e, void *ud) {
  struct seen *s = ud;
  if (!s->n) s->first_seq = e->seq;
  s->n++;
  if (e->level == LOG_ERROR) s->errors++;
  snprintf(s->last, sizeof s->last, "%s", e->text);
}

static int pinged;
static void ping(void *ud) {
  pinged++;
}

static void test_log(void) {
  log_to_stderr(0);
  log_clear();
  uint64_t before = log_seq(), errors = log_errors();
  log_on_entry(ping, NULL);
  log_info("one %d", 1);
  log_warn("two");
  log_error("three\n");
  log_debug("four");
  log_on_entry(NULL, NULL);
  struct seen s = {0};
  log_each(see, &s);
  int want = LULIBRE_DEBUG ? 4 : 3;
  ok(s.n == want && pinged == want, "entries are kept, and announced");
  ok(log_seq() - before == (uint64_t)want, "and counted");
  ok(log_errors() - errors == 1 && s.errors == 1, "errors are counted apart");
  eq(s.last, LULIBRE_DEBUG ? "four" : "three", "a trailing newline is dropped; the trace only in a debug build");
  eq(log_level_name(LOG_WARN), "warn", "level names");

  char path[] = "/tmp/lulibre-log-XXXXXX";
  int fd = mkstemp(path);
  if (fd >= 0) {
    close(fd);
    ok(log_to_file(path) == 0, "a log file can be opened");
    log_error("to the file");
    log_to_file(NULL);
    FILE *f = fopen(path, "r");
    char line[256] = "";
    ok(f && fgets(line, sizeof line, f) && strstr(line, "error to the file"), "and receives entries");
    if (f) fclose(f);
    unlink(path);
  }
  ok(log_to_file("/no/such/dir/x.log") != 0, "an unwritable log file is reported");

  for (int i = 0; i < 5000; i++) log_info("fill %d", i);
  struct seen all = {0};
  log_each(see, &all);
  ok(all.n == 2000, "the log keeps the latest 2000 entries");
  eq(all.last, "fill 4999", "the newest is last");
  ok(all.first_seq == log_seq() - 1999, "and the oldest kept is the 2000th from the end");
  log_clear();
  struct seen none = {0};
  log_each(see, &none);
  ok(none.n == 0, "clearing empties it");
  log_to_stderr(1);
}

/* ---- the quality of a text layer ---- */

static void test_quality(void) {
  long n = 0;
  double g = 0;
  double prose = doc_text_quality("The quick brown fox jumps over the lazy dog, twice.", &n, &g);
  ok(prose > 0.6 && g == 0, "prose reads as text");
  double frag = doc_text_quality("T h e q u i c k b r o w n f o x", &n, &g);
  ok(frag < 0.1, "one-letter fragments do not");
  /* a font with no map to Unicode: U+FFFD among the words */
  doc_text_quality("The \xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd quick brown fox jumps over the lazy dog", &n, &g);
  ok(g > 0.05, "unreadable characters are counted");
  doc_text_quality("\xee\x80\x81\xee\x80\x82\xee\x80\x83\xee\x80\x84 word", &n, &g);
  ok(g >= 0.5, "a page of private-use glyphs is no text");
  /* dots leading to a page number: one run counts once */
  doc_text_quality("Introduction \xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd 1 and the rest of a long table of contents line", &n, &g);
  ok(g < 0.05, "a run of them counts once");
}

/* ---- reentrancy: each hint or message has its own buffer ---- */

static void test_reentrant(void) {
  tui_setup();
  static const char *cmds[] = {"console", "filter", "sync add", "sync move", "sync drop", "source library"};
  char alone[6][KEY_HINT_MAX];
  for (int i = 0; i < 6; i++) snprintf(alone[i], sizeof alone[i], "%s", key_hint(cmds[i]));
  char together[6 * KEY_HINT_MAX + 8];
  /* more hints in one call than the old ring of four buffers held */
  snprintf(together, sizeof together, "%s|%s|%s|%s|%s|%s", key_hint(cmds[0]), key_hint(cmds[1]), key_hint(cmds[2]),
           key_hint(cmds[3]), key_hint(cmds[4]), key_hint(cmds[5]));
  char want[sizeof together];
  snprintf(want, sizeof want, "%s|%s|%s|%s|%s|%s", alone[0], alone[1], alone[2], alone[3], alone[4], alone[5]);
  eq(together, want, "key_hint: six hints in one statement are six hints");
  eq(errstr(ENOENT), "No such file or directory", "errstr: the message for an error number");
  char two[160];
  snprintf(two, sizeof two, "%s / %s", errstr(ENOENT), errstr(EACCES));
  eq(two, "No such file or directory / Permission denied", "errstr: two in one statement");
}

/* while typing: Ctrl or Alt with an arrow moves a word, as b and w */
static void test_words(void) {
  ctx_defaults();
  struct lineedit le = {0};
  uint32_t k[KEYSEQ_MAX];
  le_set(&le, "foo.bar  baz");
  size_t back[4], fwd[4];
  key_parse("<C-Left>", k);
  for (int i = 0; i < 4; i++) {
    le_key(&le, k[0], NULL);
    back[i] = le.cur;
  }
  ok(back[0] == 9 && back[1] == 4 && back[2] == 3 && back[3] == 0, "C-Left: to each word's start, punctuation a word of its own");
  key_parse("<C-Right>", k);
  for (int i = 0; i < 4; i++) {
    le_key(&le, k[0], NULL);
    fwd[i] = le.cur;
  }
  ok(fwd[0] == 3 && fwd[1] == 4 && fwd[2] == 9 && fwd[3] == 12, "C-Right: to the next word's start, past blanks, then the end");
  le.cur = 0;
  key_parse("<M-Right>", k);
  le_key(&le, k[0], NULL);
  ok(le.cur == 3, "and with Alt the same");
  le_set(&le, "\xc3\xa9t\xc3\xa9 x");
  le.cur = 0;
  key_parse("<C-Right>", k);
  le_key(&le, k[0], NULL);
  ok(le.cur == 6, "an accented letter is part of the word");
  le_free(&le);
  ctx_free();
}

static void test_lines(void) {
  size_t off[4], len[4];
  const char *s = "aaa bbb ccc";
  int n = dr_lines(s, 8, off, len, 4);
  ok(n == 2 && len[0] == 7 && off[1] == 8 && len[1] == 3, "lines break at a space, which is not shown");
  s = "one\ntwo\n";
  n = dr_lines(s, 20, off, len, 4);
  ok(n == 2 && len[0] == 3 && off[1] == 4 && len[1] == 3, "at the text's own newlines, none for one at the end");
  s = "a b c d e f";
  n = dr_lines(s, 1, off, len, 4);
  ok(n == 6 && off[3] == 6, "the count is of every line, past the ones filled in");
  n = dr_lines("question [y/N] ", 40, off, len, 4);
  ok(n == 1 && len[0] == 15, "the last line keeps its space, where the answer is typed");
}

int main(void) {
  test_version();
  test_util();
  test_md5();
  test_match();
  test_config();
  test_query();
  test_log();
  test_quality();
  test_reentrant();
  test_words();
  test_lines();
  printf("C unit tests: %d checks, %d failed\n", checks, fails);
  return fails ? 1 : 0;
}
