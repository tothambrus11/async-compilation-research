# Why Swift's async is slow on wasm32, and what actually helps

[`RESULTS.md`](../RESULTS.md) reports that a non-inlinable async call costs 556 ns in Chrome and
359 ns in Wasmtime, against 18 ns natively, and that recursive async programs either crawl or trap.
This note is the follow-up investigation: where that time goes, and which levers move it.

Probes are in [`probes/`](probes); `./probes/run_probes.sh` rebuilds and re-runs all of them.

## Where the time goes

Disassembling the module (`wasm2wat`) shows the resume partial function of every `await`:

```wat
(func $$s17microcall_asyncni4bodyyyYaFTQ1_ ...
    call $swift_task_dealloc
    call $swift_task_switch      ;; <- an executor hop, on every await
```

`swift_task_switch` is 331 instructions on wasm and can end in
`swift::AsyncTask::flagAsAndEnqueueOnExecutor`, the enqueue path. The measured cost says that is the
path being taken: a *non-suspending* await on wasm costs about what a *real suspension* costs
natively.

| operation | native | wasm (Wasmtime) | wasm (Chrome) |
|---|---:|---:|---:|
| non-inlinable sync call | 0.94 ns | 0.86 ns | 1.0 ns |
| non-inlinable async call, no suspension | 17.5 ns | 362 ns | 556 ns |
| real suspension (`Task.yield()`) | 342 ns | 1402 ns | — |

Native emits `swift_task_switch` too — nine call sites in the same binary — but takes its fast path.
On wasm the whole round trip is paid on every await.

## Why it cannot simply be removed

The hop is load-bearing on this target. Two independent ways of removing it both break the program:

- **`nonisolated(nonsending)`** (SE-0461), which makes the callee run on the caller's executor and
  removes the hop, speeds the native build up by 31 % (15.2 → 10.4 ns) and makes the **wasm build
  trap with `call stack exhausted`**. The backtrace alternates the callee and its resume function.
- **A custom global executor** installed through `swift_task_enqueueGlobal_hook` that runs jobs
  synchronously instead of queueing them **traps the same way**.

The reason is the missing tail call. Swift's async lowering expects the callee to *tail-call* the
caller's resume function; on a target without guaranteed tail calls that becomes a nested call, so
the stack grows with every await. Bouncing the continuation through the executor queue is what
returns to a shallow stack and keeps the program alive. **Swift's executor is acting as an
accidental trampoline, and its price is a general-purpose scheduler on every await.**

This also explains the shape of the results in `RESULTS.md`: loops survive but pay per await, while
recursion (`fib`) accumulates frames faster than the bounce can unwind them and dies.

## Levers, measured

| lever | effect |
|---|---|
| `-Ounchecked` | 370 ns vs 359 ns baseline. No effect. |
| `-Xfrontend -enable-default-cmo` (cross-module optimization) | `parser` 611 → 599 ms, about 2 %. |
| Non-resilience | The wasm stdlib does ship `.swiftinterface` files, so it is built resilient, but the hot path is the module's own code, compiled `-wmo`. Not the bottleneck. |
| `nonisolated(nonsending)` | Native −31 %. Wasm: traps. |
| Custom inline executor (`swift_task_enqueueGlobal_hook`) | Wasm: traps. |
| `-Xcc -mtail-call` | On Swift 6.3.3 it does not enable the async tail-call lowering at all. On a current toolchain it does, and then the link fails against the prebuilt runtime — see below. |
| Newer toolchain + hermetic-LTO stdlib | 351 → 285 ns per call, **−19 %**. The only lever that moved the number. |
| Engine choice | Wasmtime 359 ns vs Chrome 556 ns. Engines differ by ~1.5x; neither is the cause. |
| Toolchain version | Swift 6.3.3 and 6.5-dev are within noise natively (17.45 vs 17.10 ns). Not a version regression. |

## The tail-call path: compiler support exists, the runtime does not

This took three passes to get right, and the first two answers were wrong.

**Pass 1 — "tail calls are broken".** With Swift 6.3.3, `-Xcc -mtail-call` produced modules engines
reject. That looked like a codegen bug.

**Pass 2 — "the fix is not in this toolchain".** Comparing `-emit-ir` output showed 6.3.3 never
emitted the async tail-call convention for wasm at all, with or without the flag: it fell back to
ordinary `swiftcc` calls, where the same program built natively emits `swifttailcc` and `musttail`.
The `return_call` instructions the flag produced came from generic tail-call optimization elsewhere.

**Pass 3 — the actual blocker.** Pairing a current toolchain (`main-snapshot-2026-08-30`, Swift
6.5-dev) with a matching Wasm SDK, the compiler *does* emit the async convention for wasm32:

| build | `swifttailcc` | `musttail` | `swiftasync` param |
|---|---:|---:|---:|
| native | 15 | 7 | 7 |
| wasm32, Swift 6.3.3, `-Xcc -mtail-call` | 0 | 0 | 7 |
| wasm32, Swift 6.5-dev, `-Xcc -mtail-call` | **15** | **7** | 7 |

and emits 7 `return_call` instructions for the async transfers. The link then fails:

```
wasm-ld: warning: function signature mismatch: swift_task_switch
>>> defined as (i32, i32, i32, i32, i32, i32, i32) -> void in libswift_Concurrency.a(Actor.cpp.o)
>>> defined as (i32, i32, i32, i32, i32, i32)      -> void in <my code>.lto.o
```

