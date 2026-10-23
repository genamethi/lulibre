/* lulibre-setup: the choices of a setup, made on one screen and kept in the
 * plan, setup.conf, in the folder lulibre-setup runs from. "Install now"
 * steps back to the shell and runs setup/install.sh on the plan there, in
 * view; the screen comes back when the script is done.
 *
 * Basic is the easiest path: the level, pixi, the library and the content
 * server. Nothing is filled in: each is chosen. Advanced holds the prefix,
 * luv, and every other option of lulibre's, each at lulibre's default
 * until it is set. */
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "core/config.h"
#include "core/util.h"
#include "setup/setup.h"
#include "tui/tui.h"

static struct item *items;
static int nitems, capitems;
static char *root, *plan, *script;
static struct notcurses *nc;
static int cur, top;
static char *msg;
static int msg_color;

/* ---- the items ---- */

static struct item *item_named(const char *key) {
  for (int i = 0; i < nitems; i++)
    if (items[i].key && !items[i].opt && !strcmp(items[i].key, key)) return &items[i];
  return NULL;
}

static const char *value_of(const char *key) {
  struct item *it = item_named(key);
  return it && it->value ? it->value : "";
}

static int is(const char *key, const char *v) {
  return !strcmp(value_of(key), v);
}

static int add(struct item it) {
  if (nitems == capitems) {
    capitems = capitems ? capitems * 2 : 64;
    items = xrealloc(items, (size_t)capitems * sizeof *items);
  }
  items[nitems] = it;
  return nitems++;
}

static int server_on(void) {
  return is("SERVER", "yes");
}

/* the password file is the user's but open to group or others */
static int password_open(void) {
  struct stat st;
  const char *p = value_of("PASSWORD_FILE");
  return server_on() && p[0] && stat(p, &st) == 0 && st.st_uid == getuid() && (st.st_mode & 077);
}

static void set_note(struct item *it, int color, const char *fmt, ...) PRINTF(3, 4);
static void set_note(struct item *it, int color, const char *fmt, ...) {
  free(it->note);
  it->note = NULL;
  if (!fmt) return;
  va_list ap;
  va_start(ap, fmt);
  if (vasprintf(&it->note, fmt, ap) < 0) it->note = NULL;
  va_end(ap);
  it->note_color = color;
}

/* What the values chosen are, said beside them: the library is one, the
 * password file is safe. Only the values the person gave are looked at. */
static void notes(void) {
  struct item *lib = item_named("LIBRARY"), *pw = item_named("PASSWORD_FILE"), *pre = item_named("PREFIX");
  struct stat st;
  if (lib->value) {
    char *db = xasprintf("%s/metadata.db", lib->value);
    if (stat(db, &st) == 0) set_note(lib, theme.ok, "a calibre library");
    else set_note(lib, theme.error, "no metadata.db here: not a calibre library");
    free(db);
  } else {
    set_note(lib, 0, NULL);
  }
  if (pw->value) {
    if (stat(pw->value, &st) != 0) set_note(pw, theme.error, "no such file");
    else if (!S_ISREG(st.st_mode)) set_note(pw, theme.error, "not a file");
    else if (st.st_uid != getuid()) set_note(pw, theme.error, "not yours: it is to be owned by you");
    else if (st.st_mode & 077) set_note(pw, theme.warn, "mode %03o: group or others have access", st.st_mode & 0777);
    else set_note(pw, theme.ok, "mode %03o, yours", st.st_mode & 0777);
  } else {
    set_note(pw, 0, NULL);
  }
  if (!password_open()) {
    struct item *ch = item_named("PASSWORD_CHMOD");
    free(ch->value);
    ch->value = NULL;
  }
  if (!pre->value && item_named("LEVEL")->value)
    set_note(pre, theme.dim, "%s, as the level has it", is("LEVEL", "system") ? "/usr/local" : "~/.local");
  else
    set_note(pre, 0, NULL);
}

