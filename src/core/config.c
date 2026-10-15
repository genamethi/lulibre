#include "core/config.h"

#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include "core/util.h"

#define OPT(name, type, def, choices, help, group) \
  {#name, type, offsetof(struct config, name), def, choices, help, group}
#define POLICY "auto|ask|never"

static const struct opt_def opts[] = {
  OPT(library, OPT_PATH, "", NULL, "calibre library directory", "The library"),
  OPT(server, OPT_STR, "", NULL,
      "calibre content server URL; changes go through it (http://127.0.0.1:8080)", NULL),
  OPT(user, OPT_STR, "", NULL, "content server user", NULL),
  OPT(password_file, OPT_PATH, "", NULL, "file holding the content server password", NULL),
  OPT(write_via, OPT_STR, "auto", "auto|server|direct",
      "how changes reach calibre: through the content server, straight to the library folder "
      "(calibre allows that only while no calibre program has the library open), or auto: the "
      "server when it answers, else directly",
      NULL),

  OPT(pages, OPT_INT, "6", NULL, "first N pages of each file to index as text", "The index"),
  OPT(layout_pages, OPT_INT, "2", NULL, "of those, pages kept as lines tagged with font size", NULL),
  OPT(jobs, OPT_INT, "0", NULL, "worker threads (0 = one per core)", NULL),
  OPT(auto_index, OPT_STR, "auto", POLICY,
      "index new or changed files when the interface starts (ask: only say how many are waiting)",
      NULL),
  OPT(ocr, OPT_STR, "never", "never|auto|always",
      "read page images with tesseract after indexing: never, auto (files with no text), always",
      NULL),
  OPT(ocr_pages, OPT_INT, "3", NULL, "pages per file the OCR pass reads", NULL),
  OPT(ocr_lang, OPT_STR, "eng", NULL, "tesseract language(s), e.g. eng or eng+fra", NULL),
  OPT(ocr_write, OPT_STR, "off", "off|replace|keep",
      "whether OCR also writes the text it read into the PDF itself (with ocrmypdf), so that other "
      "programs can search it: off leaves the file alone, replace puts the new PDF in its place, keep "
      "does so and keeps the old one in ocr_originals",
      NULL),
  OPT(ocr_originals, OPT_PATH, "", NULL,
      "where ocr_write = keep puts the PDFs it wrote over: a folder outside the library, so calibre "
      "never sees two copies (default: ocr-originals/ under the XDG data dir)",
      NULL),
  OPT(text_fallback, OPT_STR, "auto", "off|auto",
      "pages whose text comes out garbled (a font with no map to letters) are read again with "
      "poppler's pdftotext, when it is installed, and the better reading is kept (:run reread)",
      NULL),

  OPT(write_jobs, OPT_INT, "6", NULL, "calibredb processes at once when writing",
      "Changing the library"),
  OPT(repair_links, OPT_STR, "ask", POLICY,
      "after a change renames a book's folder, fix the symlinks in your own folders that "
      "pointed into it",
      NULL),
  OPT(carry_metadata, OPT_STR, "auto", POLICY,
      "before a duplicate or orphan record is removed, keep what only it knew as proposals",
      NULL),

  OPT(propose_over, OPT_STR, "sure", "gaps|sure|any",
      "what :propose does about a field that already has a value: gaps leaves it alone; sure "
      "proposes when the file is confident (0.8 or more) and says something different; any "
      "proposes whenever the file's best candidate differs",
      NULL),
  OPT(one_word_titles, OPT_STR, "check", "check|ok|junk",
      "a title of one word: check takes a plain capitalised word (Algebra, Topology) for a title "
      "and what is left of a file name (infinite, E807en) for junk; ok takes any single word for "
      "a title; junk takes none",
      NULL),
  OPT(good_titles, OPT_STR, "", NULL,
      "titles, separated by commas, that are titles whatever they look like: \"Notes, Preface, 1984\"",
      NULL),
  OPT(never_titles, OPT_STR, "", NULL,
      "words and phrases, separated by commas, that mark a title as not a title (added to the "
      "built-in ones such as untitled, or a file name): \"scan, downloaded from\"",
      NULL),
  OPT(never_authors, OPT_STR, "", NULL,
      "words and phrases, separated by commas, that are never proposed as an author (added to the "
      "built-in ones such as professor emeritus): \"visiting scholar, lecture notes\"",
      NULL),
  OPT(refs_pages, OPT_INT, "14", NULL,
      "how many of a file's last pages :refs reads when looking for its bibliography", NULL),
  OPT(subject_learned, OPT_STR, "suggest", "off|suggest|propose",
      "what a subject worked out from the learned phrases is used for: suggest offers it in the "
      "edit form, propose also makes it a proposal when :propose runs, off neither",
      NULL),
  OPT(subject_terms, OPT_INT, "20", NULL,
      "how many marking phrases :learn keeps for each subject", NULL),
  OPT(subject_catchall, OPT_STR, "", NULL,
      "subjects that file a book by its form, not its topic, named whole or by their last part "
      "and separated by commas (added to general, papers, books, handbook, misc, other): they "
      "are not learned from as a topic and not suggested ahead of real ones",
      NULL),
  OPT(title_case, OPT_STR, "auto", "auto|never",
      "a title found in CAPITALS is proposed in title case (APA style); never leaves it as found",
      NULL),
  OPT(enrich_services, OPT_STR, "arxiv,crossref,zbmath,openlibrary,openalex", NULL,
      "the metadata services :enrich asks, separated by commas: arxiv (by arXiv number), crossref "
      "and openalex (by DOI), zbmath (by DOI or arXiv number; gives mathematics its subject), "
      "openlibrary (by ISBN). None needs an account",
      "Looking things up"),
  OPT(contact_email, OPT_STR, "", NULL,
      "an address sent with each request to those services (CrossRef and Open Library allow more "
      "to callers they can reach); nothing is sent while this is empty",
      NULL),
  OPT(arxiv_snapshot, OPT_PATH, "", NULL,
      "a file of arXiv's records (its snapshot from Kaggle, or a hypergraph of arXiv; .json or .zip): "
      ":enrich reads a paper's record from it and asks arXiv only about papers newer than the file. "
      "Empty: arxiv-metadata-oai-snapshot.json or arxiv.json in lulibre's data folder "
      "(~/.local/share/lulibre) is used if it is there",
      NULL),
  OPT(sync_dir, OPT_PATH, "", NULL,
      "a folder of files waiting to be added to the library; gS shows it", "The sync folder"),
  OPT(sync_propose, OPT_STR, "ask", POLICY,
      "propose metadata from the title pages of files new to the sync folder", NULL),

  OPT(preview, OPT_STR, "text", "text|image", "what the preview shows first; P switches",
      "The interface"),
  OPT(blitter, OPT_STR, "auto", "auto|pixel|sextant|quadrant|half", "how page images are drawn",
      NULL),
  OPT(mouse, OPT_INT, "1", NULL,
      "1: click selects, the wheel scrolls (Shift selects text); 0: off", NULL),
  OPT(review_open, OPT_INT, "0", NULL,
      "1: the review screen starts with every book's other fields shown", NULL),
  OPT(review_sort, OPT_STR, "confidence", "confidence|id|disputed",
      "the order of books in review: the surest proposals first, by book id, or those whose sources disagree most first", NULL),
  OPT(review_rows, OPT_STR, "field", "field|all",
      "review shows one row for each field of a book, with the surest proposal for it (o steps to the "
      "next source, O takes that source for the field in every book, m switches), or all: every "
      "proposal a row of its own", NULL),
  OPT(review_context, OPT_INT, "1", NULL,
      "1: review shows, where the list is, what the proposal under the cursor rests on: the record "
      "it came from, what the book's pages say of it, the other sources for the field (i hides it)", NULL),
  OPT(review_reject, OPT_STR, "once", "once|always",
      "once: rejecting a proposal decides that proposal only, and a later run may propose the value "
      "again (N in review is the key that says never again); always: a rejected value is not proposed "
      "again for that book and field", NULL),
  OPT(weigh_sources, OPT_STR, "off", "off|on",
      "a proposal's confidence is what its agreeing sources come to, each taken for how often it has been right "
      "in this library (measured by :weigh, adjustable in :weights), instead of the confidence its rule claims", NULL),
  OPT(leader, OPT_STR, "\\", NULL,
      "the key <Leader> stands for in key bindings, in key-map notation: \\, <Space>, ,", NULL),

  OPT(config_dir, OPT_PATH, "", NULL,
      "where init.lua, scripts/ and lua/ are looked for (default: ~/.config/lulibre). To start "
      "from another one use `lulibre -C DIR` or $LULIBRE_CONFIG_DIR; set here, it moves scripts/ "
      "and lua/ from then on",
      "Where lulibre keeps things"),
  OPT(index, OPT_PATH, "", NULL, "index database file (default: under the XDG data dir)", NULL),
  OPT(orphans_dir, OPT_PATH, "", NULL,
      "where stray files are set aside (default: orphans/ under the XDG data dir)", NULL),
  OPT(log_file, OPT_PATH, "", NULL,
      "also append the log to this file (the console, `, shows it either way)", NULL),

  OPT(pixi_deps, OPT_STR, "off", "off|on",
      "on: programs that features need (pdftotext, tesseract, ocrmypdf) may come from an environment "
      "lulibre keeps with pixi under its data folder, and it offers to add one that is missing there. "
      "Off by default: it means running what pixi fetches",
      "Programs and modules"),
  OPT(rocks_tree, OPT_PATH, "", NULL,
      "a luarocks tree (luarocks --tree DIR) whose Lua modules scripts may require", NULL),
  OPT(rocks_install, OPT_STR, "off", "off|on",
      "on: when a script needs a rock that is not there, lulibre offers to install it into rocks_tree. "
      "Off by default: it means running what luarocks fetches",
      NULL),
  OPT(config_add_core, OPT_STR, "ask", POLICY,
      "options of lulibre's own that init.lua does not mention yet are put in it, commented out with "
      "their defaults (ask: the config window, :config, offers to)",
      "The configuration file"),
  OPT(config_add_scripts, OPT_STR, "ask", POLICY,
      "the same for the options scripts declare (lulibre.option), each script's under its own name", NULL),
  OPT(config_comments, OPT_STR, "full", "full|values|none",
      "what is written above an option put in init.lua: its help in full, only the values it takes, or "
      "nothing (an option with no help gets none either way)",
      NULL),
};

const struct opt_def *config_opts(size_t *n) {
  *n = ARRAY_LEN(opts);
  return opts;
}

const struct opt_def *config_find(const char *name) {
  for (size_t i = 0; i < ARRAY_LEN(opts); i++)
    if (strcmp(opts[i].name, name) == 0) return &opts[i];
  return NULL;
}

static char **str_slot(const struct config *c, const struct opt_def *o) {
  return (char **)((char *)c + o->off);
}

static int *int_slot(const struct config *c, const struct opt_def *o) {
  return (int *)((char *)c + o->off);
}

void config_init(struct config *c) {
  memset(c, 0, sizeof *c);
  for (size_t i = 0; i < ARRAY_LEN(opts); i++) {
    if (opts[i].type == OPT_INT) *int_slot(c, &opts[i]) = atoi(opts[i].def);
    else *str_slot(c, &opts[i]) = xstrdup(opts[i].def);
  }
}

void config_free(struct config *c) {
  for (size_t i = 0; i < ARRAY_LEN(opts); i++)
    if (opts[i].type != OPT_INT) free(*str_slot(c, &opts[i]));
  memset(c, 0, sizeof *c);
}

int config_set(struct config *c, const char *name, const char *val, char **err) {
  const struct opt_def *o = config_find(name);
  if (!o) {
    *err = xasprintf("unknown option '%s'", name);
    return -1;
  }
  if (o->type == OPT_INT) {
    char *end;
    errno = 0;
    long v = strtol(val, &end, 10);
    if (errno || *end || end == val || v < 0 || v > INT_MAX) {
      *err = xasprintf("option '%s' wants a non-negative integer, got '%s'", name, val);
      return -1;
    }
    *int_slot(c, o) = (int)v;
    return 0;
  }
  if (o->choices) {
    size_t n = strlen(val);
    int found = 0;
    for (const char *p = o->choices; *p && n;) {
      const char *e = strchr(p, '|');
      size_t len = e ? (size_t)(e - p) : strlen(p);
      if (len == n && !strncmp(p, val, n)) found = 1;
      p += len + (e != NULL);
    }
    if (!found) {
      *err = xasprintf("option '%s' is one of %s, not '%s'", name, o->choices, val);
      return -1;
    }
  }
  char **slot = str_slot(c, o);
  free(*slot);
  *slot = o->type == OPT_PATH ? path_expand(val) : xstrdup(val);
  return 0;
}

const char *config_str(const struct config *c, const struct opt_def *o) {
  return *str_slot(c, o);
}

int config_int(const struct config *c, const struct opt_def *o) {
  return *int_slot(c, o);
}

char *config_dir_path(const struct config *c) {
  if (c->config_dir && c->config_dir[0]) return xstrdup(c->config_dir);
  const char *xdg = getenv("XDG_CONFIG_HOME");
  return xdg && xdg[0] ? xasprintf("%s/lulibre", xdg) : path_expand("~/.config/lulibre");
}

char *config_index_path(const struct config *c) {
  if (c->index[0]) return xstrdup(c->index);
  char *real = realpath(c->library, NULL);
  const char *lib = real ? real : c->library;
  const char *base = strrchr(lib, '/');
  base = base && base[1] ? base + 1 : "library";
  const char *xdg = getenv("XDG_DATA_HOME");
  char *dir = xdg && xdg[0] ? xasprintf("%s/lulibre", xdg) : path_expand("~/.local/share/lulibre");
  char *out = xasprintf("%s/%s-%08llx.db", dir, base, hash_fnv1a(lib) & 0xffffffffULL);
  free(dir);
  free(real);
  return out;
}
