#!/bin/sh
# Rules of AGENT.md that the sources can be searched for.
#   lint.sh
set -u
src=$(cd "$(dirname "$0")/.." && pwd)/src
fails=0
# strerror shares one buffer between threads: errstr(err) (core/util.h)
hits=$(grep -rn 'strerror(' "$src" | grep -v 'strerror_r\|uv_strerror\|curl_easy_strerror\|/setup/')
if [ -n "$hits" ]; then
  echo "FAIL  strerror outside core/util.c: use errstr"
  echo "$hits"
  fails=1
else
  echo "ok    no strerror: errstr instead"
fi
[ $fails -eq 0 ] && echo "all passed" || exit 1
