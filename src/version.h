#ifndef LULIBRE_VERSION_H
#define LULIBRE_VERSION_H

/* lulibre's version: the one place it is written.
 *
 * Semantic versioning (semver.org): MAJOR.MINOR.PATCH, followed while there
 * is one by a pre-release tag: "-alpha", "-beta", "-rc.1"; "" for a release.
 * ./configure reads this file, checks that it is a valid version and hands
 * it to make; `lulibre -V` and lulibre.version report it. */
#define LULIBRE_VERSION_MAJOR 0
#define LULIBRE_VERSION_MINOR 2
#define LULIBRE_VERSION_PATCH 0
#define LULIBRE_VERSION_PRE "-alpha.0"

#define LULIBRE_STR_(x) #x
#define LULIBRE_STR(x) LULIBRE_STR_(x)
#define LULIBRE_VERSION                                                         \
  LULIBRE_STR(LULIBRE_VERSION_MAJOR) "." LULIBRE_STR(LULIBRE_VERSION_MINOR) "." \
  LULIBRE_STR(LULIBRE_VERSION_PATCH) LULIBRE_VERSION_PRE

#endif
