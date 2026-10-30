/* Windows: a binary tree of splits whose leaves are views, and above it a
 * few floating windows (wm_float): boxes, or one over the whole area. */
#include <stdlib.h>
#include <string.h>

#include "tui/tui.h"

static const struct view_class *const classes[] = {&view_list, &view_preview};

static void close_node(struct tui *t, struct node *n);

static const struct view_class *wm_class(const char *name) {
  for (size_t i = 0; i < ARRAY_LEN(classes); i++)
    if (strcmp(classes[i]->name, name) == 0) return classes[i];
  return NULL;
}

static struct node *leaf_new(struct tui *t, const struct view_class *cls) {
  struct node *n = xcalloc(1, sizeof *n);
  n->cls = cls;
  n->state = cls->create ? cls->create(t) : NULL;
  return n;
}

static void node_free(struct tui *t, struct node *n) {
  if (!n) return;
  if (n->split) {
    node_free(t, n->a);
    node_free(t, n->b);
  } else {
    if (n->cls->destroy) n->cls->destroy(t, n->state);
    if (n->under_cls && n->under_cls->destroy) n->under_cls->destroy(t, n->under_state);
  }
  free(n);
}

void wm_init(struct tui *t) {
  struct node *root = xcalloc(1, sizeof *root);
  root->split = 'v';
  root->ratio = 0.56f;
  root->a = leaf_new(t, &view_list);
  root->b = leaf_new(t, &view_preview);
  root->a->parent = root->b->parent = root;
  t->root = root;
  t->focus = root->a;
}

void wm_free(struct tui *t) {
  node_free(t, t->root);
  for (int i = 0; i < t->nfloats; i++) node_free(t, t->floats[i]);
  t->nfloats = 0;
  t->root = t->focus = NULL;
}

/* Nothing but previews of a book under this node. */
static int only_preview(const struct node *n) {
  if (!n->split) return n->cls == &view_preview;
  return only_preview(n->a) && only_preview(n->b);
}

/* bare: the bar's Configuration tab is open, and a book's preview beside it
 * gets no room (draw() then takes it off the screen). */
static void layout(struct node *n, struct rect r, int bare) {
  n->r = r;
  if (!n->split) return;
  if (bare && n->split == 'v' && only_preview(n->a) != only_preview(n->b)) {
    struct node *keep = only_preview(n->a) ? n->b : n->a, *drop = keep == n->a ? n->b : n->a;
    layout(keep, r, bare);
    layout(drop, (struct rect){r.y, r.x + r.w, r.h, 0}, bare);
    return;
  }
  if (n->split == 'v') {
    int wa = (int)((float)(r.w - 1) * n->ratio);
    if (wa < 1) wa = 1;
    if (wa > r.w - 2) wa = r.w - 2 > 1 ? r.w - 2 : 1;
    layout(n->a, (struct rect){r.y, r.x, r.h, wa}, bare);
    layout(n->b, (struct rect){r.y, r.x + wa + 1, r.h, r.w - wa - 1}, bare);
  } else {
    int ha = (int)((float)r.h * n->ratio);
    if (ha < 1) ha = 1;
    if (ha > r.h - 1) ha = r.h - 1 > 1 ? r.h - 1 : 1;
    layout(n->a, (struct rect){r.y, r.x, ha, r.w}, bare);
    layout(n->b, (struct rect){r.y + ha, r.x, r.h - ha, r.w}, bare);
  }
}

void wm_layout(struct tui *t, struct rect area) {
  layout(t->root, area, t->screen_tab != NULL);
  for (int i = 0; i < t->nfloats; i++) {
    struct node *f = t->floats[i];
    if (f->full) {
      f->r = area;
      continue;
    }
    /* a box: its share of the area, at least a bar and a few rows, and the
     * view inside the frame */
    int w = (int)((float)area.w * f->fsize), h = (int)((float)area.h * f->fsize);
    if (w < 24) w = area.w < 24 ? area.w : 24;
    if (h < 6) h = area.h < 6 ? area.h : 6;
    int y = area.y + (area.h - h) / 2, x = area.x + (area.w - w) / 2;
    f->r = (struct rect){y + 1, x + 1, h - 2 > 0 ? h - 2 : 0, w - 2 > 0 ? w - 2 : 0};
  }
}

