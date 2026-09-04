#!/usr/bin/env bash
# Build the wasm32 modules that ../build.sh's generated variants correspond to.
#
# Needs a Swift toolchain whose version exactly matches an installed Swift SDK for
# WebAssembly (`swift sdk list`).  Override with SWIFT_SDK / SWIFTLY_TOOLCHAIN.
set -euo pipefail
cd "$(dirname "$0")"
GEN=../gen
SDK_NAME=${SWIFT_SDK:-swift-6.3.3-RELEASE_wasm}
TC=${SWIFTLY_TOOLCHAIN:-6.3.3}
SDK=$HOME/.swiftpm/swift-sdks/$SDK_NAME.artifactbundle/$SDK_NAME/wasm32-unknown-wasip1
[ -d "$SDK" ] || { echo "Swift SDK not found at $SDK"; echo "install one with: swift sdk install <url-or-file>"; exit 1; }
RES=$SDK/swift.xctoolchain/usr/lib/swift_static

variants=${VARIANTS:-"sync async"}
names=${*:-$(ls $GEN/*_sync.swift | xargs -n1 basename | sed 's/_sync\.swift//')}
for n in $names; do
  for v in $variants; do
    [ -f "$GEN/${n}_${v}.swift" ] || continue
    swiftly run "+$TC" swiftc -O -parse-as-library -wmo \
      -target wasm32-unknown-wasip1 \
      -sdk "$SDK/WASI.sdk" -sysroot "$SDK/WASI.sdk" \
      -resource-dir "$RES" \
      -Xclang-linker "-resource-dir=$RES/clang" \
      ${EXTRA_FLAGS:-} \
      "$GEN/${n}_${v}.swift" ../src/common.swift -o "${n}_${v}.wasm" \
      2> "${n}_${v}.log" || { echo "FAIL $n $v"; sed -n 1,4p "${n}_${v}.log"; continue; }
    echo "built ${n}_${v}.wasm"
  done
done