static const char *opt_skip[] = {"library", "server", "user", "password_file", "config_dir", NULL};

static void build_items(void) {
  int basic = add((struct item){.kind = K_HEAD, .label = "Basic", .head = -1, .open = 1});
  add((struct item){
    .kind = K_CHOICE, .key = "LEVEL", .label = "Level", .choices = "user|system", .depth = 1, .head = basic,
    .help = "user: lulibre is installed under ~/.local, and nothing asks for root. system: under /usr/local, "
            "with sudo for the steps that write there."});
  add((struct item){
    .kind = K_CHOICE, .key = "PIXI", .label = "pixi", .choices = "yes|no", .depth = 1, .head = basic,
    .help = "yes: pixi's environment (pixi.toml) provides luv and the optional programs (pdftotext, tesseract, "
            "ocrmypdf, kaggle); pixi itself is installed first if it is missing. no: they come from the system."});
  add((struct item){.kind = K_DIR, .key = "LIBRARY", .label = "Library", .depth = 1, .head = basic,
                    .help = "the calibre library: the folder that holds metadata.db."});
  add((struct item){
    .kind = K_CHOICE, .key = "SERVER", .label = "Content server", .choices = "yes|no", .depth = 1, .head = basic,
    .help = "yes: changes go through calibre's content server, with the URL, user and password file below. "
            "no: lulibre writes to the library folder itself."});
  add((struct item){.kind = K_TEXT, .key = "SERVER_URL", .label = "URL", .depth = 2, .head = basic,
                    .shown = server_on, .help = "the content server's address, such as http://127.0.0.1:8080"});
  add((struct item){.kind = K_TEXT, .key = "SERVER_USER", .label = "User", .depth = 2, .head = basic,
                    .shown = server_on, .help = "the user lulibre signs in to the content server as."});
  add((struct item){
    .kind = K_FILE, .key = "PASSWORD_FILE", .label = "Password file", .depth = 2, .head = basic, .shown = server_on,
    .help = "a file that holds that user's password and nothing else. lulibre gives calibredb the file's path, "
            "never the password. The file is to be yours, with no access for group or others (mode 600)."});
  add((struct item){.kind = K_CHOICE, .key = "PASSWORD_CHMOD", .label = "Make it mode 600", .choices = "yes|no",
                    .depth = 3, .head = basic, .shown = password_open,
                    .help = "yes: the install takes group's and others' access away (chmod 600)."});

  int adv = add((struct item){.kind = K_HEAD, .label = "Advanced", .head = -1});
  add((struct item){
    .kind = K_DIR, .key = "PREFIX", .label = "Install prefix", .depth = 1, .head = adv,
    .help = "where lulibre is installed: bin/lulibre and share/lulibre under it. Not set: ~/.local for a user, "
            "/usr/local for the system."});
  add((struct item){.kind = K_CHOICE, .key = "CONFIRM", .label = "Confirm each command", .choices = "yes|no",
                    .depth = 1, .head = adv, .help = "yes: the install asks before each command it runs."});
  add((struct item){
    .kind = K_CHOICE, .key = "LUV_ROCKS", .label = "Install luv with luarocks", .choices = "user|system|no",
    .depth = 1, .head = adv,
    .help = "luv is found on Lua's package path, as any module is, and nothing needs setting when it is there. "
            "user: make rocks installs it into the user-level luarocks tree (~/.luarocks), which lulibre "
            "searches when the option mod_tree names it. system: into the system's tree, with sudo. pixi's "
            "environment has it already."});
  add((struct item){.kind = K_CHECK, .key = "LUV_CHECK", .label = "Check luv", .depth = 1, .head = adv,
                    .help = "Enter runs require \"luv\" under lulibre's own Lua (build/lulibre, in pixi's "
                            "environment when pixi is chosen) and says whether it loads."});
  size_t n;
  const struct opt_def *defs = config_opts(&n);
  const char *group = NULL;
  int head = adv;
  for (size_t i = 0; i < n; i++) {
    const struct opt_def *o = &defs[i];
    if (o->group) group = o->group;
    int skip = 0;
    for (int k = 0; opt_skip[k]; k++) skip |= !strcmp(o->name, opt_skip[k]);
    if (skip) continue;
    if (o->group || head == adv) {
      head = add((struct item){.kind = K_HEAD, .label = group ? group : "Options", .depth = 1, .head = adv,
                               .help = "lulibre's options: each at lulibre's default until it is set here."});
    }
    enum kind kind = o->choices || o->type == OPT_BOOL ? K_CHOICE : K_TEXT;
    add((struct item){.kind = kind, .key = o->name, .label = o->name, .help = o->help, .opt = o, .depth = 2,
                      .head = head, .choices = o->type == OPT_BOOL ? "true|false" : o->choices});
  }
  add((struct item){.kind = K_ACTION, .key = "install", .label = "Install now", .head = -1,
                    .help = "steps back to the shell and runs setup/install.sh on these choices, in view; "
                            "this screen comes back when it is done."});
  add((struct item){.kind = K_ACTION, .key = "quit", .label = "Save and quit", .head = -1,
                    .help = "leaves; the choices stay in the plan for the next time."});
}

