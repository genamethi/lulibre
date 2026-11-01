/* Text with styles and links, as the pager shows it (struct rich, tui.h):
 * made from Markdown, parsed by md4c, or from plain text.
 *
 * Markdown is laid out for a terminal: a paragraph or a list item is one
 * line, which the pager wraps under the column its text starts at; lists
 * are marked "- " or "1. ", a quote "│ ", code blocks indented; headings
 * open sections (those of level 1 and 2 in capitals); a table's cells side
 * by side in columns, the head's in bold. Each heading keeps its text and
 * its anchor as GitHub makes it, and each row of a table where its cells
 * are, for those who read the text for more than showing it (the guides'
 * index). Raw HTML is left out. The interface thread's (dr_width). */
#include <stdlib.h>
#include <string.h>

#include <md4c.h>

#include "core/util.h"
#include "match/fold.h"
#include "tui/tui.h"

/* ---- building ---- */

static void grow(void **v, int n, int *cap, size_t size) {
  if (n < *cap) return;
  *cap = *cap ? *cap * 2 : 16;
  *v = xrealloc(*v, (size_t)*cap * size);
}

void rich_link(struct rich *r, size_t off, size_t len, const char *target) {
  grow((void **)&r->links, r->nlinks, &r->links_cap, sizeof *r->links);
  r->links[r->nlinks++] = (struct pager_link){off, len, xstrdup(target)};
}

static void add_span(struct rich *r, size_t off, size_t len, unsigned style) {
  if (!len) return;
  grow((void **)&r->spans, r->nspans, &r->spans_cap, sizeof *r->spans);
  r->spans[r->nspans++] = (struct rich_span){off, len, style};
}

static void set_hang(struct rich *r, int line, int hang) {
  if (line >= r->hang_cap) {
    int was = r->hang_cap;
    r->hang_cap = line + 64;
    r->hang = xrealloc(r->hang, (size_t)r->hang_cap * sizeof *r->hang);
    for (int i = was; i < r->hang_cap; i++) r->hang[i] = -1;
  }
  r->hang[line] = hang;
}

/* src's text, spans and links, at the end of dst's text */
static void append(struct rich *dst, const struct rich *src) {
  size_t base = dst->text.len;
  if (src->text.len) sb_putn(&dst->text, src->text.s, src->text.len);
  for (int i = 0; i < src->nspans; i++) add_span(dst, base + src->spans[i].off, src->spans[i].len, src->spans[i].style);
  for (int i = 0; i < src->nlinks; i++) rich_link(dst, base + src->links[i].off, src->links[i].len, src->links[i].target);
}

/* the end of a line: hang is the column its wrapped rows start at (-1: the
 * pager's guess) */
static void end_line(struct rich *r, int hang) {
  sb_putc(&r->text, '\n');
  set_hang(r, r->nlines++, hang);
}

static int last_blank(const struct rich *r) {
  return r->text.len == 0 || (r->text.len >= 2 && r->text.s[r->text.len - 2] == '\n');
}

void rich_free(struct rich *r) {
  sb_free(&r->text);
  free(r->hang);
  free(r->src);
  free(r->spans);
  for (int i = 0; i < r->nlinks; i++) free(r->links[i].target);
  free(r->links);
  for (int i = 0; i < r->nheads; i++) {
    free(r->heads[i].text);
    free(r->heads[i].anchor);
  }
  free(r->heads);
  for (int i = 0; i < r->nrows; i++) free(r->rows[i].cells);
  free(r->rows);
  memset(r, 0, sizeof *r);
}

static void add_head(struct rich *r, int line, int level, char *text, char *anchor) {
  grow((void **)&r->heads, r->nheads, &r->heads_cap, sizeof *r->heads);
  r->heads[r->nheads++] = (struct rich_heading){line, level, text, anchor};
}

