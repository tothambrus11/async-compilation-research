#!/usr/bin/env bash
# Build every variant of every benchmark.  Usage: ./build.sh [name ...]   (default: all)
#
# Variants, all generated mechanically from one source per benchmark:
#   sync       every "async"/"await" token deleted
#   async      as written: every function async, every call site awaited
#   syncni     sync,  plus @inline(never) on every function
#   asyncni    async, plus @inline(never) on every function
#   mainactor  async, workload moved into @main's MainActor-isolated entry point
#   mainactorni  mainactor plus @inline(never) on every function
set -euo pipefail
cd "$(dirname "$0")"
SRC=src; GEN=gen; BIN=bin
SWIFTC=${SWIFTC:-swiftc}
FLAGS=${FLAGS:--O -parse-as-library -wmo}
mkdir -p "$GEN" "$BIN"

is_async_only() { head -1 "$SRC/$1.swift" | grep -q '^// async-only'; }

list_all() {
  for f in "$SRC"/*.swift; do
    n=$(basename "$f" .swift)
    [ "$n" = common ] || echo "$n"
  done
}

compile() { # name variant
  $SWIFTC $FLAGS "$GEN/$1_$2.swift" "$SRC/common.swift" -o "$BIN/$1_$2" 2> "$GEN/$1_$2.log" \
    || { echo "FAIL $1 $2"; sed -n 1,5p "$GEN/$1_$2.log"; return 1; }
}

names=${*:-$(list_all)}
for n in $names; do
  if is_async_only "$n"; then
    sed 's/ATTR //g' "$SRC/$n.swift" > "$GEN/${n}_async.swift"
    compile "$n" async
    echo "built $n (async only)"
    continue
  fi
  sed 's/ATTR //g; s/ async//g; s/await //g'              "$SRC/$n.swift" > "$GEN/${n}_sync.swift"
  sed 's/ATTR //g'                                        "$SRC/$n.swift" > "$GEN/${n}_async.swift"
  sed 's/ATTR /@inline(never) /g; s/ async//g; s/await //g' "$SRC/$n.swift" > "$GEN/${n}_syncni.swift"
  sed 's/ATTR /@inline(never) /g'                          "$SRC/$n.swift" > "$GEN/${n}_asyncni.swift"
  python3 mkmainactor.py "$SRC/$n.swift" "$GEN/${n}_mainactor.swift"
  python3 mkmainactor.py "$SRC/$n.swift" "$GEN/${n}_mainactorni.swift" "@inline(never)"
  for v in sync async syncni asyncni mainactor mainactorni; do compile "$n" "$v"; done
  echo "built $n"
done