/* shown: its own condition, and every heading above it open */
static int visible(int i) {
  if (items[i].shown && !items[i].shown()) return 0;
  for (int h = items[i].head; h >= 0; h = items[h].head)
    if (!items[h].open || (items[h].shown && !items[h].shown())) return 0;
  return 1;
}

static void say(int color, const char *fmt, ...) PRINTF(2, 3);
static void say(int color, const char *fmt, ...) {
  free(msg);
  msg = NULL;
  msg_color = color;
  if (!fmt) return;
  va_list ap;
  va_start(ap, fmt);
  if (vasprintf(&msg, fmt, ap) < 0) msg = NULL;
  va_end(ap);
}

static void save(void) {
  char *err = NULL;
  if (plan_save(plan, items, nitems, &err)) {
    say(theme.error, "%s", err);
    free(err);
  }
}

static void set_value(struct item *it, const char *v) {
  free(it->value);
  it->value = v && v[0] ? xstrdup(v) : NULL;
  if (it->kind == K_CHECK) return;
  notes();
  save();
}

/* ---- drawing ---- */

#define LABEL_W 34

/* a path as shown: the home folder as ~ */
static char *shown_path(const char *p) {
  const char *home = getenv("HOME");
  size_t hl = home ? strlen(home) : 0;
  if (hl > 1 && !strncmp(p, home, hl) && (p[hl] == '/' || !p[hl])) return xasprintf("~%s", p + hl);
  return xstrdup(p);
}

static void draw_value(struct ncplane *n, int y, int x, int w, const struct item *it, int cursor) {
  int bg = cursor ? theme.cursor_bg : C_DEFAULT;
  int used = 0;
  if (it->kind == K_CHECK || it->kind == K_ACTION) {
    /* nothing but the note */
  } else if (it->value) {
    dr_style(n, theme.accent, bg, 0);
    int path = it->kind == K_DIR || it->kind == K_FILE || (it->opt && it->opt->type == OPT_PATH);
    char *s = path ? shown_path(it->value) : xstrdup(it->value);
    /* room kept for the note */
    used = dr_text(n, y, x, it->note && w > 40 ? w * 3 / 5 : w, s);
    free(s);
  } else if (it->opt) {
    dr_style(n, theme.dim, bg, 0);
    char *d = xasprintf("default: %s", it->opt->def[0] ? it->opt->def : "(empty)");
    used = dr_text(n, y, x, w, d);
    free(d);
  } else if (!it->note) {
    dr_style(n, theme.dim, bg, A_ITALIC);
    used = dr_text(n, y, x, w, "not set");
  }
  if (it->note && w - used - 3 > 0) {
    dr_style(n, it->note_color ? it->note_color : theme.dim, bg, 0);
    dr_text(n, y, x + used + (used ? 3 : 0), w - used - 3, it->note);
  }
}