static void draw(struct tui *t, struct node *n) {
  if (!n->split) {
    if (n->r.w > 0 && n->r.h > 0) n->cls->draw(t, n->state, n->r, n == t->focus);
    else if (n->cls->hide) n->cls->hide(t, n->state); /* no room: take down what it left on screen */
    return;
  }
  draw(t, n->a);
  draw(t, n->b);
  if (n->split == 'v' && n->a->r.w > 0 && n->b->r.w > 0) {
    /* the line between them; the stretch beside the focused window is lit */
    int x = n->a->r.x + n->a->r.w;
    const struct rect *f = t->focus ? &t->focus->r : NULL;
    int beside = f && (f->x + f->w == x || f->x == x + 1);
    for (int y = n->r.y; y < n->r.y + n->r.h; y++) {
      int lit = beside && y >= f->y && y < f->y + f->h;
      dr_style(t->std, lit ? theme.accent : theme.border, C_DEFAULT, 0);
      ncplane_putstr_yx(t->std, y, x, "│");
    }
  }
}

void wm_draw(struct tui *t) {
  draw(t, t->root);
  for (int i = 0; i < t->nfloats; i++) {
    struct node *f = t->floats[i];
    if (!f->full) dr_frame(t->std, (struct rect){f->r.y - 1, f->r.x - 1, f->r.h + 2, f->r.w + 2}, C_DEFAULT);
    else
      for (int y = 0; y < f->r.h; y++) { /* nothing of the windows under it shows through */
        dr_style(t->std, C_DEFAULT, C_DEFAULT, 0);
        dr_fill(t->std, f->r.y + y, f->r.x, f->r.w);
      }
    draw(t, f);
  }
}

static void leaves(struct node *n, struct node **out, int *count) {
  if (!n->split) {
    if (*count < 32) out[(*count)++] = n;
    return;
  }
  leaves(n->a, out, count);
  leaves(n->b, out, count);
}

/* the tree's leaves, then the floating windows */
static void all_leaves(struct tui *t, struct node **out, int *count) {
  if (t->root) leaves(t->root, out, count);
  for (int i = 0; i < t->nfloats && *count < 32; i++) out[(*count)++] = t->floats[i];
}

/* A floating window goes: its view with it (destroy), or kept (a hidden
 * panel's). The focus goes back to a window of the tree. */
static void unfloat(struct tui *t, struct node *f, int destroy) {
  int at = -1;
  for (int i = 0; i < t->nfloats; i++)
    if (t->floats[i] == f) at = i;
  if (at < 0) return;
  memmove(&t->floats[at], &t->floats[at + 1], (size_t)(t->nfloats - at - 1) * sizeof *t->floats);
  t->nfloats--;
  if (t->focus == f) {
    struct node *back = t->nfloats ? t->floats[t->nfloats - 1] : NULL;
    if (!back && t->last_window) back = wm_leaf_of(t, t->last_window);
    if (!back) {
      back = t->root;
      while (back->split) back = back->a;
    }
    t->focus = back;
  }
  if (destroy && f->cls->destroy) f->cls->destroy(t, f->state);
  else if (f->cls->hide) f->cls->hide(t, f->state);
  free(f);
  tui_dirty(t);
}

struct node *wm_float(struct tui *t, const struct view_class *cls, void *state, float size, int full) {
  if (t->nfloats == (int)ARRAY_LEN(t->floats)) unfloat(t, t->floats[0], 1); /* the oldest makes room */
  struct node *f = xcalloc(1, sizeof *f);
  f->cls = cls;
  f->state = state;
  f->floating = 1;
  f->full = full;
  f->fsize = size > 0.1f && size <= 1.0f ? size : 0.6f;
  t->floats[t->nfloats++] = f;
  t->focus = f;
  tui_dirty(t);
  return f;
}

int wm_leaves(struct tui *t, struct node **out, int max) {
  struct node *all[32];
  int n = 0;
  if (!t->root) return 0;
  all_leaves(t, all, &n);
  if (n > max) n = max;
  memcpy(out, all, (size_t)n * sizeof *out);
  return n;
}

