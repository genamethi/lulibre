/* Windows: a binary tree of splits whose leaves are views. */
#include <stdlib.h>
#include <string.h>

#include "tui/tui.h"

static const struct view_class *const classes[] = {&view_list, &view_preview};

static void close_node(struct tui *t, struct node *n);

const struct view_class *wm_class(const char *name) {
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
  } else if (n->cls->destroy) {
    n->cls->destroy(t, n->state);
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
  t->root = t->focus = NULL;
}

static void layout(struct node *n, struct rect r) {
  n->r = r;
  if (!n->split) return;
  if (n->split == 'v') {
    int wa = (int)((float)(r.w - 1) * n->ratio);
    if (wa < 1) wa = 1;
    if (wa > r.w - 2) wa = r.w - 2 > 1 ? r.w - 2 : 1;
    layout(n->a, (struct rect){r.y, r.x, r.h, wa});
    layout(n->b, (struct rect){r.y, r.x + wa + 1, r.h, r.w - wa - 1});
  } else {
    int ha = (int)((float)r.h * n->ratio);
    if (ha < 1) ha = 1;
    if (ha > r.h - 1) ha = r.h - 1 > 1 ? r.h - 1 : 1;
    layout(n->a, (struct rect){r.y, r.x, ha, r.w});
    layout(n->b, (struct rect){r.y + ha, r.x, r.h - ha, r.w});
  }
}

void wm_layout(struct tui *t, struct rect area) {
  layout(t->root, area);
}

static void draw(struct tui *t, struct node *n) {
  if (!n->split) {
    if (n->r.w > 0 && n->r.h > 0) n->cls->draw(t, n->state, n->r, n == t->focus);
    else if (n->cls->hide) n->cls->hide(t, n->state); /* no room: take down what it left on screen */
    return;
  }
  draw(t, n->a);
  draw(t, n->b);
  if (n->split == 'v') {
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
}

static void leaves(struct node *n, struct node **out, int *count) {
  if (!n->split) {
    if (*count < 32) out[(*count)++] = n;
    return;
  }
  leaves(n->a, out, count);
  leaves(n->b, out, count);
}

struct node *wm_leaf_of(struct tui *t, void *state) {
  struct node *all[32];
  int n = 0;
  if (!state) return NULL;
  leaves(t->root, all, &n);
  for (int i = 0; i < n; i++)
    if (all[i]->state == state) return all[i];
  return NULL;
}

struct node *wm_at(struct tui *t, int y, int x) {
  struct node *all[32];
  int n = 0;
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
  leaves(t->root, all, &n);
  if (t->focus && t->focus->cls == cls) return t->focus;
  for (int i = 0; i < n; i++)
    if (all[i]->cls == cls) return all[i];
  return NULL;
}

int wm_split(struct tui *t, char dir, const char *view) {
  const struct view_class *cls = view && *view ? wm_class(view) : t->focus->cls;
  if (!cls) return -1;
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

/* Is `n` inside the subtree at `root`? */
static int within(const struct node *root, const struct node *n) {
  for (; n; n = n->parent)
    if (n == root) return 1;
  return 0;
}

static void close_node(struct tui *t, struct node *n) {
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
  if (n && !n->split && n->parent) close_node(t, n);
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

/* Close the window showing this state, if there is one. */
void wm_undock(struct tui *t, void *state) {
  struct node *stack[64];
  int n = 0;
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
      if (x->parent) {
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

void wm_only(struct tui *t) {
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

void wm_focus_next(struct tui *t, int delta) {
  struct node *all[32];
  int n = 0;
  leaves(t->root, all, &n);
  for (int i = 0; i < n; i++)
    if (all[i] == t->focus) {
      t->focus = all[((i + delta) % n + n) % n];
      break;
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
    if (all[i] == t->focus) continue;
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