static void draw(void) {
  struct ncplane *n = notcurses_stdplane(nc);
  unsigned rows, cols;
  ncplane_dim_yx(n, &rows, &cols);
  int w = (int)cols, list = (int)rows - 4;
  if (list < 1) list = 1;
  ncplane_erase(n);
  dr_bar(n, (struct rect){0, 0, 1, w}, 1);
  int x = dr_text(n, 0, 1, w - 2, "lulibre setup");
  dr_style(n, theme.on_accent, theme.accent, 0);
  char *where = xasprintf("the plan: %s", plan);
  dr_text(n, 0, x + 4, w - x - 5, where);
  free(where);

  int vis[4096], nv = 0, at = 0;
  for (int i = 0; i < nitems && nv < (int)ARRAY_LEN(vis); i++)
    if (visible(i)) {
      if (i == cur) at = nv;
      vis[nv++] = i;
    }
  if (at < top) top = at;
  if (at >= top + list) top = at - list + 1;
  for (int r = 0; r < list && top + r < nv; r++) {
    const struct item *it = &items[vis[top + r]];
    int cursor = vis[top + r] == cur, y = 1 + r, ind = 2 * it->depth + 1;
    int bg = cursor ? theme.cursor_bg : C_DEFAULT;
    dr_style(n, C_DEFAULT, bg, 0);
    dr_fill(n, y, 0, w);
    if (it->kind == K_HEAD) {
      dr_style(n, theme.title, bg, A_BOLD);
      char *s = xasprintf("%s %s", it->open ? "▾" : "▸", it->label);
      dr_text(n, y, ind, w - ind - 1, s);
      free(s);
      continue;
    }
    if (it->kind == K_ACTION) {
      dr_style(n, theme.accent, bg, A_BOLD);
      char *s = xasprintf("[ %s ]", it->label);
      dr_text(n, y, ind, w - ind - 1, s);
      free(s);
      continue;
    }
    dr_style(n, it->value || it->opt ? C_DEFAULT : theme.warn, bg, 0);
    dr_text(n, y, ind, LABEL_W - ind - 1, it->label);
    if (w > LABEL_W + 2) draw_value(n, y, LABEL_W, w - LABEL_W - 1, it, cursor);
  }

  /* the help of the row under the cursor, or what was last said */
  const char *help = msg ? msg : items[cur].help ? items[cur].help : "";
  size_t off[2], len[2];
  int lines = dr_lines(help, w - 2, off, len, 2);
  dr_style(n, msg ? msg_color : theme.dim, C_DEFAULT, 0);
  for (int k = 0; k < 2; k++) {
    dr_fill(n, (int)rows - 3 + k, 0, w);
    if (k < lines) dr_textn(n, (int)rows - 3 + k, 1, w - 2, help + off[k], len[k]);
  }
  dr_style(n, theme.dim, C_DEFAULT, 0);
  dr_fill(n, (int)rows - 1, 0, w);
  dr_text(n, (int)rows - 1, 1, w - 2,
          "Enter change   Space next value   e type   x unset   i install now   q quit (the plan is kept)");
  notcurses_render(nc);
}

/* ---- running things ---- */

/* argv's output, both streams, into a malloc'd string; *status its exit */
static char *capture(char *const argv[], int *status) {
  int fd[2];
  *status = -1;
  if (pipe(fd) != 0) return xstrdup(errstr(errno));
  pid_t pid = fork();
  if (pid == 0) {
    close(fd[0]);
    dup2(fd[1], 1);
    dup2(fd[1], 2);
    close(fd[1]);
    int null = open("/dev/null", 0);
    if (null >= 0) dup2(null, 0);
    execvp(argv[0], argv);
    fprintf(stderr, "cannot run %s: %s", argv[0], errstr(errno));
    _exit(127);
  }
  close(fd[1]);
  sbuf out = SBUF_INIT;
  sb_puts(&out, "");
  char buf[4096];
  ssize_t r;
  while ((r = read(fd[0], buf, sizeof buf)) > 0 || (r < 0 && errno == EINTR))
    if (r > 0) sb_putn(&out, buf, (size_t)r);
  close(fd[0]);
  int st;
  if (pid > 0 && waitpid(pid, &st, 0) == pid) *status = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
  return sb_take(&out);
}

