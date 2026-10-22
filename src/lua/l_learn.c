/* Phrases: the two- and three-word sequences of a text, and how many texts
 * each turns up in. This is the counting behind learn.lua, which finds the
 * phrases that tell one subject from the others; it is in C because a
 * library's first pages hold millions of them.
 *
 *   lulibre.phrases(text)        the distinct phrases of a text, as a list
 *   local c = lulibre.counter()  a counter of phrases over many texts
 *   c:add(text)                  count each distinct phrase of the text once
 *   c:prune(min [, max])         forget phrases in fewer than min texts, or
 *                                more than max; returns how many are left
 *   c:of(text)                   the distinct phrases of a text that the
 *                                counter still knows, as a list
 *   c:count(phrase)              how many texts held it
 *   c:size()  c:texts()          phrases known; texts added
 *   c:close()                    empty it, and free its memory now: Lua
 *                                does not see that memory, so the collector
 *                                is in no hurry (also `local c <close> = ...`)
 *
 * The same counter counts whole lines instead, which is how text that many
 * books share word for word (a publisher's imprint, a series list, a
 * journal's notice) is found and set aside before any phrase is counted:
 *
 *   c:add_lines(text [, same])   count each distinct line of the text once;
 *                                same: this is another copy of the text
 *                                last added, not a different one
 *   c:strip(text, min)           the text without the lines that at least
 *                                min texts hold
 *
 * Lines are compared with case, accents and figures set aside, and only
 * lines of some length count: a short line says too little to be judged.
 *
 * A phrase is two or three words in a row within one clause: lower case,
 * accents folded away, no figures, not broken by punctuation, and neither
 * beginning nor ending with a function word ("ring of integers" is one;
 * "of the ring" is not), and holding no word of the publishing trade ("all
 * rights reserved", "springer verlag"). A word broken over a line end is
 * joined. */
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "core/util.h"
#include "lua/lapi.h"
#include "match/fold.h"

#define MT "lulibre.counter"
#define MAX_PHRASE 72
#define MAX_WORD 32

static const char *const STOP[] = {
  "a", "about", "above", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be", "been",
  "before", "being", "below", "between", "both", "but", "by", "can", "cannot", "could", "did", "do", "does", "each",
  "either", "et", "al", "etc", "for", "from", "further", "had", "has", "have", "he", "hence", "her", "here", "his",
  "how", "however", "i", "ie", "eg", "if", "in", "into", "is", "it", "its", "let", "may", "might", "more", "most",
  "much", "must", "my", "no", "nor", "not", "now", "of", "on", "one", "only", "or", "other", "our", "out", "over",
  "per", "same", "say", "see", "shall", "she", "should", "since", "so", "some", "such", "than", "that", "the",
  "their", "them", "then", "there", "therefore", "these", "they", "this", "those", "through", "thus", "to", "too",
  "two", "under", "until", "up", "upon", "us", "very", "via", "was", "we", "were", "what", "when", "where",
  "whether", "which", "while", "who", "whose", "why", "will", "with", "within", "without", "would", "yet", "you",
  "your", "de", "la", "le", "der", "die", "und", "des", "les", "du", "von", "van", "el", "en",
  /* a page's furniture, where it would begin or end a phrase */
  "page", "pages", "vol", "pp", "ed", "eds", "university", "press", "department",
};

/* Words of the publishing trade and of the web. A phrase with one of these
 * anywhere in it says who printed the book or where it was fetched from, not
 * what it is about. The list is kept to words with no other use: "series",
 * "number", "law", "distribution", "abstract" and "proof" look like trade
 * words too and are half of power series, number field, reciprocity law,
 * probability distribution, abstract algebra and proof theory. What gets
 * past this is dealt with by learn.lua, which knows more (lines books share,
 * imprint pages, the phrases titles are made of). */
static const char *const TRADE[] = {
  "copyright", "copyrights", "isbn", "issn", "reserved", "publisher", "publishers", "publishing", "trademark",
  "trademarks", "liable", "imprint", "permission", "permissions", "reproduced", "reprinted", "printed",
  "springer", "verlag", "elsevier", "apress", "wiley", "birkhauser", "preprint", "arxiv", "download",
  "downloaded", "website", "license", "licensed", "licence", "email", "fax", "http", "https", "www", "com",
  "org", "edu", "doi", "pdf",
};

static int is_trade(const char *w, size_t n) {
  for (size_t i = 0; i < ARRAY_LEN(TRADE); i++)
    if (strlen(TRADE[i]) == n && !memcmp(TRADE[i], w, n)) return 1;
  return 0;
}