void rich_plain(struct rich *r) {
  int line = 0;
  for (const char *p = r->text.s ? r->text.s : ""; *p; line++) {
    size_t len = strcspn(p, "\n");
    if (len && p[0] != ' ') add_head(r, line, 1, xstrndup(p, len), NULL);
    p += len + (p[len] == '\n');
  }
  r->nlines = line;
}

/* A heading's anchor as GitHub makes it: lower case, punctuation gone,
 * spaces as dashes, and -1, -2 ... after one the text already has. */
static char *slug(const struct rich *r, const char *text) {
  sbuf out = SBUF_INIT;
  for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
    if (*p >= 'A' && *p <= 'Z') sb_putc(&out, (char)(*p - 'A' + 'a'));
    else if (*p == ' ') sb_putc(&out, '-');
    else if (*p >= 0x80 || (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '-' || *p == '_')
      sb_putc(&out, (char)*p);
  }
  char *s = out.s ? sb_take(&out) : xstrdup("");
  for (int n = 1;; n++) {
    int taken = 0;
    for (int i = 0; i < r->nheads && !taken; i++) taken = r->heads[i].anchor && !strcmp(r->heads[i].anchor, s);
    if (!taken) return s;
    char *again = xasprintf("%.*s-%d", (int)(n == 1 ? strlen(s) : strrchr(s, '-') - s), s, n);
    free(s);
    s = again;
  }
}

/* ---- Markdown ---- */

enum { NEST_MAX = 16, OPEN_MAX = 16 };

struct nest { /* a list, or a quote (ol < 0) */
  int ol, tight;
  unsigned n;
  char mark[16]; /* the item's mark, until its first line has it */
};

struct open_span {
  MD_SPANTYPE type;
  size_t at;
  char *href;
};

struct cell_at { /* where a table's cell is */
  int row, col;
  long at; /* in the source; -1 until its text comes */
};

struct md {
  struct rich *out;
  int width;
  const char *src;
  size_t srclen;
  long *ats; /* each line's start in the source, -1 for none */
  int ats_cap;
  struct rich line; /* a paragraph, a heading, an item's text, a code block, as it comes */
  long line_at;     /* where its text starts in the source */
  struct nest nest[NEST_MAX];
  int depth, over; /* over: lists and quotes past NEST_MAX, in the last one's place */
  struct open_span open[OPEN_MAX];
  int nopen;
  int code, html, heading;
  /* a table, as it comes: its cells, row by row */
  struct rich *cells;
  struct cell_at *cell;
  int ncells, cells_cap, cols, in_cell, rows, head_rows;
};

static struct rich *cur(struct md *m) {
  return m->in_cell ? &m->cells[m->ncells - 1] : &m->line;
}

/* What goes before a line, put in out: the margin, each list's indent (the
 * item's mark on its first line), each quote's bar. Returns its width. */
static int lead(struct md *m, sbuf *out) {
  sb_puts(out, "  ");
  int w = 2;
  for (int i = 0; i < m->depth; i++) {
    struct nest *n = &m->nest[i];
    if (n->ol < 0) {
      sb_puts(out, "│ ");
      w += 2;
      continue;
    }
    int mw = n->ol ? 3 + (n->n >= 10) : 2;
    if (n->mark[0]) {
      sb_printf(out, "%-*s", mw, n->mark);
      n->mark[0] = '\0';
    } else {
      sb_printf(out, "%*s", mw, "");
    }
    w += mw;
  }
  return w;
}

/* in a tight list: no blank lines between its items */
static int tight(const struct md *m) {
  for (int i = m->depth - 1; i >= 0; i--)
    if (m->nest[i].ol >= 0) return m->nest[i].tight;
  return 0;
}

/* the end of a line of the text, which starts at `at` in the source */
static void md_end(struct md *m, int hang, long at) {
  if (m->out->nlines >= m->ats_cap) {
    m->ats_cap = m->out->nlines + 64;
    m->ats = xrealloc(m->ats, (size_t)m->ats_cap * sizeof *m->ats);
  }
  m->ats[m->out->nlines] = at;
  end_line(m->out, hang);
}