static void check_luv(struct item *it) {
  char *bin = xasprintf("%s/build/lulibre", root), *lua = xasprintf("%s/setup/luv-check.lua", root);
  char *manifest = xasprintf("%s/pixi.toml", root);
  int pixi = is("PIXI", "yes");
  char *with_pixi[] = {"pixi", "run", "--manifest-path", manifest, bin, "--clean", "run", lua, NULL};
  char *plain[] = {bin, "--clean", "run", lua, NULL};
  set_note(it, theme.dim, "checking ...");
  draw();
  int status;
  char *out = capture(pixi ? with_pixi : plain, &status);
  /* the first line says it (a traceback may follow) */
  char *line = out, *nl;
  if ((nl = strchr(line, '\n'))) *nl = '\0';
  if (!strncmp(line, "lulibre: ", 9)) line += 9;
  if (!strncmp(line, "luv-check.lua: ", 15)) line += 15;
  set_note(it, status == 0 ? theme.ok : theme.warn, "%s%s", line, pixi ? " (in pixi's environment)" : "");
  free(out);
  free(bin);
  free(lua);
  free(manifest);
}

static struct notcurses *terminal_start(void) {
  struct notcurses_options no = {.flags = NCOPTION_SUPPRESS_BANNERS};
  struct notcurses *n = notcurses_core_init(&no, NULL);
  if (!n) die("cannot initialise the terminal (TERM=%s)", getenv("TERM") ? getenv("TERM") : "");
  notcurses_linesigs_disable(n);
  return n;
}

/* the basic choices not made yet, as a list for a message; NULL when all are */
static char *missing(int *first) {
  static const char *need[] = {"LEVEL", "PIXI", "LIBRARY", "SERVER", NULL};
  static const char *need_server[] = {"SERVER_URL", "SERVER_USER", "PASSWORD_FILE", NULL};
  sbuf s = SBUF_INIT;
  *first = -1;
  for (int pass = 0; pass < 2; pass++) {
    const char **keys = pass ? need_server : need;
    if (pass && !server_on()) break;
    for (int k = 0; keys[k]; k++) {
      struct item *it = item_named(keys[k]);
      if (it->value) continue;
      if (*first < 0) *first = (int)(it - items);
      sb_printf(&s, "%s%s", s.len ? ", " : "", it->label);
    }
  }
  struct item *ch = item_named("PASSWORD_CHMOD");
  if (password_open() && !ch->value) {
    if (*first < 0) *first = (int)(ch - items);
    sb_printf(&s, "%s%s", s.len ? ", " : "", "whether to make the password file mode 600");
  }
  return s.len ? sb_take(&s) : NULL;
}

static void install_now(void) {
  int first;
  char *gap = missing(&first);
  if (gap) {
    say(theme.warn, "to choose first: %s", gap);
    free(gap);
    items[0].open = 1;
    cur = first;
    return;
  }
  save();
  notcurses_stop(nc);
  nc = NULL;
  printf("lulibre-setup: sh %s %s\n", script, plan);
  fflush(stdout);
  struct sigaction ign = {.sa_handler = SIG_IGN}, old_int, old_quit;
  sigaction(SIGINT, &ign, &old_int);
  sigaction(SIGQUIT, &ign, &old_quit);
  int status = -1;
  pid_t pid = fork();
  if (pid == 0) {
    signal(SIGINT, SIG_DFL);
    signal(SIGQUIT, SIG_DFL);
    execl("/bin/sh", "sh", script, plan, (char *)NULL);
    _exit(127);
  } else if (pid > 0) {
    int st;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {
    }
    status = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
  }
  sigaction(SIGINT, &old_int, NULL);
  sigaction(SIGQUIT, &old_quit, NULL);
  printf("\nlulibre-setup: the install %s. Enter goes back to the setup screen.\n",
         status == 0 ? "is done" : "stopped");
  fflush(stdout);
  int c;
  while ((c = getchar()) != EOF && c != '\n') {
  }
  nc = terminal_start();
  if (status == 0) say(theme.ok, "the install is done; its output is on the shell's screen again after quitting");
  else say(theme.error, "the install stopped (exit %d); its output is on the shell's screen again after quitting", status);
}

