#!/usr/bin/env bash
# Build and run the diagnostic probes that explain why Swift's async is slow on
# wasm32, and what the achievable floor is.  Each probe prints ns per call.
#
#   floor.swift      a hand-written status-return / driver-re-entry lowering,
#                    i.e. the shape a purpose-built compiler would emit
#   isolation.swift  plain async vs nonisolated(nonsending), which removes the
#                    executor hop (and, on wasm, the trampoline that bounds the stack)
#   executor.swift   replacing the global executor with one that runs jobs inline
#   depth.swift      what a resume costs in that lowering, as a function of depth
#   tiny.swift       the smallest async loop, with and without -mtail-call
set -euo pipefail
cd "$(dirname "$0")"
SDK_NAME=${SWIFT_SDK:-swift-6.3.3-RELEASE_wasm}
TC=${SWIFTLY_TOOLCHAIN:-6.3.3}
SDK=$HOME/.swiftpm/swift-sdks/$SDK_NAME.artifactbundle/$SDK_NAME/wasm32-unknown-wasip1
RES=$SDK/swift.xctoolchain/usr/lib/swift_static
RUN=${RUN:-wasmtime}

build() { # out extra-flags source
  swiftly run "+$TC" swiftc -O -parse-as-library -wmo -target wasm32-unknown-wasip1 \
    -sdk "$SDK/WASI.sdk" -sysroot "$SDK/WASI.sdk" -resource-dir "$RES" \
    -Xclang-linker "-resource-dir=$RES/clang" $2 "$3" -o "$1" 2>&1 |
    grep -v "unknown driver flag" | head -3 || true
}

for p in floor depth isolation executor tiny; do
  echo "===== $p"
  build "/tmp/probe_$p.wasm" "" "$p.swift"
  timeout 900 $RUN "/tmp/probe_$p.wasm" 2>&1 | head -6 || true
done

echo "===== tiny, with tail calls (expected: broken codegen in Swift 6.3.3)"
build /tmp/probe_tiny_tc.wasm "-Xcc -mtail-call" tiny.swift
timeout 900 $RUN --wasm tail-call=y /tmp/probe_tiny_tc.wasm 2>&1 | head -5 || true

echo "===== does the wasm target use the async tail-call convention?"
# Native async uses swifttailcc + musttail.  On wasm32 in Swift 6.3.3 neither appears,
# with or without -Xcc -mtail-call: the async lowering falls back to ordinary calls.
for cfg in "native:" "wasm:" "wasm+tailcall:-Xcc -mtail-call"; do
  lbl=${cfg%%:*}; flags=${cfg#*:}
  if [ "$lbl" = native ]; then
    swiftly run "+$TC" swiftc -O -parse-as-library -wmo -emit-ir tiny.swift -o /tmp/probe_ir.ll 2>/dev/null || true
  else
    swiftly run "+$TC" swiftc -O -parse-as-library -wmo -target wasm32-unknown-wasip1 $flags \
      -sdk "$SDK/WASI.sdk" -sysroot "$SDK/WASI.sdk" -resource-dir "$RES" \
      -emit-ir tiny.swift -o /tmp/probe_ir.ll 2>/dev/null || true
  fi
  printf "  %-16s swifttailcc=%-4s musttail=%-4s swiftasync-param=%s\n" "$lbl" \
    "$(grep -c swifttailcc /tmp/probe_ir.ll)" "$(grep -c musttail /tmp/probe_ir.ll)" \
    "$(grep -c 'ptr swiftasync' /tmp/probe_ir.ll)"
done

echo "===== native baseline for comparison"
swiftly run "+$TC" swiftc -O -parse-as-library -wmo floor.swift -o /tmp/probe_floor_native 2>&1 | head -2 || true
taskset -c 2 /tmp/probe_floor_native