static int is_stop(const char *w, size_t n) {
  for (size_t i = 0; i < ARRAY_LEN(STOP); i++)
    if (strlen(STOP[i]) == n && !memcmp(STOP[i], w, n)) return 1;
  return 0;
}

struct word {
  const char *s;
  size_t n;
  int stop, trade;
};

typedef void phrase_fn(const char *phrase, size_t len, void *ud);

/* the phrases of one clause's words */
static void clause(const struct word *w, int n, phrase_fn *fn, void *ud) {
  char buf[MAX_PHRASE + 1];
  for (int i = 0; i < n; i++) {
    if (w[i].stop) continue;
    for (int k = 2; k <= 3 && i + k <= n; k++) {
      if (w[i + k - 1].stop) continue;
      size_t len = 0;
      int fits = 1;
      for (int j = 0; j < k; j++) fits = fits && !w[i + j].trade;
      for (int j = 0; j < k && fits; j++) {
        if (len + w[i + j].n + 1 > MAX_PHRASE) fits = 0;
        else {
          if (j) buf[len++] = ' ';
          memcpy(buf + len, w[i + j].s, w[i + j].n);
          len += w[i + j].n;
        }
      }
      if (fits) fn(buf, len, ud);
    }
  }
}

/* After folding, the letters of Latin-script words are a to z. Whatever is
 * left above ASCII is a symbol (a dot, an operator) or another script, and
 * ends the clause as punctuation does. */
static int is_letter(unsigned char c) {
  return c >= 'a' && c <= 'z';
}

/* Call fn for every phrase of the text (with repeats). */
static void phrases(const char *text, size_t n, phrase_fn *fn, void *ud) {
  sbuf f = SBUF_INIT, joined = SBUF_INIT;
  fold_utf8(&f, text, n);
  /* a word broken over a line end is one word */
  for (size_t i = 0; i < f.len; i++) {
    if (f.s[i] == '-' && i > 0 && is_letter((unsigned char)f.s[i - 1])) {
      size_t j = i + 1;
      while (j < f.len && (f.s[j] == ' ' || f.s[j] == '\r')) j++;
      if (j < f.len && f.s[j] == '\n') {
        j++;
        while (j < f.len && (f.s[j] == ' ' || f.s[j] == '\t')) j++;
        if (j < f.len && is_letter((unsigned char)f.s[j])) {
          i = j - 1;
          continue;
        }
      }
    }
    sb_putc(&joined, f.s[i]);
  }
  sb_free(&f);
  const char *s = joined.s ? joined.s : "";
  size_t len = joined.len;
  struct word w[64];
  int nw = 0;
  for (size_t i = 0; i <= len;) {
    unsigned char c = i < len ? (unsigned char)s[i] : '.';
    if (is_letter(c)) {
      size_t start = i;
      int bad = 0;
      while (i < len) {
        unsigned char d = (unsigned char)s[i];
        if (is_letter(d)) i++;
        else if ((d == '-' || d == '\'') && i + 1 < len && is_letter((unsigned char)s[i + 1])) i++;
        else if (d >= '0' && d <= '9') { bad = 1; i++; } /* x2, h1n1: not a word */
        else break;
      }
      size_t wl = i - start;
      if (bad || wl < 2 || wl > MAX_WORD) { /* ends the clause, as punctuation does */
        clause(w, nw, fn, ud);
        nw = 0;
      } else {
        if (nw == 64) { /* a clause this long: keep sliding */
          clause(w, nw, fn, ud);
          memmove(w, w + 62, 2 * sizeof *w);
          nw = 2;
        }
        w[nw++] = (struct word){s + start, wl, is_stop(s + start, wl), is_trade(s + start, wl)};
      }
    } else if (c == ' ' || c == '\n' || c == '\t' || c == '\r' || c == '\f') {
      i++;
    } else { /* punctuation, figures, symbols */
      clause(w, nw, fn, ud);
      nw = 0;
      i++;
    }
  }
  sb_free(&joined);
}

/* ---- the counter: an open-addressing table of phrase -> texts ---- */

struct entry {
  char *key;
  uint32_t hash, count, stamp;
};

struct counter {
  struct entry *e;
  size_t cap, n;
  uint32_t texts;
};

static uint32_t hash_of(const char *s, size_t n) {
  uint32_t h = 2166136261u;
  for (size_t i = 0; i < n; i++) h = (h ^ (unsigned char)s[i]) * 16777619u;
  return h ? h : 1;
}

