/* The preview: metadata and the indexed page text for the book under the
 * cursor, both read from the index (never from the book file), so it is
 * instant. The graphic mode renders the page on the thread pool and is only
 * started once the cursor has rested. */
#include <stdlib.h>
#include <string.h>

#include "doc/doc.h"
#include "match/fold.h"
#include "tui/tui.h"

struct wline {
  const char *p;
  int len;
};

struct pstate {
  struct tui *t;
  sqlite3_int64 book;
  uint64_t rows_gen;

  char *title, *authors, *tags, *pub, *idents, *year;
  sqlite3_int64 file;
  char *fpath, *fmt, *ferror, *etitle, *eauthor;
  int fstatus, npages, indexed;
  int first_text; /* first indexed page with text worth showing; 0 if none */
  int skipped;    /* blank leading pages passed over when the book was opened */

  int page; /* 1-based */
  char *text;
  int scroll;
  struct wline *wl;
  int nwl, capwl, wrap_w;
  /* text selected with the mouse: bytes [sel_lo, sel_hi) of text */
  struct rect body; /* where the text was last drawn; h == 0 when it was not */
  long sel_lo, sel_hi;
  long anchor_lo, anchor_hi; /* the character the drag began on */
  int selecting, clicks, click_y, click_x;
  double click_at;

  int graphic;
  struct doc_image img;
  sqlite3_int64 img_file;
  int img_page, img_w;
  struct ncplane *plane;
  struct rect plane_r;
  int plane_scroll, plane_valid;
  int cell_w, cell_h; /* image pixels per cell under the blitter in use */
  int scroll_px, scroll_x;
  int zoom; /* 1 = page width fills the pane */
  float img_aspect;
  int job_running, dead;
  char *job_error;
};

struct rjob {
  uv_work_t req;
  struct pstate *ps;
  char *path;
  sqlite3_int64 file;
  int page, width;
  float aspect;
  struct doc_image img;
};

static char *col(sqlite3_stmt *st, int i) {
  const char *s = (const char *)sqlite3_column_text(st, i);
  return s && *s ? xstrdup(s) : NULL;
}

static void drop_plane(struct pstate *ps) {
  if (ps->plane) ncplane_destroy(ps->plane);
  ps->plane = NULL;
  ps->plane_valid = 0;
}

static void clear_book(struct pstate *ps) {
  char **fields[] = {&ps->title, &ps->authors, &ps->tags, &ps->pub, &ps->idents, &ps->year,
                     &ps->fpath, &ps->fmt, &ps->ferror, &ps->etitle, &ps->eauthor, &ps->text,
                     &ps->job_error};
  for (size_t i = 0; i < ARRAY_LEN(fields); i++) {
    free(*fields[i]);
    *fields[i] = NULL;
  }
  ps->file = 0;
  ps->fstatus = ps->npages = ps->indexed = 0;
  ps->nwl = 0;
  ps->wrap_w = 0;
}

static void load_page(struct pstate *ps) {
  sqlite3_stmt *st;
  free(ps->text);
  ps->text = NULL;
  ps->sel_lo = ps->sel_hi = 0; /* a selection belongs to the page it was made on */
  ps->selecting = 0;
  ps->nwl = 0;
  ps->wrap_w = 0;
  ps->scroll = ps->scroll_px = ps->scroll_x = 0;
  ps->plane_valid = 0;
  if (!ps->file) return;
  if (sqlite3_prepare_v2(ps->t->app->db.h, "SELECT text FROM pages WHERE file = ? AND page = ?", -1,
                         &st, NULL) != SQLITE_OK)
    return;
  sqlite3_bind_int64(st, 1, ps->file);
  sqlite3_bind_int(st, 2, ps->page);
  const char *text = sqlite3_step(st) == SQLITE_ROW ? (const char *)sqlite3_column_text(st, 0) : NULL;
  if (text) ps->text = xstrdup(text);
  sqlite3_finalize(st);
}

