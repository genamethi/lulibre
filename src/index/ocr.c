#include "index/ocr.h"

#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "core/util.h"

extern char **environ;

/* Pixels across a rendered page: about 300 dpi for a letter or A4 page. */
enum { OCR_WIDTH = 2480 };

char *ocr_find(void) {
  const char *path = getenv("PATH");
  for (const char *p = path ? path : ""; *p;) {
    const char *end = strchr(p, ':');
    size_t n = end ? (size_t)(end - p) : strlen(p);
    char *exe = xasprintf("%.*s/tesseract", (int)n, p);
    if (n && access(exe, X_OK) == 0) return exe;
    free(exe);
    p += n + (end ? 1 : 0);
  }
  return NULL;
}

/* The image as a greyscale PGM in a file of its own; its path, malloc'd. */
static char *write_pgm(const struct doc_image *img, char **err) {
  const char *dir = getenv("TMPDIR");
  char *path = xasprintf("%s/lulibre-ocr-XXXXXX", dir && dir[0] ? dir : "/tmp");
  int fd = mkstemp(path);
  FILE *f = fd >= 0 ? fdopen(fd, "wb") : NULL;
  if (!f) {
    *err = xasprintf("a file for the page image: %s", errstr(errno));
    if (fd >= 0) close(fd);
    free(path);
    return NULL;
  }
  fprintf(f, "P5\n%d %d\n255\n", img->w, img->h);
  unsigned char *row = xmalloc((size_t)img->w);
  for (int y = 0; y < img->h; y++) {
    const unsigned char *px = img->rgba + (size_t)y * img->w * 4;
    for (int x = 0; x < img->w; x++, px += 4) row[x] = (unsigned char)((px[0] * 299 + px[1] * 587 + px[2] * 114) / 1000);
    fwrite(row, 1, (size_t)img->w, f);
  }
  free(row);
  if (fclose(f) != 0) {
    *err = xasprintf("writing the page image: %s", errstr(errno));
    remove(path);
    free(path);
    return NULL;
  }
  return path;
}

/* tesseract IMAGE stdout -l LANG tsv: its output, malloc'd, or NULL. */
static char *run_tesseract(const char *tesseract, const char *image, const char *lang, char **err) {
  int out[2];
  if (pipe(out) != 0) {
    *err = xasprintf("pipe: %s", errstr(errno));
    return NULL;
  }
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, out[1], 1);
  posix_spawn_file_actions_addclose(&fa, out[0]);
  posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", 0, 0);
  char *argv[] = {(char *)"tesseract", (char *)image, (char *)"stdout", (char *)"-l", (char *)lang, (char *)"tsv", NULL};
  pid_t pid;
  int rc = posix_spawn(&pid, tesseract, &fa, NULL, argv, environ);
  posix_spawn_file_actions_destroy(&fa);
  close(out[1]);
  if (rc != 0) {
    close(out[0]);
    *err = xasprintf("tesseract: %s", errstr(rc));
    return NULL;
  }
  sbuf b = SBUF_INIT;
  char buf[8192];
  ssize_t n;
  while ((n = read(out[0], buf, sizeof buf)) > 0 || (n < 0 && errno == EINTR))
    if (n > 0) sb_putn(&b, buf, (size_t)n);
  close(out[0]);
  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
  }
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    *err = xasprintf("tesseract failed (language %s?)", lang);
    sb_free(&b);
    return NULL;
  }
  return sb_take(&b);
}

struct oline {
  char *text;
  int block, par;
  float x0, y0, x1, y1;
};

static int cmp_float(const void *a, const void *b) {
  float x = *(const float *)a, y = *(const float *)b;
  return (x > y) - (x < y);
}

/* Which lines start a paragraph: tesseract's own paragraph changing within
 * a block, a gap above the line well over the page's usual gap between
 * lines (its lower quartile), or the line's height changing by more than a
 * quarter. tesseract often makes each line a block of its own, so a block
 * alone says little. */