static void gap(struct md *m) {
  if (m->out->text.len && !last_blank(m->out)) md_end(m, -1, -1);
}

/* the gathered line, after its lead, as a line of the text */
static void flush(struct md *m) {
  struct rich *l = &m->line;
  if (!l->text.len) return;
  int hang = lead(m, &m->out->text);
  append(m->out, l);
  md_end(m, hang, m->line_at);
  m->line_at = -1;
  rich_free(l);
  for (int i = 0; i < m->nopen; i++) m->open[i].at = 0; /* spans still open go on in the next line */
}

/* &amp; &#233; &#xe9; ...: the character; one not known stays as it is */
static void entity(sbuf *out, const char *s, size_t n) {
  static const char *const named[][2] = {{"amp", "&"}, {"lt", "<"}, {"gt", ">"}, {"quot", "\""},
                                         {"apos", "'"}, {"nbsp", "\xc2\xa0"}, {"mdash", "—"}, {"ndash", "–"}};
  if (n > 3 && s[1] == '#') { /* one that is no character is U+FFFD, as CommonMark has it */
    int hex = s[2] == 'x' || s[2] == 'X';
    unsigned long cp = strtoul(s + 2 + hex, NULL, hex ? 16 : 10);
    char u[8];
    int k = cp && cp <= 0x10ffff && (cp < 0xd800 || cp > 0xdfff) ? utf8_encode(u, (unsigned)cp) : 0;
    if (k > 0) sb_putn(out, u, (size_t)k);
    else sb_puts(out, "\xef\xbf\xbd");
    return;
  }
  for (size_t i = 0; i < ARRAY_LEN(named); i++)
    if (n == strlen(named[i][0]) + 2 && !strncmp(s + 1, named[i][0], n - 2)) {
      sb_puts(out, named[i][1]);
      return;
    }
  sb_putn(out, s, n);
}

static void attr(sbuf *out, const MD_ATTRIBUTE *a) {
  for (int i = 0; a->substr_offsets && a->substr_offsets[i] < a->size; i++) {
    MD_OFFSET from = a->substr_offsets[i], to = a->substr_offsets[i + 1];
    if (a->substr_types[i] == MD_TEXT_ENTITY) entity(out, a->text + from, to - from);
    else sb_putn(out, a->text + from, to - from);
  }
}

/* A table: its cells side by side, each column as wide as its widest cell,
 * the last one wrapping under itself. When the columns before the last
 * would take more than the width less 32, the widest of them narrows; a
 * cell wider than its column goes on, and the row's next cell starts a line
 * of its own below, in its column. */