/* ---- keys ---- */

static int step_visible(int from, int dir) {
  for (int i = from + dir; i >= 0 && i < nitems; i += dir)
    if (visible(i)) return i;
  return from;
}

static void next_value(struct item *it) {
  const char *c = it->choices;
  if (!c) return;
  const char *v = it->value ? it->value : "";
  const char *p = c, *next = c;
  if (v[0]) {
    size_t vl = strlen(v);
    for (;;) {
      const char *bar = strchr(p, '|');
      size_t l = bar ? (size_t)(bar - p) : strlen(p);
      if (l == vl && !strncmp(p, v, l)) {
        next = bar ? bar + 1 : NULL;
        break;
      }
      if (!bar) break;
      p = bar + 1;
    }
  }
  if (!next) { /* past the last value: unset again, as at first */
    set_value(it, NULL);
    return;
  }
  const char *bar = strchr(next, '|');
  char *val = bar ? xstrndup(next, (size_t)(bar - next)) : xstrdup(next);
  set_value(it, val);
  free(val);
}

static void type_value(struct item *it) {
  char *prompt = xasprintf("%s: ", it->label);
  int paths = it->kind == K_DIR || it->kind == K_FILE || (it->opt && it->opt->type == OPT_PATH);
  char *v = line_edit(nc, prompt, it->value, paths);
  free(prompt);
  if (!v) return;
  if (it->opt && it->opt->type == OPT_INT && v[0]) {
    char *end;
    strtol(v, &end, 10);
    if (*end) {
      say(theme.error, "%s takes a whole number", it->label);
      free(v);
      return;
    }
  }
  if (it->opt && it->opt->choices && v[0]) {
    char *bars = xasprintf("|%s|", it->opt->choices), *want = xasprintf("|%s|", v);
    int ok = strstr(bars, want) != NULL;
    free(bars);
    free(want);
    if (!ok) {
      say(theme.error, "%s takes one of %s", it->label, it->opt->choices);
      free(v);
      return;
    }
  }
  if (paths && v[0]) {
    char *p = path_expand(v);
    set_value(it, p);
    free(p);
  } else {
    set_value(it, v);
  }
  free(v);
}

static int act(struct item *it, uint32_t k) {
  switch (it->kind) {
  case K_HEAD:
    it->open = !it->open;
    break;
  case K_CHOICE:
    next_value(it);
    break;
  case K_TEXT:
    if (k == NCKEY_ENTER) type_value(it);
    break;
  case K_DIR:
  case K_FILE:
    if (k == NCKEY_ENTER) {
      char *title = xasprintf("%s: choose a %s", it->label, it->kind == K_DIR ? "folder" : "file");
      char *p = browse(nc, title, it->value, it->kind == K_DIR);
      free(title);
      if (p) set_value(it, p);
      free(p);
    }
    break;
  case K_CHECK:
    if (k == NCKEY_ENTER) check_luv(it);
    break;
  case K_ACTION:
    if (k != NCKEY_ENTER) break;
    if (!strcmp(it->key, "quit")) return 1;
    install_now();
    break;
  }
  return 0;
}