static struct entry *find(struct counter *c, const char *s, size_t n, uint32_t h) {
  if (!c->cap) return NULL;
  for (size_t i = h & (c->cap - 1);; i = (i + 1) & (c->cap - 1)) {
    struct entry *e = &c->e[i];
    if (!e->key) return e; /* the free slot it would go in */
    if (e->hash == h && strlen(e->key) == n && !memcmp(e->key, s, n)) return e;
  }
}

static void grow(struct counter *c) {
  struct entry *old = c->e;
  size_t ocap = c->cap;
  c->cap = ocap ? ocap * 2 : 1 << 16;
  c->e = xcalloc(c->cap, sizeof *c->e);
  for (size_t i = 0; i < ocap; i++)
    if (old[i].key) {
      size_t j = old[i].hash & (c->cap - 1);
      while (c->e[j].key) j = (j + 1) & (c->cap - 1);
      c->e[j] = old[i];
    }
  free(old);
}

static void count_one(const char *s, size_t n, void *ud) {
  struct counter *c = ud;
  if ((c->n + 1) * 10 >= c->cap * 7) grow(c);
  uint32_t h = hash_of(s, n);
  struct entry *e = find(c, s, n, h);
  if (!e->key) {
    e->key = xstrndup(s, n);
    e->hash = h;
    c->n++;
  }
  if (e->stamp != c->texts) { /* once for each text, however often it says it */
    e->stamp = c->texts;
    e->count++;
  }
}

static void counter_clear(struct counter *c) {
  for (size_t i = 0; i < c->cap; i++) free(c->e[i].key);
  free(c->e);
  memset(c, 0, sizeof *c);
}

static int c_add(lua_State *L) {
  struct counter *c = luaL_checkudata(L, 1, MT);
  size_t n;
  const char *text = luaL_checklstring(L, 2, &n);
  c->texts++;
  phrases(text, n, count_one, c);
  return 0;
}

/* A line as it is compared: folded, figures all alike, spaces single. Returns
 * its length in buf, 0 when the line is too short to be judged. */
static size_t line_key(const char *s, size_t n, char *buf, size_t cap) {
  sbuf f = SBUF_INIT;
  fold_utf8(&f, s, n);
  size_t len = 0, words = 0;
  int gap = 1;
  for (size_t i = 0; i < f.len && len + 1 < cap; i++) {
    unsigned char c = (unsigned char)f.s[i];
    if (c == ' ' || c == '\t' || c == '\r') {
      gap = 1;
      continue;
    }
    if (gap) {
      if (len) buf[len++] = ' ';
      words++;
      gap = 0;
    }
    buf[len++] = c >= '0' && c <= '9' ? '#' : (char)c;
  }
  sb_free(&f);
  return len >= 24 && words >= 3 ? len : 0;
}

static int c_add_lines(lua_State *L) {
  struct counter *c = luaL_checkudata(L, 1, MT);
  size_t n;
  const char *text = luaL_checklstring(L, 2, &n);
  if (!lua_toboolean(L, 3) || c->texts == 0) c->texts++;
  char key[200];
  for (size_t i = 0; i < n;) {
    const char *nl = memchr(text + i, '\n', n - i);
    size_t len = nl ? (size_t)(nl - (text + i)) : n - i;
    size_t kl = line_key(text + i, len, key, sizeof key);
    if (kl) count_one(key, kl, c);
    i += len + 1;
  }
  return 0;
}

static int c_strip(lua_State *L) {
  struct counter *c = luaL_checkudata(L, 1, MT);
  size_t n;
  const char *text = luaL_checklstring(L, 2, &n);
  uint32_t min = (uint32_t)luaL_checkinteger(L, 3);
  sbuf out = SBUF_INIT;
  char key[200];
  for (size_t i = 0; i < n;) {
    const char *nl = memchr(text + i, '\n', n - i);
    size_t len = nl ? (size_t)(nl - (text + i)) : n - i;
    size_t kl = line_key(text + i, len, key, sizeof key);
    struct entry *e = kl ? find(c, key, kl, hash_of(key, kl)) : NULL;
    if (e && e->key && e->count >= min) {
      sb_puts(&out, ".\n"); /* what stood on either side is not one clause */
    } else {
      sb_putn(&out, text + i, len);
      sb_putc(&out, '\n');
    }
    i += len + 1;
  }
  lua_pushlstring(L, out.s ? out.s : "", out.len);
  sb_free(&out);
  return 1;
}