static void table(struct md *m) {
  enum { COLS_MAX = 16 };
  int ncols = m->cols < COLS_MAX ? m->cols : COLS_MAX, width[COLS_MAX] = {0};
  int budget = m->width - 32 > 16 ? m->width - 32 : 16;
  for (int c = 0; c < m->ncells; c++) {
    int col = m->cell[c].col, w = m->cells[c].text.s ? dr_width(m->cells[c].text.s, m->cells[c].text.len) : 0;
    if (col < ncols && w > width[col]) width[col] = w;
  }
  for (;;) {
    int sum = 0, widest = 0;
    for (int j = 0; j < ncols - 1; j++) {
      sum += width[j] + 3;
      if (width[j] > width[widest]) widest = j;
    }
    if (sum <= budget || width[widest] <= 8) break;
    width[widest]--;
  }
  struct rich *o = m->out;
  for (int c = 0; c < m->ncells;) {
    int row = m->cell[c].row, first = c, last;
    long at = m->cell[c].at;
    while (c < m->ncells && m->cell[c].row == row) c++;
    for (last = c - 1; last > first && !m->cells[last].text.len; last--) {} /* nothing after the last cell with something */
    grow((void **)&o->rows, o->nrows, &o->rows_cap, sizeof *o->rows);
    struct rich_row *rr = &o->rows[o->nrows++];
    *rr = (struct rich_row){o->nlines, row < m->head_rows, c - first, xcalloc((size_t)(c - first), sizeof *rr->cells)};
    int col = lead(m, &o->text);
    for (int k = first; k <= last; k++) {
      int j = m->cell[k].col, w = m->cells[k].text.s ? dr_width(m->cells[k].text.s, m->cells[k].text.len) : 0;
      int start = col;
      rr->cells[k - first] = (struct rich_cell){o->text.len, m->cells[k].text.len};
      if (rr->head) add_span(o, o->text.len, m->cells[k].text.len, RS_STRONG);
      append(o, &m->cells[k]);
      if (k == last || j >= ncols - 1) break;
      int pad = width[j] - w + 3;
      col += width[j] + 3;
      if (w > width[j]) { /* the next cell, below in its column */
        md_end(m, start, at);
        pad = col;
      }
      for (int p = 0; p < pad; p++) sb_putc(&o->text, ' ');
    }
    md_end(m, col, at);
  }
  for (int c = 0; c < m->ncells; c++) rich_free(&m->cells[c]);
  free(m->cells);
  free(m->cell);
  m->cells = NULL;
  m->cell = NULL;
  m->ncells = m->cells_cap = m->cols = m->rows = 0;
}

static int enter_block(MD_BLOCKTYPE type, void *detail, void *ud) {
  struct md *m = ud;
  if (m->html) return 0;
  switch (type) {
    case MD_BLOCK_UL:
    case MD_BLOCK_OL:
    case MD_BLOCK_QUOTE:
      flush(m);
      if (!m->depth || type == MD_BLOCK_QUOTE || !tight(m)) gap(m);
      if (m->depth == NEST_MAX) m->over++;
      else {
        struct nest *n = &m->nest[m->depth++];
        *n = (struct nest){type == MD_BLOCK_QUOTE ? -1 : type == MD_BLOCK_OL, 0, 1, ""};
        if (type == MD_BLOCK_OL) n->n = ((MD_BLOCK_OL_DETAIL *)detail)->start;
        n->tight = type == MD_BLOCK_UL ? ((MD_BLOCK_UL_DETAIL *)detail)->is_tight
                   : type == MD_BLOCK_OL ? ((MD_BLOCK_OL_DETAIL *)detail)->is_tight
                                         : 0;
      }
      break;
    case MD_BLOCK_LI: {
      flush(m);
      struct nest *n = m->depth ? &m->nest[m->depth - 1] : NULL;
      if (!n || n->ol < 0) break;
      MD_BLOCK_LI_DETAIL *li = detail;
      const char *task = !li->is_task ? "" : li->task_mark == ' ' ? "[ ] " : "[x] ";
      if (n->ol) snprintf(n->mark, sizeof n->mark, "%u.", n->n++);
      else snprintf(n->mark, sizeof n->mark, "-");
      if (*task) sb_puts(&m->line.text, task);
      break;
    }
    case MD_BLOCK_H:
      flush(m);
      gap(m);
      m->heading = (int)((MD_BLOCK_H_DETAIL *)detail)->level;
      break;
    case MD_BLOCK_CODE:
      flush(m);
      gap(m);
      m->code = 1;
      break;
    case MD_BLOCK_HTML: m->html = 1; break;
    case MD_BLOCK_P:
      flush(m);
      if (!tight(m)) gap(m);
      break;
    case MD_BLOCK_HR: {
      flush(m);
      gap(m);
      int hang = lead(m, &m->out->text);
      for (int i = 0; i < 24; i++) sb_puts(&m->out->text, "─");
      md_end(m, hang, -1);
      break;
    }
    case MD_BLOCK_TABLE:
      flush(m);
      gap(m);
      m->cols = (int)((MD_BLOCK_TABLE_DETAIL *)detail)->col_count;
      m->head_rows = (int)((MD_BLOCK_TABLE_DETAIL *)detail)->head_row_count;
      m->rows = 0;
      break;
    case MD_BLOCK_TR: m->rows++; break;
    case MD_BLOCK_TH:
    case MD_BLOCK_TD: {
      int col = 0;
      for (int c = m->ncells - 1; c >= 0 && m->cell[c].row == m->rows - 1; c--) col++;
      grow((void **)&m->cells, m->ncells, &m->cells_cap, sizeof *m->cells);
      m->cell = xrealloc(m->cell, (size_t)m->cells_cap * sizeof *m->cell);
      memset(&m->cells[m->ncells], 0, sizeof *m->cells);
      m->cell[m->ncells++] = (struct cell_at){m->rows - 1, col, -1};
      m->in_cell = 1;
      break;
    }
    default: break;
  }
  return 0;
}