static void find_root(const char *argv0, const char *plan_arg) {
  char exe[4096];
  ssize_t len = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (len <= 0) die("cannot tell where %s is", argv0);
  exe[len] = '\0';
  char *slash = strrchr(exe, '/');
  *slash = '\0';
  /* build/lulibre-setup: the folder is the one above build/ */
  slash = strrchr(exe, '/');
  if (slash && !strcmp(slash + 1, "build")) *slash = '\0';
  root = xstrdup(exe[0] ? exe : "/");
  plan = plan_arg ? xstrdup(plan_arg) : xasprintf("%s/setup.conf", root);
  script = xasprintf("%s/setup/install.sh", root);
  if (access(script, R_OK) != 0)
    die("%s is not there: lulibre-setup runs from lulibre's folder, as build/lulibre-setup", script);
}

int main(int argc, char **argv) {
  if (argc > 1 && (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))) {
    puts("usage: lulibre-setup [PLAN]\n\n"
         "Choose how lulibre is set up, on one screen, and install it from there. The choices\n"
         "are kept in the plan, setup.conf in lulibre's folder unless PLAN names another;\n"
         "setup/install.sh carries them out.");
    return 0;
  }
  setlocale(LC_ALL, "");
  if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) die("lulibre-setup needs a terminal");
  find_root(argv[0], argc > 1 ? argv[1] : NULL);
  build_items();
  char *err = NULL;
  if (plan_load(plan, items, nitems, &err)) die("%s", err);
  notes();
  cur = step_visible(0, 1);
  nc = terminal_start();
  for (;;) {
    draw();
    struct ncinput ni;
    if (notcurses_get_blocking(nc, &ni) == (uint32_t)-1) break;
    uint32_t k = key_of(&ni);
    if (!k || k == NCKEY_RESIZE) continue;
    say(0, NULL);
    unsigned rows, cols;
    ncplane_dim_yx(notcurses_stdplane(nc), &rows, &cols);
    int page = (int)rows / 2 > 1 ? (int)rows / 2 : 1;
    struct item *it = &items[cur];
    if (k == 'q' || k == (KEY_CTRL | 'c')) break;
    if (k == 'j' || k == NCKEY_DOWN) cur = step_visible(cur, 1);
    else if (k == 'k' || k == NCKEY_UP) cur = step_visible(cur, -1);
    else if (k == 'g' || k == NCKEY_HOME) cur = step_visible(-1, 1);
    else if (k == 'G' || k == NCKEY_END) cur = step_visible(nitems, -1);
    else if (k == (KEY_CTRL | 'd') || k == NCKEY_PGDOWN)
      for (int s = 0; s < page; s++) cur = step_visible(cur, 1);
    else if (k == (KEY_CTRL | 'u') || k == NCKEY_PGUP)
      for (int s = 0; s < page; s++) cur = step_visible(cur, -1);
    else if (k == 'i') install_now();
    else if (k == 'x' || k == NCKEY_DEL) {
      if (it->kind != K_HEAD && it->kind != K_ACTION && it->kind != K_CHECK) set_value(it, NULL);
    } else if (k == 'e') {
      if (it->kind == K_TEXT || it->kind == K_DIR || it->kind == K_FILE) type_value(it);
    } else if (k == ' ') {
      if (it->kind == K_HEAD || it->kind == K_CHOICE) act(it, k);
    } else if (k == NCKEY_ENTER || k == 'l' || k == NCKEY_RIGHT) {
      if (k != NCKEY_ENTER && it->kind != K_HEAD) continue;
      if (act(it, NCKEY_ENTER)) break;
    } else if (k == 'h' || k == NCKEY_LEFT) {
      /* to the heading above, closing it */
      if (it->kind == K_HEAD && it->open) it->open = 0;
      else if (it->head >= 0) {
        cur = it->head;
        items[cur].open = 0;
      }
    }
    if (!visible(cur)) cur = step_visible(cur, -1);
  }
  notcurses_stop(nc);
  save();
  printf("lulibre-setup: the choices are kept in %s\n", plan);
  return 0;
}