struct node *wm_leaf_of(struct tui *t, void *state) {
  struct node *all[32];
  int n = 0;
  if (!state) return NULL;
  all_leaves(t, all, &n);
  for (int i = 0; i < n; i++)
    if (all[i]->state == state) return all[i];
  return NULL;
}

struct node *wm_at(struct tui *t, int y, int x) {
  struct node *all[32];
  int n = 0;
  for (int i = t->nfloats - 1; i >= 0; i--) { /* the top one first; a box's frame is its own */
    struct node *f = t->floats[i];
    struct rect r = f->full ? f->r : (struct rect){f->r.y - 1, f->r.x - 1, f->r.h + 2, f->r.w + 2};
    if (y >= r.y && y < r.y + r.h && x >= r.x && x < r.x + r.w) return f;
  }
  leaves(t->root, all, &n);
  for (int i = 0; i < n; i++) {
    const struct rect *r = &all[i]->r;
    if (y >= r->y && y < r->y + r->h && x >= r->x && x < r->x + r->w) return all[i];
  }
  return NULL;
}

struct node *wm_find(struct tui *t, const struct view_class *cls) {
  struct node *all[32];
  int n = 0;
  all_leaves(t, all, &n);
  if (t->focus && t->focus->cls == cls) return t->focus;
  for (int i = 0; i < n; i++)
    if (all[i]->cls == cls) return all[i];
  return NULL;
}

int wm_split(struct tui *t, char dir, const char *view) {
  const struct view_class *cls = view && *view ? wm_class(view) : t->focus->cls;
  /* a panel is a script's, not something a window can be made of; a
   * floating window is not split */
  if (!cls || !cls->create || t->focus->floating) return -1;
  struct node *old = t->focus;
  /* the focused leaf becomes a split holding itself and the new view */
  struct node *moved = xcalloc(1, sizeof *moved);
  *moved = *old;
  moved->parent = old;
  struct node *fresh = leaf_new(t, cls);
  fresh->parent = old;
  old->split = dir == 'h' ? 'h' : 'v';
  old->ratio = 0.5f;
  old->a = moved;
  old->b = fresh;
  old->cls = NULL;
  old->state = NULL;
  t->focus = fresh;
  tui_dirty(t);
  return 0;
}

struct node *wm_tile(struct tui *t, const struct view_class *cls, void *state, float size) {
  struct node *old = t->focus;
  if (!old || old->floating) old = t->last_window ? wm_leaf_of(t, t->last_window) : NULL;
  if (!old || old->floating) {
    old = t->root;
    while (old->split) old = old->a;
  }
  struct node *moved = xcalloc(1, sizeof *moved);
  *moved = *old;
  moved->parent = old;
  struct node *fresh = xcalloc(1, sizeof *fresh);
  fresh->cls = cls;
  fresh->state = state;
  fresh->parent = old;
  old->split = 'v';
  old->ratio = 1.0f - (size > 0.1f && size < 0.9f ? size : 0.5f);
  old->a = moved;
  old->b = fresh;
  old->cls = NULL;
  old->state = NULL;
  old->under_cls = NULL;
  old->under_state = NULL;
  if (moved->split) moved->a->parent = moved->b->parent = moved;
  t->focus = fresh;
  tui_dirty(t);
  return fresh;
}

/* Is `n` inside the subtree at `root`? */
static int within(const struct node *root, const struct node *n) {
  for (; n; n = n->parent)
    if (n == root) return 1;
  return 0;
}

static void close_node(struct tui *t, struct node *n) {
  if (!n->split && n->under_cls) {
    /* a view shown over the list: closing it brings the list back */
    if (n->cls->destroy) n->cls->destroy(t, n->state);
    n->cls = n->under_cls;
    n->state = n->under_state;
    n->under_cls = NULL;
    n->under_state = NULL;
    tui_dirty(t);
    return;
  }
  struct node *p = n->parent;
  struct node *sib = p->a == n ? p->b : p->a;
  int had_focus = within(n, t->focus);
  struct node *focus = t->focus; /* stays valid unless it was inside n or is sib itself */
  int focus_is_sib = focus == sib;
  node_free(t, n);
  struct node *gp = p->parent;
  struct rect r = p->r;
  *p = *sib; /* the sibling takes the parent's place */
  p->parent = gp;
  p->r = r;
  if (p->split) p->a->parent = p->b->parent = p;
  free(sib);
  if (had_focus || focus_is_sib) {
    struct node *f = p;
    while (f->split) f = f->a;
    t->focus = f;
  }
  tui_dirty(t);
}