static int leave_block(MD_BLOCKTYPE type, void *detail, void *ud) {
  struct md *m = ud;
  (void)detail;
  if (m->html) {
    m->html = type != MD_BLOCK_HTML;
    return 0;
  }
  switch (type) {
    case MD_BLOCK_UL:
    case MD_BLOCK_OL:
    case MD_BLOCK_QUOTE:
      flush(m);
      if (m->over) m->over--;
      else if (m->depth) m->depth--;
      break;
    case MD_BLOCK_LI:
    case MD_BLOCK_P: flush(m); break;
    case MD_BLOCK_H: {
      struct rich *l = &m->line, *o = m->out;
      char *text = xstrndup(l->text.s ? l->text.s : "", l->text.len);
      add_head(o, o->nlines, m->heading, text, slug(o, text));
      if (m->heading <= 2)
        for (size_t k = 0; k < l->text.len; k++)
          if (l->text.s[k] >= 'a' && l->text.s[k] <= 'z') l->text.s[k] = (char)(l->text.s[k] - 'a' + 'A');
      append(o, l);
      md_end(m, 0, m->line_at);
      m->line_at = -1;
      rich_free(l);
      m->heading = 0;
      break;
    }
    case MD_BLOCK_CODE: {
      struct rich *l = &m->line;
      const char *s = l->text.s ? l->text.s : "";
      size_t n = l->text.len;
      if (n && s[n - 1] == '\n') n--;
      long from = m->line_at; /* each line of code is a line of the source */
      for (size_t at = 0; at < n;) {
        size_t len = strcspn(s + at, "\n");
        if (at + len > n) len = n - at;
        int hang = lead(m, &m->out->text) + 2;
        sb_puts(&m->out->text, "  ");
        add_span(m->out, m->out->text.len, len, RS_CODE);
        sb_putn(&m->out->text, s + at, len);
        md_end(m, hang, from);
        const char *nl = from >= 0 ? memchr(m->src + from, '\n', m->srclen - (size_t)from) : NULL;
        from = nl ? nl + 1 - m->src : -1;
        at += len + 1;
      }
      m->line_at = -1;
      rich_free(l);
      m->code = 0;
      break;
    }
    case MD_BLOCK_TH:
    case MD_BLOCK_TD: m->in_cell = 0; break;
    case MD_BLOCK_TABLE: table(m); break;
    default: break;
  }
  return 0;
}

static int enter_span(MD_SPANTYPE type, void *detail, void *ud) {
  struct md *m = ud;
  if (m->html || m->nopen == OPEN_MAX) return 0;
  sbuf href = SBUF_INIT;
  if (type == MD_SPAN_A) attr(&href, &((MD_SPAN_A_DETAIL *)detail)->href);
  m->open[m->nopen++] = (struct open_span){type, cur(m)->text.len, href.s ? sb_take(&href) : NULL};
  return 0;
}