static int c_prune(lua_State *L) {
  struct counter *c = luaL_checkudata(L, 1, MT);
  uint32_t min = (uint32_t)luaL_optinteger(L, 2, 2);
  uint32_t max = (uint32_t)luaL_optinteger(L, 3, 0x7fffffff);
  struct counter kept = {0};
  kept.texts = c->texts;
  for (size_t i = 0; i < c->cap; i++) {
    struct entry *e = &c->e[i];
    if (!e->key) continue;
    if (e->count < min || e->count > max) {
      free(e->key);
    } else {
      if ((kept.n + 1) * 10 >= kept.cap * 7) grow(&kept);
      size_t j = e->hash & (kept.cap - 1);
      while (kept.e[j].key) j = (j + 1) & (kept.cap - 1);
      kept.e[j] = *e;
      kept.e[j].stamp = 0;
      kept.n++;
    }
  }
  free(c->e);
  *c = kept;
  lua_pushinteger(L, (lua_Integer)c->n);
  return 1;
}

/* collecting the distinct phrases of one text into the Lua table on top */
struct collect {
  lua_State *L;
  struct counter *known; /* only these, when set */
  int n;
};

static void collect_one(const char *s, size_t n, void *ud) {
  struct collect *k = ud;
  if (k->known) {
    struct entry *e = find(k->known, s, n, hash_of(s, n));
    if (!e || !e->key) return;
  }
  /* on the stack: seen, list */
  lua_pushlstring(k->L, s, n);
  lua_pushvalue(k->L, -1);
  if (lua_rawget(k->L, -4) == LUA_TNIL) {
    lua_pop(k->L, 1);
    lua_pushvalue(k->L, -1);
    lua_pushboolean(k->L, 1);
    lua_rawset(k->L, -5);
    lua_rawseti(k->L, -2, ++k->n);
  } else {
    lua_pop(k->L, 2);
  }
}

static int push_phrases(lua_State *L, int text_idx, struct counter *known) {
  size_t n;
  const char *text = luaL_checklstring(L, text_idx, &n);
  luaL_checkstack(L, 8, "phrases");
  lua_newtable(L); /* seen: phrase -> true */
  lua_newtable(L); /* the list, which is what is returned */
  struct collect k = {L, known, 0};
  phrases(text, n, collect_one, &k); /* collect_one leaves the two tables as it found them */
  lua_remove(L, -2);
  return 1;
}

static int c_of(lua_State *L) {
  struct counter *c = luaL_checkudata(L, 1, MT);
  return push_phrases(L, 2, c);
}

static int c_count(lua_State *L) {
  struct counter *c = luaL_checkudata(L, 1, MT);
  size_t n;
  const char *s = luaL_checklstring(L, 2, &n);
  struct entry *e = find(c, s, n, hash_of(s, n));
  lua_pushinteger(L, e && e->key ? e->count : 0);
  return 1;
}

static int c_size(lua_State *L) {
  struct counter *c = luaL_checkudata(L, 1, MT);
  lua_pushinteger(L, (lua_Integer)c->n);
  return 1;
}

static int c_texts(lua_State *L) {
  struct counter *c = luaL_checkudata(L, 1, MT);
  lua_pushinteger(L, c->texts);
  return 1;
}

static int c_close(lua_State *L) {
  counter_clear(luaL_checkudata(L, 1, MT));
  return 0;
}

static int l_counter(lua_State *L) {
  struct counter *c = lua_newuserdatauv(L, sizeof *c, 0);
  memset(c, 0, sizeof *c);
  luaL_setmetatable(L, MT);
  return 1;
}

static int l_phrases(lua_State *L) {
  return push_phrases(L, 1, NULL);
}

void l_learn_open(lua_State *L) {
  static const luaL_Reg methods[] = {
    {"add", c_add},   {"prune", c_prune}, {"of", c_of},     {"count", c_count},
    {"size", c_size}, {"texts", c_texts}, {"add_lines", c_add_lines}, {"strip", c_strip},
    {"close", c_close}, {"__close", c_close}, {"__gc", c_close}, {NULL, NULL},
  };
  luaL_newmetatable(L, MT);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, methods, 0);
  lua_pop(L, 1);
  lua_pushcfunction(L, l_counter);
  lua_setfield(L, -2, "counter");
  lua_pushcfunction(L, l_phrases);
  lua_setfield(L, -2, "phrases");
}