void wm_close(struct tui *t) {
  if (t->focus->floating) {
    unfloat(t, t->focus, 1);
    return;
  }
  if (!t->focus->parent) {
    tui_msg(t, 1, "cannot close the last window");
    return;
  }
  close_node(t, t->focus);
}

/* Closing a window frees its node and its sibling's (the sibling's contents
 * move up into their parent), so a node pointer held across a close may be
 * dangling. This closes any leaf and leaves t->focus valid whatever it was. */
void wm_close_leaf(struct tui *t, struct node *n) {
  if (n && n->floating) unfloat(t, n, 1);
  else if (n && !n->split && n->parent) close_node(t, n);
}

/* Add a full-width window along the bottom showing an existing view state. */
struct node *wm_dock(struct tui *t, const struct view_class *cls, void *state, float size, char side) {
  struct node *leaf = xcalloc(1, sizeof *leaf);
  leaf->cls = cls;
  leaf->state = state;
  struct node *root = xcalloc(1, sizeof *root);
  if (side == 'l') { /* a column down the left edge */
    root->split = 'v';
    root->ratio = size > 0.1f && size < 0.9f ? size : 0.28f;
    root->a = leaf;
    root->b = t->root;
  } else {
    root->split = 'h';
    root->ratio = 1.0f - (size > 0.1f && size < 0.9f ? size : 0.45f);
    root->a = t->root;
    root->b = leaf;
  }
  root->a->parent = root->b->parent = root;
  t->root = root;
  t->focus = leaf;
  tui_dirty(t);
  return leaf;
}

struct node *wm_over_list(struct tui *t, const struct view_class *cls, void *state) {
  struct node *stack[64], *list = NULL;
  int n = 0;
  if (t->root) stack[n++] = t->root;
  while (n && !list) {
    struct node *x = stack[--n];
    if (x->split) {
      if (n < 62) {
        stack[n++] = x->b;
        stack[n++] = x->a;
      }
    } else if (x->cls == &view_list && !x->under_cls) {
      list = x;
    }
  }
  if (!list) {
    struct node *keep = t->focus;
    struct node *leaf = wm_dock(t, cls, state, 0.4f, 'l');
    if (keep) t->focus = keep;
    return leaf;
  }
  list->under_cls = list->cls;
  list->under_state = list->state;
  list->cls = cls;
  list->state = state;
  tui_dirty(t);
  return list;
}

/* Close the window showing this state, if there is one. */
void wm_undock(struct tui *t, void *state) {
  struct node *stack[64];
  int n = 0;
  for (int i = 0; i < t->nfloats; i++)
    if (t->floats[i]->state == state) {
      unfloat(t, t->floats[i], 1);
      return;
    }
  if (!t->root) return;
  stack[n++] = t->root;
  while (n) {
    struct node *x = stack[--n];
    if (x->split) {
      if (n < 62) {
        stack[n++] = x->a;
        stack[n++] = x->b;
      }
    } else if (x->state == state) {
      if (x->under_cls) {
        /* it was shown over the list for a while: the list comes back */
        if (x->cls->destroy) x->cls->destroy(t, x->state);
        x->cls = x->under_cls;
        x->state = x->under_state;
        x->under_cls = NULL;
        x->under_state = NULL;
        tui_dirty(t);
      } else if (x->parent) {
        close_node(t, x);
      } else {
        /* It is the only window left (:only was used on it). Its view still
         * has to go, and a screen with no window is no use: the list takes
         * its place. */
        if (x->cls->destroy) x->cls->destroy(t, x->state);
        x->cls = &view_list;
        x->state = view_list.create(t);
        t->focus = x;
        tui_dirty(t);
      }
      return;
    }
  }
}