static int leave_span(MD_SPANTYPE type, void *detail, void *ud) {
  struct md *m = ud;
  (void)detail;
  if (m->html || !m->nopen) return 0;
  struct rich *r = cur(m);
  size_t at = m->open[--m->nopen].at, len = r->text.len - at;
  char *href = m->open[m->nopen].href;
  switch (type) {
    case MD_SPAN_EM: add_span(r, at, len, RS_EM); break;
    case MD_SPAN_STRONG: add_span(r, at, len, RS_STRONG); break;
    case MD_SPAN_CODE: add_span(r, at, len, RS_CODE); break;
    case MD_SPAN_DEL: add_span(r, at, len, RS_STRIKE); break;
    case MD_SPAN_A:
      if (href && *href && len) rich_link(r, at, len, href);
      break;
    default: break;
  }
  free(href);
  return 0;
}

static int text(MD_TEXTTYPE type, const MD_CHAR *s, MD_SIZE n, void *ud) {
  struct md *m = ud;
  if (m->html) return 0;
  sbuf *out = &cur(m)->text;
  long at = s >= m->src && s < m->src + m->srclen ? s - m->src : -1;
  if (m->in_cell && m->cell[m->ncells - 1].at < 0) m->cell[m->ncells - 1].at = at;
  else if (!m->in_cell && m->line_at < 0) m->line_at = at;
  switch (type) {
    case MD_TEXT_HTML: break;
    case MD_TEXT_NULLCHAR: sb_puts(out, "\xef\xbf\xbd"); break;
    case MD_TEXT_SOFTBR: sb_putc(out, ' '); break;
    case MD_TEXT_BR:
      if (m->in_cell || m->heading) sb_putc(out, ' ');
      else flush(m);
      break;
    case MD_TEXT_ENTITY: entity(out, s, n); break;
    default: sb_putn(out, s, n);
  }
  return 0;
}

int md_render(const char *src, size_t n, int width, struct rich *out) {
  memset(out, 0, sizeof *out);
  struct md m = {.out = out, .width = width > 0 ? width : PAGER_WIDTH, .src = src, .srclen = n, .line_at = -1};
  const MD_PARSER parser = {0,          MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH | MD_FLAG_TASKLISTS | MD_FLAG_PERMISSIVEURLAUTOLINKS,
                            enter_block, leave_block, enter_span, leave_span, text, NULL, NULL};
  int r = md_parse(src, (MD_SIZE)n, &parser, &m);
  flush(&m);
  rich_free(&m.line);
  for (int i = 0; i < m.nopen; i++) free(m.open[i].href);
  for (int c = 0; c < m.ncells; c++) rich_free(&m.cells[c]);
  free(m.cells);
  free(m.cell);
  /* no blank lines at the end */
  while (out->text.len >= 2 && out->text.s[out->text.len - 1] == '\n' && out->text.s[out->text.len - 2] == '\n') {
    out->text.s[--out->text.len] = '\0';
    out->nlines--;
  }
  /* each line's line in the source, from 1; one with none has the one before's */
  out->src = xcalloc((size_t)out->nlines + 1, sizeof *out->src);
  long done = 0;
  for (int i = 0, line = 1, prev = 1; i < out->nlines; i++) {
    long at = m.ats[i];
    if (at >= done) {
      for (; done < at; done++) line += src[done] == '\n';
    } else if (at >= 0) { /* earlier than the line before: count again */
      line = 1;
      for (done = 0; done < at; done++) line += src[done] == '\n';
    }
    out->src[i] = prev = at >= 0 ? line : prev;
  }
  free(m.ats);
  return r ? -1 : 0;
}

int rich_line_of(const struct rich *r, int src) {
  int best = 0;
  for (int i = 0; r->src && i < r->nlines; i++)
    if (r->src[i] <= src && r->src[i] > r->src[best]) best = i;
  return best;
}