The tail-call convention changes the signature of the runtime entry points, and **no shipping Wasm
SDK provides a concurrency runtime built with the same target feature**. wasm-ld emits a trapping
stub, and the module is rejected: `type mismatch: expected i32 but nothing on stack`. This is exactly
the blocker recorded in [swiftwasm#5568](https://github.com/swiftwasm/swift/issues/5568): "we need to
build separate stdlib builds for tail-call enabled and not."

Configurations tested, all with the same outcome:

| toolchain | Wasm SDK | result |
|---|---|---|
| Swift 6.3.3 | 6.3.3 release | no `swifttailcc` emitted at all |
| Swift 6.5-dev (2026-07-11) | swift.org snapshot, same date | emits it; signature mismatch on `swift_task_switch` |
| Swift 6.5-dev (2026-08-30) | SwiftWasm **hermetic-LTO**, same date | emits it; same mismatch |
| as above, plus `nonisolated(nonsending)` to remove the hop | | same mismatch: the stdlib still references the symbol |

Hermetic LTO was the most promising candidate, because it ships the Swift stdlib as bitcode that is
code-generated at link time with the final target features. It does not help: the *C++* concurrency
runtime (`libswift_Concurrency.a`) ships as prebuilt wasm objects, not bitcode, so `Actor.cpp.o`
keeps its non-tail-call signature regardless.

Getting past this needs a Wasm SDK whose concurrency runtime is compiled with `+tail-call`, which
means building the Swift runtime from source for wasm. That is the one experiment not run here.

## What `-Xcc -mtail-call` does, and does not do

A Clang flag looks like an odd lever on Swift codegen, so it is worth being precise. Swift derives
the LLVM target features it compiles with from the Clang importer's target configuration, so `-Xcc`
flags that set target features do reach the backend. That much is observable: the flag adds
`+tail-call` to the emitted `"target-features"` attribute.

What it does **not** do in Swift 6.3.3 is switch the async calling convention. Comparing
`-emit-ir` output for the same program:

| build | `swifttailcc` | `musttail` | `swiftasync` context parameter |
|---|---:|---:|---:|
| native, Swift 6.3.3 | 15 | 7 | 7 |
| native, Swift 6.5-dev | 15 | 7 | 7 |
| wasm32, Swift 6.3.3, with `-Xcc -mtail-call` | **0** | **0** | 7 |

On wasm the async functions keep their async context parameter but are emitted as ordinary `swiftcc`
functions with ordinary calls: the fallback regime that exists precisely because the target has no
guaranteed tail calls. The 27 `return_call` instructions the flag produces come from generic
tail-call optimization elsewhere in the module, not from the async lowering, and enabling that
optimization is what breaks the module.

So the honest statement is not "the fix is broken" but "the fix is not in this toolchain". Swift's
`swifttailcc` support for WebAssembly landed upstream between March and June 2026
([llvm#188296](https://github.com/llvm/llvm-project/pull/188296),
[clang#203330](https://github.com/llvm/llvm-project/pull/203330),
[swift#88074](https://github.com/swiftlang/swift/pull/88074)), after Swift 6.3 was released on
24 March 2026. It should be testable on 6.4 or newer; it could not be tested here because a Swift SDK
for WebAssembly only works with the exact toolchain version it was built for, and the newest
available pairing was 6.3.3.

## What would actually make it fast

**Working tail calls.** That is the designed fix, and everything else is a workaround for its
absence. The `tail-call` feature is in Wasm 3.0 and shipped in every engine, and the Swift compiler
now emits the right thing for wasm32. What is missing is a Wasm SDK whose concurrency runtime is
built with the same feature, so that the two sides agree on the signature of `swift_task_switch`.
Until such an SDK exists, async on wasm cannot use tail calls no matter what flags you pass.

**Upgrading the toolchain and using the LTO stdlib.** Worth a real but modest amount: a non-inlinable
async call goes from 351 ns (Swift 6.5-dev with the swift.org snapshot SDK) to 285 ns (same compiler
family with SwiftWasm's hermetic-LTO SDK), a 19 % improvement, against 0.9 ns for a sync call in
both.

**Failing that, a cheaper trampoline.** If a bounce is unavoidable, it does not have to be a
scheduler. The `floor.swift` probe measures the shape a purpose-built lowering would emit — the
callee owns an explicit frame, returns a status, and a driver loop re-enters it on a resume index:

| | wasm | native |
|---|---:|---:|
| plain non-inlinable call | 0.87 ns | 0.90 ns |
| status-return call | 1.88 ns | 0.88 ns |
| driver re-entry (resume-index dispatch) | 1.90 ns | 0.89 ns |

**1.9 ns per call on wasm, against Swift's 359-556 ns.** A trampoline is not inherently expensive;
a general-purpose executor used as one is.

## What this means for a new language

The 30x wasm penalty measured in `RESULTS.md` is not the price of "every function is a coroutine".
It is the price of Swift's runtime being pressed into service as a trampoline on a target its async
lowering was not designed for. A lowering that returns a status to a driver loop and re-enters frames
by index costs 1.9 ns per call on wasm — 2.2x a plain call, and roughly what it costs natively.

Three design rules follow, and they are the same ones the
[groundwork report](../../research/async-background.md) reaches on other evidence:

1. Do not depend on guaranteed tail calls. Make the resume a plain call from a driver loop.
2. Keep the await point trivial. Every piece of scheduler work there is paid on awaits that never
   suspend, which is most of them.
3. Keep the frame layout compiler-known and the resume dispatch a `br_table` on a small integer.
   That is what buys the 1.9 ns.