void wm_set_size(struct tui *t, void *state, float size) {
  struct node *n = wm_leaf_of(t, state);
  if (size < 0.1f) size = 0.1f;
  if (size > 0.9f) size = 0.9f;
  if (n && n->floating) {
    n->fsize = size;
    tui_dirty(t);
    return;
  }
  if (!n || !n->parent) return;
  n->parent->ratio = n->parent->a == n ? size : 1.0f - size;
  tui_dirty(t);
}

void wm_only(struct tui *t) {
  /* the floating windows go but the focused one; from one of them, the
   * tree stays as it is */
  for (int i = t->nfloats - 1; i >= 0; i--)
    if (t->floats[i] != t->focus) unfloat(t, t->floats[i], 1);
  if (t->focus->floating) return;
  while (t->focus->parent) {
    /* close every other window: rotate focus to a sibling subtree and back */
    struct node *keep = t->focus, *p = keep->parent;
    struct node *sib = p->a == keep ? p->b : p->a;
    node_free(t, sib);
    struct node *gp = p->parent;
    struct rect r = p->r;
    *p = *keep;
    p->parent = gp;
    p->r = r;
    free(keep);
    t->focus = p;
  }
  tui_dirty(t);
}

static int is_panel(const struct node *n) { return n->cls == &view_panel; }

/* the leaves of one kind (panels, or the other windows) that are on the
 * screen: a preview a screen tab has squeezed to nothing is not */
static int leaves_of(struct tui *t, int panels, struct node **out) {
  struct node *all[32];
  int n = 0, k = 0;
  all_leaves(t, all, &n);
  for (int i = 0; i < n; i++)
    if (is_panel(all[i]) == panels && all[i]->r.w > 0 && all[i]->r.h > 0) out[k++] = all[i];
  return k;
}

void wm_note_focus(struct tui *t) {
  if (!t->focus || !t->focus->state) return;
  if (is_panel(t->focus)) t->last_panel = t->focus->state;
  else t->last_window = t->focus->state;
}

void wm_focus_next(struct tui *t, int delta) {
  struct node *all[32];
  int n = leaves_of(t, 0, all);
  if (n == 0) return;
  int at = -1;
  for (int i = 0; i < n; i++)
    if (all[i] == t->focus) at = i;
  if (at < 0) { /* from a panel: the window it was reached from, then on */
    struct node *back = t->last_window ? wm_leaf_of(t, t->last_window) : NULL;
    for (int i = 0; i < n; i++)
      if (all[i] == back) at = i;
    t->focus = at >= 0 ? all[at] : all[0];
  } else {
    t->focus = all[((at + delta) % n + n) % n];
  }
  tui_dirty(t);
}

void wm_focus_panel(struct tui *t, int delta) {
  struct node *all[32];
  int n = leaves_of(t, 1, all);
  if (n == 0) {
    tui_msg(t, 0, "no panel is open");
    return;
  }
  int at = -1;
  for (int i = 0; i < n; i++)
    if (all[i] == t->focus) at = i;
  if (at >= 0) {
    t->focus = all[((at + delta) % n + n) % n];
  } else {
    struct node *last = t->last_panel ? wm_leaf_of(t, t->last_panel) : NULL;
    t->focus = last && is_panel(last) ? last : all[delta > 0 ? 0 : n - 1];
  }
  tui_dirty(t);
}

void wm_focus_back(struct tui *t) {
  if (!t->focus || !is_panel(t->focus)) return;
  struct node *back = t->last_window ? wm_leaf_of(t, t->last_window) : NULL;
  if (back && !is_panel(back) && back->r.w > 0 && back->r.h > 0) {
    t->focus = back;
  } else {
    struct node *all[32];
    if (leaves_of(t, 0, all) == 0) return;
    t->focus = all[0];
  }
  tui_dirty(t);
}