static void load_book(struct pstate *ps, sqlite3_int64 id) {
  sqlite3 *h = ps->t->app->db.h;
  sqlite3_stmt *st;
  clear_book(ps);
  ps->book = id;
  ps->page = 1;
  if (!id) return;
  if (sqlite3_prepare_v2(h,
                         "SELECT title, authors, tags, publisher, idents, year FROM books"
                         " WHERE id = ?",
                         -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(st, 1, id);
    if (sqlite3_step(st) == SQLITE_ROW) {
      ps->title = col(st, 0);
      ps->authors = col(st, 1);
      ps->tags = col(st, 2);
      ps->pub = col(st, 3);
      ps->idents = col(st, 4);
      ps->year = col(st, 5);
    }
    sqlite3_finalize(st);
  }
  if (sqlite3_prepare_v2(h,
                         "SELECT f.id, f.path, f.format, f.status, f.error, f.npages,"
                         " (SELECT count(*) FROM pages p WHERE p.file = f.id), f.emb_title,"
                         " f.emb_author FROM files f WHERE f.book = ? ORDER BY f.id LIMIT 1",
                         -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(st, 1, id);
    if (sqlite3_step(st) == SQLITE_ROW) {
      ps->file = sqlite3_column_int64(st, 0);
      ps->fpath = col(st, 1);
      ps->fmt = col(st, 2);
      ps->fstatus = sqlite3_column_int(st, 3);
      ps->ferror = col(st, 4);
      ps->npages = sqlite3_column_int(st, 5);
      ps->indexed = sqlite3_column_int(st, 6);
      ps->etitle = col(st, 7);
      ps->eauthor = col(st, 8);
    }
    sqlite3_finalize(st);
  }
  /* A scan often opens on a cover or a blank leaf. Start where there is
   * something to read; [ still goes back. */
  ps->first_text = ps->skipped = 0;
  if (ps->file &&
      sqlite3_prepare_v2(h, "SELECT min(page) FROM pages WHERE file = ? AND length(trim(text)) >= 40",
                         -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(st, 1, ps->file);
    if (sqlite3_step(st) == SQLITE_ROW) ps->first_text = sqlite3_column_int(st, 0);
    sqlite3_finalize(st);
  }
  if (ps->first_text > 1) {
    ps->skipped = ps->first_text - 1;
    ps->page = ps->first_text;
  }
  load_page(ps);
}

static void wrap(struct pstate *ps, int w) {
  if (ps->wrap_w == w) return;
  ps->wrap_w = w;
  ps->nwl = 0;
  const char *p = ps->text ? ps->text : "";
  while (*p) {
    const char *nl = strchr(p, '\n');
    size_t len = nl ? (size_t)(nl - p) : strlen(p);
    size_t off = 0;
    do {
      size_t take = dr_wrap(p + off, len - off, w);
      if (ps->nwl == ps->capwl) {
        ps->capwl = ps->capwl ? ps->capwl * 2 : 128;
        ps->wl = xrealloc(ps->wl, (size_t)ps->capwl * sizeof *ps->wl);
      }
      ps->wl[ps->nwl++] = (struct wline){p + off, (int)take};
      off += take;
      while (off < len && p[off] == ' ') off++;
    } while (off < len);
    p += len;
    if (*p == '\n') p++;
  }
}

/* ---- graphic mode ---- */

static void work_cb(uv_work_t *req) {
  struct rjob *j = req->data;
  doc_render(j->path, j->page - 1, j->width, j->aspect, &j->img);
}

static void pstate_free(struct pstate *ps) {
  clear_book(ps);
  doc_image_free(&ps->img);
  free(ps->wl);
  free(ps);
}

static void after_cb(uv_work_t *req, int status) {
  struct rjob *j = req->data;
  struct pstate *ps = j->ps;
  ps->job_running = 0;
  if (ps->dead) {
    pstate_free(ps);
  } else if (!ps->t->quit) {
    if (j->file == ps->file && j->page == ps->page) {
      doc_image_free(&ps->img);
      free(ps->job_error);
      ps->job_error = NULL;
      if (j->img.error) {
        ps->job_error = j->img.error;
        j->img.error = NULL;
      } else {
        ps->img = j->img;
        memset(&j->img, 0, sizeof j->img);
      }
      ps->img_file = j->file;
      ps->img_page = j->page;
      ps->img_w = j->width;
      ps->img_aspect = j->aspect;
      ps->plane_valid = 0;
    }
    tui_dirty(ps->t); /* a stale result: the next draw asks again */
  }
  doc_image_free(&j->img);
  free(j->path);
  free(j);
}

static void request_image(struct pstate *ps, int width, float aspect) {
  struct rjob *j = xcalloc(1, sizeof *j);
  j->ps = ps;
  j->path = xstrdup(ps->fpath);
  j->file = ps->file;
  j->page = ps->page;
  j->width = width;
  j->aspect = aspect;
  j->req.data = j;
  ps->job_running = 1;
  uv_queue_work(ps->t->app->loop, &j->req, work_cb, after_cb);
}

/* How a page image reaches the screen. Real pixels when the terminal has
 * them (sixel, kitty). Otherwise block glyphs drawn here rather than by
 * notcurses, which will not use sextants or quadrants inside tmux because it
 * cannot see the outer terminal; the `blitter` option overrides the choice. */
enum imode { IMG_PIXEL, IMG_SEXTANT, IMG_QUADRANT, IMG_HALF };

/* Sets the image pixels one cell holds, and one such pixel's height over its
 * width (taking a cell to be twice as tall as wide). */
static enum imode cell_geometry(struct tui *t, int *cw, int *ch, float *aspect) {
  const char *want = t->app->cfg.blitter;
  int any = !strcmp(want, "auto");
  if ((any || !strcmp(want, "pixel")) && notcurses_canpixel(t->nc)) {
    unsigned pxy, pxx, cdy, cdx, my, mx;
    ncplane_pixel_geom(t->std, &pxy, &pxx, &cdy, &cdx, &my, &mx);
    if (cdy > 0 && cdx > 0) {
      *cw = (int)cdx;
      *ch = (int)cdy;
      *aspect = 1.0f;
      return IMG_PIXEL;
    }
  }
  enum imode m = IMG_QUADRANT;
  if (!strcmp(want, "sextant") || (any && notcurses_cansextant(t->nc))) m = IMG_SEXTANT;
  else if (!strcmp(want, "half")) m = IMG_HALF;
  *cw = m == IMG_HALF ? 1 : 2;
  *ch = m == IMG_SEXTANT ? 3 : 2;
  *aspect = 2.0f * (float)*cw / (float)*ch;
  return m;
}

/* Is the right image in hand? If not, ask for it (once the cursor has
 * rested) and report 0 so the caller shows text in the meantime. */
static int image_ready(struct pstate *ps, int body_w, enum imode *mode) {
  struct tui *t = ps->t;
  float aspect;
  *mode = cell_geometry(t, &ps->cell_w, &ps->cell_h, &aspect);
  if (ps->zoom < 1) ps->zoom = 1;
  int want_w = body_w * ps->cell_w * ps->zoom;
  if (want_w > 4096) want_w = 4096;
  if (ps->img.rgba && ps->img_file == ps->file && ps->img_page == ps->page &&
      ps->img_w == want_w && ps->img_aspect == aspect)
    return 1;
  if (t->settled && !ps->job_running && ps->fpath && !ps->job_error) {
    ps->img_aspect = aspect;
    request_image(ps, want_w, aspect);
  }
  return 0;
}

static unsigned glyph_for(enum imode mode, unsigned mask) {
  static const unsigned quad[16] = {' ',    0x2598, 0x259d, 0x2580, 0x2596, 0x258c,
                                    0x259e, 0x259b, 0x2597, 0x259a, 0x2590, 0x259c,
                                    0x2584, 0x2599, 0x259f, 0x2588};
  static const unsigned half[4] = {' ', 0x2580, 0x2584, 0x2588};
  if (mode == IMG_HALF) return half[mask & 3];
  if (mode == IMG_QUADRANT) return quad[mask & 15];
  /* sextants: U+1FB00 onward in mask order, except the three masks that
   * already existed as block elements */
  mask &= 63;
  if (mask == 0) return ' ';
  if (mask == 21) return 0x258c;
  if (mask == 42) return 0x2590;
  if (mask == 63) return 0x2588;
  return 0x1fb00 + mask - 1 - (mask > 21) - (mask > 42);
}

/* Draw the visible part of the image with block glyphs: each cell covers
 * cw x ch image pixels, split into a lighter and a darker group, which
 * become the cell's foreground and background. */
static void blit_cells(struct pstate *ps, struct rect body, enum imode mode) {
  struct ncplane *n = ps->t->std;
  const struct doc_image *im = &ps->img;
  int cw = ps->cell_w, ch = ps->cell_h, npx = cw * ch;
  for (int cy = 0; cy < body.h; cy++) {
    int py0 = ps->scroll_px + cy * ch;
    if (py0 >= im->h) break;
    for (int cx = 0; cx < body.w; cx++) {
      int px0 = ps->scroll_x + cx * cw;
      if (px0 >= im->w) break;
      const unsigned char *px[6];
      int lum[6], lo = 255, hi = 0, sum = 0;
      for (int i = 0; i < npx; i++) {
        int x = px0 + i % cw, y = py0 + i / cw;
        if (x >= im->w) x = im->w - 1;
        if (y >= im->h) y = im->h - 1;
        px[i] = im->rgba + ((size_t)y * (size_t)im->w + (size_t)x) * 4;
        lum[i] = (px[i][0] * 3 + px[i][1] * 6 + px[i][2]) / 10;
        if (lum[i] < lo) lo = lum[i];
        if (lum[i] > hi) hi = lum[i];
        sum += lum[i];
      }
      int mean = sum / npx;
      unsigned mask = 0;
      int f[3] = {0, 0, 0}, b[3] = {0, 0, 0}, nf = 0, nb = 0;
      for (int i = 0; i < npx; i++) {
        int bright = hi - lo >= 12 && lum[i] > mean;
        if (bright) mask |= 1u << i;
        int *acc = bright ? f : b;
        acc[0] += px[i][0];
        acc[1] += px[i][1];
        acc[2] += px[i][2];
        if (bright) nf++;
        else nb++;
      }
      if (nf) ncplane_set_fg_rgb8(n, (unsigned)(f[0] / nf), (unsigned)(f[1] / nf), (unsigned)(f[2] / nf));
      if (nb) ncplane_set_bg_rgb8(n, (unsigned)(b[0] / nb), (unsigned)(b[1] / nb), (unsigned)(b[2] / nb));
      char utf[8];
      utf[utf8_encode(utf, glyph_for(mode, mask))] = '\0';
      ncplane_putegc_yx(n, body.y + cy, body.x + cx, utf, NULL);
    }
  }
}

/* Real pixels go through a notcurses plane, redrawn only when they change. */
static void blit_pixels(struct pstate *ps, struct rect body) {
  struct tui *t = ps->t;
  if (ps->plane && memcmp(&ps->plane_r, &body, sizeof body) != 0) drop_plane(ps);
  if (!ps->plane) {
    struct ncplane_options po = {.y = body.y, .x = body.x, .rows = (unsigned)body.h,
                                 .cols = (unsigned)body.w, .name = "preview"};
    ps->plane = ncplane_create(t->std, &po);
    ps->plane_r = body;
    ps->plane_valid = 0;
    if (!ps->plane) return;
  }
  if (ps->plane_valid) return;
  ncplane_erase(ps->plane);
  /* crop by pointing into the image: rowstride stays the full width */
  int leny = ps->img.h - ps->scroll_px, lenx = ps->img.w - ps->scroll_x;
  if (leny > body.h * ps->cell_h) leny = body.h * ps->cell_h;
  if (lenx > body.w * ps->cell_w) lenx = body.w * ps->cell_w;
  const unsigned char *origin =
    ps->img.rgba + ((size_t)ps->scroll_px * (size_t)ps->img.w + (size_t)ps->scroll_x) * 4;
  struct ncvisual *v = ncvisual_from_rgba(origin, leny, ps->img.w * 4, lenx);
  if (v) {
    struct ncvisual_options vo = {.n = ps->plane, .scaling = NCSCALE_NONE,
                                  .blitter = NCBLIT_PIXEL};
    ncvisual_blit(t->nc, v, &vo);
    ncvisual_destroy(v);
  }
  ps->plane_valid = 1;
}

static void draw_image(struct pstate *ps, struct rect body, enum imode mode) {
  int max_y = ps->img.h - body.h * ps->cell_h, max_x = ps->img.w - body.w * ps->cell_w;
  if (ps->scroll_px > max_y) ps->scroll_px = max_y;
  if (ps->scroll_px < 0) ps->scroll_px = 0;
  if (ps->scroll_x > max_x) ps->scroll_x = max_x;
  if (ps->scroll_x < 0) ps->scroll_x = 0;
  if (mode == IMG_PIXEL) {
    blit_pixels(ps, body);
  } else {
    drop_plane(ps);
    blit_cells(ps, body, mode);
  }
}

/* ---- drawing ---- */

static void *create(struct tui *t) {
  struct pstate *ps = xcalloc(1, sizeof *ps);
  ps->t = t;
  ps->page = 1;
  ps->zoom = 1;
  ps->graphic = !strcmp(t->app->cfg.preview, "image");
  return ps;
}

static void destroy(struct tui *t, void *state) {
  struct pstate *ps = state;
  if (t->drag == ps) t->drag = NULL; /* a drag under way ends with its window */
  if (t->nc) drop_plane(ps);
  ps->plane = NULL;
  if (ps->job_running) ps->dead = 1; /* freed when the job reports back */
  else pstate_free(ps);
}

static void hide(struct tui *t, void *state) {
  drop_plane(state);
}

static void draw(struct tui *t, void *state, struct rect r, int focused) {
  struct pstate *ps = state;
  struct ncplane *n = t->std;
  sqlite3_int64 cur = rows_current(t);
  if (cur != ps->book || ps->rows_gen != t->rows.gen) {
    int same = cur == ps->book;
    int page = ps->page, scroll = ps->scroll;
    load_book(ps, cur);
    ps->rows_gen = t->rows.gen;
    if (same && page <= (ps->npages > 0 ? ps->npages : 1)) { /* a refresh, not a move */
      ps->page = page;
      load_page(ps);
      ps->scroll = scroll;
    }
  }

  int y = r.y, x = r.x + 1, w = r.w - 2;
  if (w < 4) return;
  if (!ps->book) {
    drop_plane(ps);
    dr_bar(n, r, focused);
    dr_style(n, theme.dim, C_DEFAULT, 0);
    dr_text(n, y + 1, x, w, "nothing selected");
    return;
  }

  dr_bar(n, r, focused);
  dr_text(n, y++, x, w, ps->title ? ps->title : "(no title)");
  if (ps->authors && strcmp(ps->authors, "Unknown") && strcmp(ps->authors, "()")) {
    dr_style(n, C_DEFAULT, C_DEFAULT, 0);
    dr_text(n, y++, x, w, ps->authors);
  } else {
    dr_style(n, theme.warn, C_DEFAULT, 0);
    dr_text(n, y++, x, w, "unknown author");
  }

  sbuf line = SBUF_INIT;
  if (ps->tags) sb_puts(&line, ps->tags);
  if (ps->year) sb_printf(&line, "%s%s", line.len ? "  ·  " : "", ps->year);
  if (ps->pub) sb_printf(&line, "%s%s", line.len ? "  ·  " : "", ps->pub);
  dr_style(n, ps->tags ? theme.accent : theme.dim, C_DEFAULT, 0);
  dr_text(n, y++, x, w, line.len ? line.s : "no subject, date or publisher");

  sb_reset(&line);
  if (ps->fmt) sb_puts(&line, ps->fmt);
  if (ps->npages > 0) sb_printf(&line, "  %d pp", ps->npages);
  if (ps->idents) sb_printf(&line, "  ·  %s", ps->idents);
  if (ps->etitle || ps->eauthor)
    sb_printf(&line, "  ·  embedded: %s%s%s", ps->eauthor ? ps->eauthor : "",
              ps->eauthor && ps->etitle ? ", " : "", ps->etitle ? ps->etitle : "");
  dr_style(n, theme.dim, C_DEFAULT, 0);
  dr_text(n, y++, x, w, line.len ? line.s : "no file");

  /* Settle the image question before drawing the rule, which reports it. */
  int overlay = t->picker != NULL || t->help != NULL;
  int want_image = ps->graphic && ps->file && ps->fstatus != FILE_MISSING;
  enum imode imode = IMG_HALF;
  int have_image = want_image && image_ready(ps, w, &imode);

  /* the rule between metadata and page, carrying page number and state */
  sb_reset(&line);
  const char *state_note = NULL;
  if (!ps->file) state_note = "no file on record";
  else if (ps->fstatus == FILE_MISSING) state_note = "file missing on disk";
  else if (ps->fstatus == FILE_ERROR) state_note = ps->ferror ? ps->ferror : "could not be read";
  else if (ps->fstatus == FILE_PENDING) state_note = "not indexed yet";
  sb_printf(&line, "── page %d", ps->page);
  if (ps->npages > 0) sb_printf(&line, "/%d", ps->npages);
  if (ps->skipped && ps->page == ps->first_text) sb_puts(&line, ", the first with text");
  if (ps->graphic && ps->zoom > 1) sb_printf(&line, " ── image ×%d ", ps->zoom);
  else sb_printf(&line, " ── %s ", ps->graphic ? "image" : "text");
  if (state_note) sb_printf(&line, "── %s ", state_note);
  if (ps->graphic && ps->job_running) sb_puts(&line, "── rendering… ");
  if (ps->graphic && ps->job_error) sb_printf(&line, "── %s ", ps->job_error);
  while (dr_width(line.s, line.len) < w) sb_puts(&line, "─");
  dr_style(n, state_note ? theme.warn : theme.border, C_DEFAULT, 0);
  dr_text(n, y++, x, w, line.s);
  sb_free(&line);

  struct rect body = {y, x, r.y + r.h - y, w};
  if (body.h < 1) {
    drop_plane(ps);
    return;
  }
  if (have_image && !overlay) {
    draw_image(ps, body, imode);
    return;
  }
  drop_plane(ps);

  ps->body.h = 0;
  int blank = 1; /* nothing but white space counts as no text */
  for (const char *c = ps->text; c && *c && blank; c++) blank = *c == ' ' || *c == '\n' || *c == '\f';
  if (blank) {
    /* say why there is nothing to read, and what would show it */
    dr_style(n, theme.dim, C_DEFAULT, 0);
    if (ps->file && ps->fstatus == FILE_OK) {
      const char *why, *then;
      char buf[160], image[96], past[160], scan[200];
      snprintf(image, sizeof image, "%s shows the page as an image.", key_hint("preview graphic"));
      snprintf(past, sizeof past, "(the option `pages`). %s", image);
      snprintf(scan, sizeof scan, ":ocr reads the first pages with tesseract. %s", image);
      then = image;
      if (ps->page > ps->indexed) {
        snprintf(buf, sizeof buf, "Page %d is past the first %d pages, which is all lulibre indexes",
                 ps->page, ps->indexed);
        why = buf;
        then = past;
      } else if (!ps->first_text) {
        why = "This file has no text in its first pages: it is a scan without a text layer.";
        then = scan;
      } else {
        snprintf(buf, sizeof buf, "No text on this page. Page %d has some: %s and %s turn pages.", ps->first_text,
                 key_hint("preview page +1"), key_hint("preview page -1"));
        why = buf;
      }
      int row = 0;
      for (const char *part = why; part; part = part == why ? then : NULL) {
        size_t len = strlen(part), off = 0;
        while (off < len && row < body.h) {
          size_t take = dr_wrap(part + off, len - off, w);
          dr_textn(n, body.y + row++, x, w, part + off, take);
          off += take;
          while (off < len && part[off] == ' ') off++;
        }
      }
    }
    return;
  }
  wrap(ps, w);
  int max_scroll = ps->nwl - body.h;
  if (max_scroll < 0) max_scroll = 0;
  if (ps->scroll > max_scroll) ps->scroll = max_scroll;
  if (ps->scroll < 0) ps->scroll = 0;
  ps->body = body;
  for (int i = 0; i < body.h && ps->scroll + i < ps->nwl; i++) {
    struct wline *l = &ps->wl[ps->scroll + i];
    long a = l->p - ps->text, b = a + l->len;
    dr_style(n, C_DEFAULT, C_DEFAULT, 0);
    if (ps->sel_hi <= ps->sel_lo || ps->sel_hi <= a || ps->sel_lo >= b) {
      dr_textn(n, body.y + i, x, w, l->p, (size_t)l->len);
      continue;
    }
    /* the selected stretch of this line, between what is before and after */
    size_t s1 = (size_t)((ps->sel_lo > a ? ps->sel_lo : a) - a);
    size_t s2 = (size_t)((ps->sel_hi < b ? ps->sel_hi : b) - a);
    int cx = x + dr_textn(n, body.y + i, x, w, l->p, s1);
    dr_style(n, C_DEFAULT, theme.visual_bg, 0);
    cx += dr_textn(n, body.y + i, cx, w - (cx - x), l->p + s1, s2 - s1);
    dr_style(n, C_DEFAULT, C_DEFAULT, 0);
    dr_textn(n, body.y + i, cx, w - (cx - x), l->p + s2, (size_t)l->len - s2);
  }
}

/* ---- selecting text with the mouse ---- */

/* The bytes of the character under a cell: [*lo, *hi). Past the end of a
 * line it is the empty stretch at the line's end. */
static void cell_bytes(struct pstate *ps, int y, int x, long *lo, long *hi) {
  int row = ps->scroll + (y - ps->body.y);
  if (row < 0) row = 0;
  if (row >= ps->nwl) row = ps->nwl - 1;
  struct wline *l = &ps->wl[row];
  int col = x - ps->body.x;
  size_t at = col <= 0 ? 0 : dr_bytes_for_cols(l->p, (size_t)l->len, col);
  *lo = (l->p - ps->text) + (long)at;
  if (y < ps->body.y) at = 0, *lo = l->p - ps->text;
  if (y >= ps->body.y + ps->body.h) at = (size_t)l->len, *lo = (l->p - ps->text) + l->len;
  *hi = *lo;
  if (at < (size_t)l->len) {
    unsigned cp;
    *hi += utf8_decode(l->p + at, (size_t)l->len - at, &cp);
  }
}

static void copy_selection(struct tui *t, struct pstate *ps) {
  if (ps->sel_hi <= ps->sel_lo) return;
  size_t n = (size_t)(ps->sel_hi - ps->sel_lo);
  int chars = dr_width(ps->text + ps->sel_lo, n);
  if (clip_copy(ps->text + ps->sel_lo, n))
    tui_msg(t, 0, "copied %d character%s   (<C-v> pastes into a field)", chars, chars == 1 ? "" : "s");
  else
    tui_msg(t, 1, "selected, but the terminal did not take the copy; <C-v> still pastes it inside lulibre");
}

int preview_mouse(struct tui *t, void *state, int y, int x, int what) {
  struct pstate *ps = state;
  if (ps->graphic || !ps->text || ps->nwl == 0 || ps->body.h <= 0) {
    ps->selecting = 0;
    return 0;
  }
  long lo, hi;
  if (what == 0) { /* press */
    if (y < ps->body.y || y >= ps->body.y + ps->body.h) return 0;
    double now = now_s();
    ps->clicks = now - ps->click_at < 0.4 && y == ps->click_y && x == ps->click_x ? ps->clicks + 1 : 1;
    ps->click_at = now;
    ps->click_y = y;
    ps->click_x = x;
    cell_bytes(ps, y, x, &lo, &hi);
    const char *s = ps->text;
    if (ps->clicks == 2) { /* the word: up to white space, less the punctuation around it */
      while (lo > 0 && !strchr(" \n\t", s[lo - 1])) lo--;
      while (s[hi] && !strchr(" \n\t", s[hi])) hi++;
      while (lo < hi && strchr("([{\"'", s[lo])) lo++;
      while (hi > lo && strchr(".,;:)]}\"'", s[hi - 1])) hi--;
    } else if (ps->clicks >= 3) { /* the line as it stands in the file */
      while (lo > 0 && s[lo - 1] != '\n') lo--;
      while (s[hi] && s[hi] != '\n') hi++;
    }
    if (ps->clicks >= 2) {
      ps->sel_lo = lo;
      ps->sel_hi = hi;
      ps->selecting = 0;
      copy_selection(t, ps);
      tui_dirty(t);
      return 0;
    }
    ps->anchor_lo = lo;
    ps->anchor_hi = hi;
    ps->sel_lo = ps->sel_hi = lo; /* nothing until the pointer moves */
    ps->selecting = 1;
    tui_dirty(t);
    return 1;
  }
  if (!ps->selecting) return 0;
  /* dragging past the top or bottom scrolls */
  if (y < ps->body.y && ps->scroll > 0) ps->scroll--;
  if (y >= ps->body.y + ps->body.h && ps->scroll < ps->nwl - ps->body.h) ps->scroll++;
  cell_bytes(ps, y, x, &lo, &hi);
  if (lo != ps->anchor_lo || what == 1) {
    ps->sel_lo = lo < ps->anchor_lo ? lo : ps->anchor_lo;
    ps->sel_hi = hi > ps->anchor_hi ? hi : ps->anchor_hi;
  }
  tui_dirty(t);
  if (what == 2) {
    ps->selecting = 0;
    if (lo == ps->anchor_lo && ps->sel_hi - ps->sel_lo <= ps->anchor_hi - ps->anchor_lo) {
      ps->sel_lo = ps->sel_hi = 0; /* a plain click selects nothing */
      return 0;
    }
    copy_selection(t, ps);
    return 0;
  }
  return 1;
}

const struct view_class view_preview = {"preview", create, destroy, draw, hide};

/* ---- commands act on the focused preview, else the first one ---- */

static struct pstate *target(struct tui *t) {
  struct node *nd = wm_find(t, &view_preview);
  return nd ? nd->state : NULL;
}

void preview_scroll(struct tui *t, int delta) {
  struct pstate *ps = target(t);
  if (!ps) return;
  if (ps->graphic && ps->img.rgba) {
    ps->scroll_px += delta * (ps->cell_h > 0 ? ps->cell_h : 1);
    ps->plane_valid = 0;
  } else {
    ps->scroll += delta;
  }
  tui_dirty(t);
}

void preview_pan(struct tui *t, int delta) {
  struct pstate *ps = target(t);
  if (!ps || !ps->graphic) return;
  ps->scroll_x += delta * (ps->cell_w > 0 ? ps->cell_w : 1);
  ps->plane_valid = 0;
  tui_dirty(t);
}

void preview_zoom(struct tui *t, int delta) {
  struct pstate *ps = target(t);
  if (!ps) return;
  int z = delta == 0 ? 1 : ps->zoom + delta;
  if (z < 1) z = 1;
  if (z > 8) z = 8;
  if (z == ps->zoom) return;
  /* keep roughly the same part of the page in view */
  ps->scroll_px = ps->scroll_px * z / ps->zoom;
  ps->scroll_x = ps->scroll_x * z / ps->zoom;
  ps->zoom = z;
  if (!ps->graphic) ps->graphic = 1;
  t->settled = 1;
  tui_dirty(t);
}

void preview_page(struct tui *t, int delta) {
  struct pstate *ps = target(t);
  if (!ps || !ps->file) return;
  int last = ps->npages > 0 ? ps->npages : ps->indexed;
  int page = ps->page + delta;
  if (page > last) page = last;
  if (page < 1) page = 1;
  if (page == ps->page) return;
  ps->page = page;
  free(ps->job_error);
  ps->job_error = NULL;
  load_page(ps);
  preview_book_changed(t);
}

void preview_toggle_graphic(struct tui *t) {
  struct pstate *ps = target(t);
  if (!ps) return;
  ps->graphic = !ps->graphic;
  free(ps->job_error);
  ps->job_error = NULL;
  if (!ps->graphic) drop_plane(ps);
  t->settled = 1; /* an explicit request: do not wait for the cursor to rest */
  tui_dirty(t);
}

static void settle_cb(uv_timer_t *h) {
  struct tui *t = h->data;
  t->settled = 1;
  tui_dirty(t);
}

void preview_book_changed(struct tui *t) {
  t->settled = 0;
  uv_timer_start(&t->settle, settle_cb, 90, 0);
  tui_dirty(t);
}