static void paragraphs(struct oline *l, int n, unsigned *starts) {
  float *gaps = xmalloc((size_t)(n > 1 ? n - 1 : 1) * sizeof *gaps);
  int ng = 0;
  for (int i = 1; i < n; i++)
    if (l[i].y0 > l[i - 1].y1) gaps[ng++] = l[i].y0 - l[i - 1].y1;
  qsort(gaps, (size_t)ng, sizeof *gaps, cmp_float);
  float usual = ng ? gaps[ng / 4] : 0;
  free(gaps);
  for (int i = 0; i < n; i++) {
    if (i == 0) {
      starts[i] = 1;
      continue;
    }
    float h = l[i].y1 - l[i].y0, ph = l[i - 1].y1 - l[i - 1].y0, gap = l[i].y0 - l[i - 1].y1;
    int par = l[i].block == l[i - 1].block && l[i].par != l[i - 1].par;
    int wide = ng && gap > usual * 1.5f + 1;
    int size = ph > 0 && (h > ph * 1.25f || h < ph * 0.8f);
    starts[i] = par || wide || size;
  }
}

/* tesseract's TSV, a row per word: level page block par line word left top
 * width height conf text. The words of one line become a line. scale:
 * points per pixel. */
static void lines_of(char *tsv, float scale, struct doc_page *pg) {
  struct oline *l = NULL;
  int n = 0, cap = 0, cur_block = -1, cur_par = -1, cur_line = -1;
  sbuf text = SBUF_INIT;
  char *save = NULL; /* strtok_r: workers read pages at once */
  for (char *row = strtok_r(tsv, "\n", &save); row; row = strtok_r(NULL, "\n", &save)) {
    int level, pageno, block, par, line, word, left, top, width, height;
    float conf;
    int used = 0;
    if (sscanf(row, "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%f\t%n", &level, &pageno, &block, &par, &line, &word, &left,
               &top, &width, &height, &conf, &used) < 11 || level != 5 || !used)
      continue;
    const char *w = row + used;
    if (!*w || conf < 0) continue;
    float x0 = left * scale, y0 = top * scale, x1 = (left + width) * scale, y1 = (top + height) * scale;
    if (block != cur_block || par != cur_par || line != cur_line) {
      if (n == cap) {
        cap = cap ? cap * 2 : 32;
        l = xrealloc(l, (size_t)cap * sizeof *l);
      }
      if (n) l[n - 1].text = sb_take(&text);
      l[n++] = (struct oline){NULL, block, par, x0, y0, x1, y1};
      cur_block = block, cur_par = par, cur_line = line;
    } else {
      sb_putc(&text, ' ');
    }
    sb_puts(&text, w);
    struct oline *o = &l[n - 1];
    if (x0 < o->x0) o->x0 = x0;
    if (y0 < o->y0) o->y0 = y0;
    if (x1 > o->x1) o->x1 = x1;
    if (y1 > o->y1) o->y1 = y1;
  }
  if (n) l[n - 1].text = sb_take(&text);
  sb_free(&text);
  unsigned *starts = xcalloc((size_t)(n ? n : 1), sizeof *starts);
  paragraphs(l, n, starts);
  for (int i = 0; i < n; i++)
    doc_page_add_line(pg, l[i].text, l[i].y1 - l[i].y0, starts[i] ? LINE_BLOCK : 0, l[i].x0, l[i].y0, l[i].x1, l[i].y1);
  free(starts);
  free(l);
}

int ocr_page(const char *tesseract, const char *path, int page, const char *lang, struct doc_page *out,
             char **err) {
  struct doc_image img = {0};
  doc_render(path, page, OCR_WIDTH, 1.0f, &img);
  if (img.error) {
    *err = img.error;
    return -1;
  }
  char *image = write_pgm(&img, err);
  float scale = out->w > 0 && img.w > 0 ? out->w / (float)img.w : 72.0f / 300.0f;
  doc_image_free(&img);
  if (!image) return -1;
  char *tsv = run_tesseract(tesseract, image, lang, err);
  remove(image);
  free(image);
  if (!tsv) return -1;
  lines_of(tsv, scale, out);
  free(tsv);
  doc_page_finish(out);
  return 0;
}

void ocr_req_free(struct ocr_req *req) {
  if (!req) return;
  if (req->out)
    for (int i = 0; i < req->n; i++) doc_page_free(&req->out[i]);
  free(req->out);
  free(req->ok);
  free(req->pages);
  free(req->w);
  free(req->h);
  free(req->path);
  free(req->lang);
  free(req->err);
  free(req);
}