void wm_focus_dir(struct tui *t, char dir) {
  struct node *all[32];
  int n = 0;
  leaves(t->root, all, &n);
  struct rect c = t->focus->r;
  int cy = c.y + c.h / 2, cx = c.x + c.w / 2;
  struct node *best = NULL;
  long best_d = 0;
  for (int i = 0; i < n; i++) {
    struct rect r = all[i]->r;
    if (all[i] == t->focus || is_panel(all[i]) || r.w <= 0 || r.h <= 0) continue;
    int ok = 0;
    switch (dir) {
      case 'h': ok = r.x + r.w <= c.x && r.y < c.y + c.h && r.y + r.h > c.y; break;
      case 'l': ok = r.x >= c.x + c.w && r.y < c.y + c.h && r.y + r.h > c.y; break;
      case 'k': ok = r.y + r.h <= c.y && r.x < c.x + c.w && r.x + r.w > c.x; break;
      case 'j': ok = r.y >= c.y + c.h && r.x < c.x + c.w && r.x + r.w > c.x; break;
    }
    if (!ok) continue;
    long dy = (r.y + r.h / 2) - cy, dx = (r.x + r.w / 2) - cx;
    long d = dy * dy * 4 + dx * dx;
    if (!best || d < best_d) {
      best = all[i];
      best_d = d;
    }
  }
  if (best) t->focus = best;
  tui_dirty(t);
}

/* ---- moving the line between two windows ----
 * Nothing here hands out a node to be kept: closing a window frees nodes
 * (see wm_close_leaf), so a divider being dragged is found again by where it
 * is each time the pointer moves. */

static struct node *divider_in(struct node *n, int y, int x) {
  if (!n->split) return NULL;
  struct node *hit = divider_in(n->a, y, x);
  if (!hit) hit = divider_in(n->b, y, x);
  if (hit) return hit; /* the innermost split owns the line */
  if (n->split == 'v' && x == n->a->r.x + n->a->r.w && y >= n->r.y && y < n->r.y + n->r.h) return n;
  if (n->split == 'h' && y == n->b->r.y && x >= n->r.x && x < n->r.x + n->r.w) return n;
  return NULL;
}

char wm_divider_at(struct tui *t, int y, int x) {
  struct node *n = t->root ? divider_in(t->root, y, x) : NULL;
  return n ? n->split : 0;
}

static void set_ratio(struct node *n, float ratio) {
  /* each side keeps room to be a window: a few columns, or a bar and a row */
  float least = n->split == 'v' ? 8.0f / (float)(n->r.w > 16 ? n->r.w : 16) : 2.0f / (float)(n->r.h > 4 ? n->r.h : 4);
  if (ratio < least) ratio = least;
  if (ratio > 1.0f - least) ratio = 1.0f - least;
  n->ratio = ratio;
}

int wm_divider_drag(struct tui *t, int *y, int *x, int to_y, int to_x) {
  struct node *n = t->root ? divider_in(t->root, *y, *x) : NULL;
  if (!n) return 0;
  /* half a cell past the pointer, so rounding down lands the line under it */
  if (n->split == 'v') set_ratio(n, ((float)(to_x - n->r.x) + 0.5f) / (float)(n->r.w > 1 ? n->r.w - 1 : 1));
  else set_ratio(n, ((float)(to_y - n->r.y) + 0.5f) / (float)(n->r.h > 0 ? n->r.h : 1));
  layout(n, n->r, t->screen_tab != NULL); /* its windows take their new places now, not at the next frame */
  if (n->split == 'v') *x = n->a->r.x + n->a->r.w;
  else *y = n->b->r.y;
  tui_dirty(t);
  return 1;
}

void wm_resize_dir(struct tui *t, char dir, int cells) {
  char want = dir == 'h' || dir == 'l' ? 'v' : 'h';
  struct node *n = t->focus ? t->focus->parent : NULL;
  while (n && n->split != want) n = n->parent;
  if (!n) return;
  float step = want == 'v' ? (float)cells / (float)(n->r.w > 1 ? n->r.w : 1)
                           : (float)cells / (float)(n->r.h > 1 ? n->r.h : 1);
  set_ratio(n, n->ratio + (dir == 'h' || dir == 'k' ? -step : step));
  tui_dirty(t);
}

void wm_resize(struct tui *t, int delta) {
  struct node *n = t->focus;
  if (!n->parent) return;
  struct node *p = n->parent;
  float step = 0.04f * (float)delta;
  p->ratio += p->a == n ? step : -step;
  if (p->ratio < 0.15f) p->ratio = 0.15f;
  if (p->ratio > 0.85f) p->ratio = 0.85f;
  tui_dirty(t);
}
