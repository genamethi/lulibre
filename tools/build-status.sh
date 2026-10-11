#!/bin/sh
# Say what was built, and how it compares with the lulibre on PATH.
#   build-status.sh BUILT_BINARY EXPECTED_VERSION INSTALL_DIR
bin=$1 want=$2 bindir=$3

md5() {
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
  elif command -v md5 >/dev/null 2>&1; then md5 -q "$1"
  else cksum "$1" | cut -d' ' -f1
  fi
}

line=$("$bin" -V 2>/dev/null) || { echo "built   $bin, but it does not run"; exit 1; }
version=$(printf '%s\n' "$line" | cut -d' ' -f2)
sum=$(md5 "$bin")
echo "built   $bin: $line"
echo "        md5 $sum"
if [ "$version" != "$want" ]; then
  echo "        WARNING: configure recorded version $want; run ./configure again"
fi

installed=$(command -v lulibre 2>/dev/null)
if [ -z "$installed" ]; then
  echo "PATH    no lulibre on PATH (make install puts this one in $bindir)"
  exit 0
fi
iline=$("$installed" -V 2>/dev/null) || iline="does not run"
isum=$(md5 "$installed")
iversion=$(printf '%s\n' "$iline" | cut -d' ' -f2)
echo "PATH    $installed: $iline"
echo "        md5 $isum"
if [ "$isum" = "$sum" ]; then
  echo "        the same binary as this build"
elif [ "$iversion" = "$version" ]; then
  echo "        same version, different binary: this build is not the one installed (make install)"
else
  echo "        a different version ($iversion, built $version): make install replaces it"
fi
