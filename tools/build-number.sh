#!/bin/sh
# Give this build its number and write it in the build log.
#   build-number.sh VERSION           prints the number ("007") and logs the build
#   build-number.sh VERSION --log     prints the log
#   build-number.sh VERSION --where   prints where the log is kept
#
# Builds of one version (0.2.0-alpha.0 is one, 0.2.0-alpha.1 another) are
# numbered 001, 002, ... in the order they are made,
# whichever checkout of the repository makes them: the log is kept beside the
# repository's own data (.git/lulibre-builds/), which every worktree shares,
# and is not part of any commit. Each line gives the number, the time, the
# version, the commit built (with + when the tree had changes not yet
# committed, in which case those changes are saved beside the log as
# NNN.diff), the branch and the checkout. Outside a git repository the log
# is build/builds.log.
#
# The number is for telling builds apart while a version is in the making;
# it is not part of the version.
version=$1
# One count for each version as it is written in full: 0.2.0-alpha.0 starts
# again at 001, as 0.2.0-alpha.1 and 0.2.0 will.
base=$version
common=$(git rev-parse --git-common-dir 2>/dev/null) || common=
if [ -n "$common" ]; then
  dir=$(cd "$common" && pwd)/lulibre-builds/$base
else
  dir=build/builds/$base
fi
log=$dir/builds.log

case ${2:-} in
  --where) echo "$log"; exit 0 ;;
  --log) [ -f "$log" ] && cat "$log" || echo "no builds of $base logged yet"; exit 0 ;;
esac

mkdir -p "$dir" || exit 1
last=$(tail -n 1 "$log" 2>/dev/null | cut -d' ' -f1 | sed 's/^0*//')
n=$(printf '%03d' $(( ${last:-0} + 1 )))
sha=none branch=- dirty=
if [ -n "$common" ]; then
  sha=$(git rev-parse --short HEAD 2>/dev/null || echo none)
  branch=$(git branch --show-current 2>/dev/null)
  if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    dirty=+
    git diff HEAD > "$dir/$n.diff" 2>/dev/null
  fi
fi
printf '%s  %s  %s  %s%s  %s  %s\n' "$n" "$(date '+%Y-%m-%d %H:%M')" "$version" "$sha" "$dirty" "${branch:--}" "$(pwd)" >> "$log"
echo "$n $sha$dirty"
