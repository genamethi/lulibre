/* lulibre config: the configuration as a Lua file. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "app.h"
#include "core/util.h"
#include "tui/tui.h"

static const char help[] =
  "usage: lulibre config [--write | --path]\n\n"
  "Print the configuration as a Lua file: every option with what it does, set\n"
  "to its current value (options still at their default are commented out),\n"
  "then the colours and examples of key maps and commands.\n\n"
  "  --write   save it as init.lua in the configuration directory\n"
  "            (~/.config/lulibre, or -C DIR), unless that file exists\n"
  "  --path    print where the configuration file is looked for\n\n"
  "`lulibre config > file` writes it anywhere. The file is plain Lua, loaded at\n"
  "startup; `lulibre -o name=value` overrides an option for one run.\n";

static char *config_path(const struct app *app) {
  char *dir = config_dir_path(&app->cfg);
  char *path = xasprintf("%s/init.lua", dir);
  free(dir);
  return path;
}

static void lua_string(FILE *f, const char *s) {
  fputc('"', f);
  for (; *s; s++) {
    if (*s == '"' || *s == '\\') fputc('\\', f);
    if (*s == '\n') fputs("\\n", f);
    else fputc(*s, f);
  }
  fputc('"', f);
}

/* help text as comment lines, wrapped */
static void comment(FILE *f, const char *text) {
  int col = 0;
  for (const char *p = text; *p;) {
    const char *e = p;
    while (*e && *e != ' ') e++;
    int len = (int)(e - p);
    if (col == 0) col = fprintf(f, "--");
    else if (col + 1 + len > 78) {
      fputc('\n', f);
      col = fprintf(f, "--");
    }
    col += fprintf(f, " %.*s", len, p);
    p = *e ? e + 1 : e;
  }
  fputc('\n', f);
}

static void emit(FILE *f, const struct app *app) {
  const char *home = getenv("HOME");
  size_t n, hl = home ? strlen(home) : 0;
  const struct opt_def *o = config_opts(&n);
  fputs("-- lulibre configuration.\n"
        "--\n"
        "-- Plain Lua, loaded when lulibre starts. `lulibre config` prints this file\n"
        "-- with the values in effect; `lulibre -o name=value` overrides an option for\n"
        "-- one run, and `:set name=value` inside the interface until it closes.\n"
        "-- A line that is commented out shows the default. From a script the same\n"
        "-- options are lulibre.settings.get(name) and lulibre.settings.set(name, value).\n"
        "--\n"
        "-- Options that say auto | ask | never are things lulibre can do on its own:\n"
        "-- \"auto\" does them without a word, \"ask\" asks first (and does nothing when\n"
        "-- there is nobody to ask, as in `lulibre run`), \"never\" leaves them to you.\n"
        "local o = lulibre.o\n",
        f);
  for (size_t i = 0; i < n; i++) {
    if (o[i].group) fprintf(f, "\n-- ---- %s %.*s\n", o[i].group, (int)(66 - strlen(o[i].group)),
                            "------------------------------------------------------------------");
    fputc('\n', f);
    sbuf text = SBUF_INIT;
    sb_puts(&text, o[i].help);
    if (o[i].choices) {
      sb_puts(&text, "  (");
      for (const char *p = o[i].choices; *p; p++) {
        if (*p == '|') sb_puts(&text, " | ");
        else sb_putc(&text, *p);
      }
      sb_putc(&text, ')');
    }
    comment(f, text.s);
    sb_free(&text);
    char num[32];
    const char *val = num;
    if (o[i].type == OPT_INT) snprintf(num, sizeof num, "%d", config_int(&app->cfg, &o[i]));
    else val = config_str(&app->cfg, &o[i]);
    /* a path default is compared after expansion, as it is stored */
    int is_default = !strcmp(val, o[i].def);
    fprintf(f, "%so.%s = ", is_default ? "-- " : "", o[i].name);
    if (o[i].type == OPT_INT) {
      fputs(val, f);
    } else if (o[i].type == OPT_PATH && hl && !strncmp(val, home, hl) && val[hl] == '/') {
      char *tilde = xasprintf("~%s", val + hl);
      lua_string(f, tilde);
      free(tilde);
    } else {
      lua_string(f, val);
    }
    fputc('\n', f);
  }

  fputs("\n-- ---- Colours ------------------------------------------------------------\n"
        "--\n"
        "-- \"#rrggbb\". border is the line between windows; bar_bg and bar_fg a\n"
        "-- window's top line (the focused window's is accent, with on_accent text).\n"
        "local c = lulibre.theme\n",
        f);
  for (int i = 0; theme_name(i); i++)
    fprintf(f, "-- c.%s = \"#%06x\"\n", theme_name(i), (unsigned)*theme_slot(theme_name(i)) & 0xffffff);

  fputs("\n-- ---- Keys and commands --------------------------------------------------\n"
        "--\n"
        "-- lulibre.map(modes, keys, target): modes is \"n\" (normal), \"v\" (selecting)\n"
        "-- or \"nv\"; target is a command line, or a function, which runs as a task.\n"
        "-- `?` inside the interface lists every key and command as they now stand.\n"
        "--\n"
        "-- lulibre.map(\"n\", \"gu\", \"filter author:unknown\")\n"
        "-- lulibre.map(\"n\", \"gm\", \"filter is:marked\")\n"
        "-- lulibre.map(\"nv\", \"gp\", \"run propose\")\n"
        "-- lulibre.map(\"n\", \"gx\", function()\n"
        "--   lulibre.notify(#lulibre.selection() .. \" selected\")\n"
        "-- end)\n"
        "--\n"
        "-- lulibre.command(\"unlabelled\", function(args)\n"
        "--   lulibre.filter(\"author:unknown no:tags \" .. args)\n"
        "-- end, \"[filter]  books with neither an author nor a subject\")\n"
        "--\n"
        "-- Scripts in ~/.config/lulibre/scripts/NAME.lua run with :run NAME, and\n"
        "-- modules in ~/.config/lulibre/lua/ can be require()d from here.\n",
        f);
}

int cmd_config(struct app *app, int argc, char **argv) {
  char *path = config_path(app);
  int rc = 0;
  if (argc > 1 && (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))) {
    fputs(help, stdout);
  } else if (argc > 1 && !strcmp(argv[1], "--path")) {
    puts(path);
  } else if (argc > 1 && !strcmp(argv[1], "--write")) {
    if (access(path, F_OK) == 0) {
      warnf("%s exists; it is left as it is (lulibre config > FILE writes elsewhere)", path);
      rc = 1;
    } else {
      char *dir = xstrdup(path);
      *strrchr(dir, '/') = '\0';
      mkdir_p(dir);
      free(dir);
      FILE *f = fopen(path, "w");
      if (!f) {
        warnf("cannot write %s", path);
        rc = 1;
      } else {
        emit(f, app);
        fclose(f);
        printf("wrote %s\n", path);
      }
    }
  } else if (argc > 1) {
    fputs(help, stderr);
    rc = 2;
  } else {
    emit(stdout, app);
  }
  free(path);
  return rc;
}
