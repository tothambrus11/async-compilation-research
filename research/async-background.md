# Exceptions, unwinding, panics and async: groundwork for Ferlium's async strategy

Research synthesis, 2026-09-04 (revised the same day to cover Teodorescu's spawn/await model).
Seven detailed, source-cited memos back this document; they are in `memos/` and are summarised and
reconciled here. Claim tags used throughout: **[V]** verified
against a primary source during this research, **[PK]** prior knowledge consistent with sources
but not re-fetched, **[?]** could not be verified or sources disagree, **[inference]** this
document's own conclusion drawn from verified facts, not a claim found in a source.

The reader is assumed to know Ferlium's current design: an HM-inferred language with a
row-polymorphic effect system (`read`, `write`, `fallible`), functions monomorphised per
instantiated effect row, `fallible` already lowered to a status-returning calling convention
with an explicit cleanup CFG (`invoke … error bN`, `propagate_error`), sandbox violations lowered
to a non-returning poison path, a MIR SSA IR, and a planned WASM backend emitted with
`wasm-encoder` (plus native later). Issue #18 asks for colorless async built on the effect system,
and the two candidate designs are: **(A) compile every function as a coroutine** (accepting a
uniform cost), or **(B) Lucian Radu Teodorescu's spawn/await model with stackful coroutines and
thread inversion**, as designed for Hylo and implemented in concore2full.

---

## 0. Findings that matter most for Ferlium

1. **Ferlium's existing error model is already the most portable one that exists.** "Errors are
   status values with explicit cleanup, panics are traps" is exactly what Swift (`swifterror`,
   `fatalError` → trap), Rust with `panic=abort` and Zig ship, and what Go on Wasm is reduced to (a
   panic cannot be propagated to the host). It needs nothing from
   native unwinders, DWARF CFI, personality routines, or the Wasm exception-handling proposal, and it
   is the only representation that crosses WASI component boundaries (which have no exception
   concept). Keep it. [V]
2. **Native unwinding is a well-understood, optional add-on, not a prerequisite.** Table-based
   ("zero-cost") unwinding costs 5–15 % of binary size and microseconds per throw, needs a
   personality routine and libunwind/libgcc, and became available in Cranelift only in 2025
   (`try_call`; Linux/macOS only, no Windows funclets). Add it only if catchable panics are a
   requirement. [V]
3. **Wasm exception handling (exnref) is standard and shipped everywhere that matters.** It is part
   of Wasm 3.0 (September 2025), in Chrome 137 / Firefox 131 / Safari 18.4, and on by default in
   Wasmtime since 47 (July 2026). `wasm-encoder` can emit it today. It cannot catch traps, stack
   overflow or out-of-memory. Its main value for Ferlium is (a) turning JS exceptions from imports
   into values and (b) optionally making panics observable to a host without killing the instance. [V]
4. **Wasm async comes in three families; only the compiler-transform family works on every engine
   and on native.** Binaryen Asyncify (≈50 % slower, 1–2× size), JSPI (standard, shipped in Chrome
   137, Firefox 153, Node 25, Safari 27 beta; JS hosts only), and core stack switching (Phase 3, no
   shipping engine). A state-machine/CPS transform needs no engine feature, is what Swift, Rust,
   Kotlin, C#, Dart, Hoot and wasm_of_ocaml's fallback all do, and it maps directly onto the WASI 0.3
   callback-style async ABI (released June 2026, default in Wasmtime 46). [V]
5. **Swift's async design is the closest published blueprint for a "frames off the stack, no stack
   switching" compiler.** Async functions are split into partial functions at each await, frames are
   caller-allocated from a per-task bump allocator, every transfer is a guaranteed tail call, errors
   travel as an extra argument of the continuation, and cancellation is a flag plus synchronously
   run handlers that never unwind. On Wasm the async context and error slot become padded `i32`
   parameters; no JSPI or Asyncify is needed. Generic `musttail` → `return_call` has existed in LLVM
   under `-mtail-call` for years, but Swift's async convention (`swifttailcc`) only gained Wasm
   support in LLVM in March–June 2026; it remains opt-in because the `generic` Wasm CPU lacks the
   feature, and without it non-suspending await loops exhaust the Wasm stack. [V]
6. **Teodorescu's model is a stackful design: "all functions are coroutines", `spawn`/`await` in
   one scope, and `await` never blocks because the awaiting thread and the worker thread swap stacks
   (thread inversion).** concore2full implements it on Boost.Context with 1 MiB malloc'd stacks per
   spawned task, an inline-execution fast path when the child has not started, and a
   `suspend(token)`/`notify()` primitive for I/O. Cancellation is not in the model yet, exceptions
   must not escape a coroutine, thread-local storage is banned, and calling in from thread-bound
   host code needs a blocking "get me back to my thread" wrapper. [V]
7. **On WebAssembly the two candidate designs collapse into one.** Stackful coroutines need engine
   stack switching (Phase 3, unshipped), JSPI (JS hosts only, one engine stack per in-flight task),
   or a compiler-managed re-enterable frame per function, which *is* option A. So the Hylo semantics
   can be kept on every target, but the Wasm implementation must be "every function is a coroutine
   with its locals in an explicit frame and a status check after every call", with native free to use
   real fibers. Both options, unlike effect-row-specialised CPS, allow suspending inside pure code, so
   fuel checks can become preemption points. Errors stay statuses, panics stay traps, and
   cancellation becomes "resume the suspended frame with a cancelled status", which reuses the
   existing fallible cleanup CFG.

8. **Measured: making every function async in Swift costs 1.0-4.3x on realistic programs, 20x on
   pure call overhead, and nothing at all where the optimizer can inline.** A ten-program benchmark
   (§6.5) puts a non-inlinable async call at 17.3 ns above a sync call and a real suspension at
   336 ns. The dominant cost is not the split calling convention but what the runtime does at the
   await point: the same program ran 49x slower when its async callee was inlined into an
   actor-isolated caller, turning every resume into an executor round trip. On `wasm32` in Chrome the
   picture changes: a non-inlinable async call costs 556 ns, recursive programs run 43-111x slower,
   and naive recursion traps outright, because Swift's lowering needs tail calls the target does not
   guarantee. [V]

---

## 1. How exceptions, unwinding and panics are compiled natively

Full detail: [Memo 1, native unwinding](memos/1-native-unwinding.md).

### 1.1 Three implementation families

| Family | Happy-path cost | Throw-path cost | Metadata | Users |
|---|---|---|---|---|
| Table-based ("zero-cost") unwinding | none in the instruction stream; binary size and locality | very high: µs per throw, global lock in libgcc, table walks | `.eh_frame` CFI + LSDA (Itanium), `.pdata/.xdata` (Win64), EHABI (ARM32), compact unwind (Apple) | C++ (Itanium and MSVC), Rust panics, .NET, Wasmtime's wasm EH, Swift for backtraces only |
| Explicit propagation (values, register slot) | one test-and-branch per fallible call | a return | none | Swift `throws`, Rust `Result`/`?`, Zig error unions, Go `error`, Midori, P0709 |
| setjmp/longjmp | save all callee-saved registers at every protected region | cheap | none, or a runtime chain | old GCC SJLJ, MinGW-32, Lua, libpng |

### 1.2 Itanium zero-cost unwinding, precisely

The Itanium C++ ABI splits the mechanism into a language-agnostic base (`_Unwind_RaiseException`,
implemented by libgcc_s or LLVM libunwind) and a language-specific personality routine
(`__gxx_personality_v0`, `rust_eh_personality`). Unwinding is two-phase: a search phase calls each
frame's personality with `_UA_SEARCH_PHASE` to find a handler without modifying anything, then a
cleanup phase re-walks the stack, running landing pads (destructors) and calling `_Unwind_Resume`
until it reaches the handler frame. The two phases exist so that an uncaught exception can call
`std::terminate` with the original stack intact. [V]

Per function, the compiler emits: a DWARF CFI entry (`.eh_frame` CIE/FDE, "bytecode-style"
`DW_CFA_*` instructions defining the canonical frame address and callee-saved register locations),
indexed by `.eh_frame_hdr` for binary search; and a language-specific data area
(`.gcc_except_table`) holding a call-site table (PC range → landing pad), an action table, and a type
table. In LLVM IR this is `invoke`/`landingpad`/`resume` plus a `personality` attribute; the backend
derives CFI and LSDA from them. [V]

Cost model, with sources: a trivial throw-and-catch costs about 1.1 µs versus about 11 ns for an
error-code return, and it scales linearly with stack depth [V]. libgcc's FDE lookup takes a global
lock through `dl_iterate_phdr`; on a 128-core EPYC, P2544R0 reports "we start to get performance
problems already at 0.1% failure rate" and the mechanism is "unusable at 1% failure rate or more"
[V]. Unwind tables were 14.7 % of the aarch64 native library size of
the Facebook Android app, versus 6.1 % with ARM EHABI [V]. Optimisation constraints are real: every
`invoke` ends a basic block and is a barrier to code motion, and values needed by the landing pad
must be kept available across the call.
The "1–2 µs per frame" figure often quoted could not be verified; the sources give roughly 1–2 µs
per shallow throw plus a per-frame component [?].

Windows x64 is also table-based (`RUNTIME_FUNCTION`, `UNWIND_INFO`, `__CxxFrameHandler4`) but runs
handlers as **funclets** before the stack is popped, which is why LLVM has a separate
`catchpad`/`cleanuppad` IR for it and why Cranelift's landingpad-style implementation cannot unwind
on Windows [V]. ARM EHABI (`.ARM.exidx/.ARM.extab`) and Apple compact unwind (a 32-bit opcode per
function, DWARF fallback for the rest) are size optimisations of the same idea [V].

### 1.3 Explicit propagation

Swift's `throws` is a second return channel: the callee writes the error box into a dedicated
register (`r12` on x86-64, `x21` on arm64, chosen because they are callee-saved so a non-throwing
function can be substituted for a throwing one), and the caller emits one test-and-branch after each
call [V]. LLVM exposes this as the `swifterror` attribute. Rust's `?`, Zig's error unions (16-bit
error codes plus `errdefer` and debug-mode error return traces), and Go's multiple returns are the
same mechanism without a dedicated register. Herb Sutter's P0709 proposes the same for C++;
P2544 measured a C++ emulation at ~25 % overhead under heavy failure rates. Khalil Estell's Cortex-M
work shows table-based EH can beat result types on code size past a certain number of propagation
sites, because each `if (err) return err;` costs code per call site whereas tables are paid once [V].

### 1.4 Panics

- **Rust.** `-C panic=unwind|abort|immediate-abort`. With abort, calls become `nounwind`,
  `invoke` becomes `call`, landing pads and LSDAs vanish; `-C force-unwind-tables` keeps
  `.eh_frame` for backtraces. `catch_unwind` needs `UnwindSafe`, double panic aborts, and RFC 2945
  defines `extern "C"` as abort-on-unwind with `"C-unwind"` for propagation; forced unwinding over
  frames with destructors is UB. Design invariant: switching unwind → abort must never introduce UB.
  On `wasm32-unknown-unknown` the default is `panic=abort`; `panic=unwind` needs nightly,
  `-Zbuild-std`, and `-Cllvm-args=-wasm-use-legacy-eh=false`. [V]
- **Go.** No LSDA, no personality: `runtime.gopanic` walks deferred calls using the compiler's own
  `pclntab` and per-function funcdata (open-coded defers), and `recover` resets SP/PC to the
  deferring frame. Possible only because Go owns the whole ABI. [V]
- **Swift.** `fatalError` and precondition failures compile to `ud2`/`brk` traps; Swift has no
  unwinder at all. [V]
- **JVM / .NET.** Per-method exception tables (JVM) and two-pass funclet EH (.NET). [V]

### 1.5 Unwinding through coroutines and async frames

C++20 coroutines wrap the body in an implicit `try/catch` routing to
`promise.unhandled_exception()`: the exception becomes a value at the coroutine boundary and is
never unwound *through* a suspended frame. Rust async needs nothing special: a panic in a
`poll` body unwinds out of `poll` like any call, the state machine's `Drop` drops locals held across
await points, and executors like Tokio apply a per-task `catch_unwind` policy. [V]

### 1.6 Backend options for a new language

- **Cranelift.** Between March and August 2025 Cranelift gained `try_call`/`try_call_indirect`:
  a block terminator with an exception table whose handlers are ordinary blocks receiving payloads
  via block parameters. Wasmtime's unwinder is one-phase and walks frame pointers itself.
  rustc's Cranelift backend proved the other integration: `try_call` plus a GCC-compatible
  `.gcc_except_table` and the system libunwind with `rust_eh_personality`, interoperating with C++
  unwinding on Linux; off by default, Windows unsupported. [V]
- **LLVM.** Full Itanium, WinEH, SJLJ and Wasm EH. CFI emission is free; the LSDA comes from
  `invoke` edges; you must supply or reuse a personality and link libunwind. [V]
- **Result-based.** Needs nothing. This is the Ferlium status quo.

Memo 1's own recommendation is the Rust model: errors as values, **panics as table-based
unwinding by default** (so destructors run before an abort), with a `panic=abort` build mode that
must never introduce UB, and async via poll-style state machines rather than stackful coroutines.
This synthesis departs from it on both points, deliberately: Ferlium's sandbox model already
defines unrecoverable failures as a poison path that runs no guest cleanup (a trap is the correct
lowering of that), it has no catch construct that a `panic=unwind` mode would serve, and the
colorless requirement of issue #18 is what motivates native fibers (§6). Memo 1's advice that
survives unchanged: keep frame pointers on (~0.5 % wall time) so a custom backtrace walker is
cheap, and if catchable panics are ever wanted, the Rust invariant (switching to abort never
introduces UB) is the rule to keep.

---

## 2. WebAssembly exception handling

Full detail: [Memo 2, WebAssembly exception handling](memos/2-wasm-exceptions.md).

### 2.1 The final design (exnref)

The legacy `try/catch/delegate/rethrow` design (Chrome 95, Firefox 100, Safari 15.2) was replaced
at the October 2023 CG meeting; the proposal repository was archived in April 2025 and the text now
lives on the `wasm-3.0` spec branch. Exception handling is a headline feature of **Wasm 3.0,
announced 2025-09-17**. [V]

Semantics that matter for a code generator [V]:

- **Tags** are declared in a new tag section (or imported/exported); a tag's payload types are the
  parameters of a function type. Tag identity is dynamic per instance; imported tags alias. Engines
  therefore cannot statically optimise handler lists.
- `throw tag` pops the payload and throws; `throw_ref` rethrows an `exnref` (traps if null).
- `try_table bt catch*` is an ordinary structured block whose catch clauses (`catch tag label`,
  `catch_ref tag label`, `catch_all label`, `catch_all_ref label`) **branch to an enclosing label**
  with the payload and/or `exnref` on the stack. There is no separate handler region; handlers are
  plain blocks, so the construct composes with `br`/`br_if`.
- `exnref` is a first-class nullable reference with its own `exn`/`noexn` heap-type hierarchy.
- **Traps are not exceptions.** `unreachable`, out-of-bounds access, division by zero, stack
  exhaustion and out-of-memory bypass every `try_table` and unwind to the host.
- **JS exceptions from imports are catchable** via the reserved `WebAssembly.JSTag` whose single
  payload is the JS value; an escaping wasm exception surfaces in JS as `WebAssembly.Exception`
  (`.is(tag)`, `.getArg(tag, i)`), and traps surface as `WebAssembly.RuntimeError`. Stack traces on
  wasm-originated exceptions are only captured on request (`traceStack: true`), for performance.
- Unwinding is **single-phase**; there is no search phase and no filters, which is why .NET's
  two-pass model and `std::set_terminate` cannot map onto it exactly.
- A `return_call` inside a `try_table` necessarily discards the handler (inference from the
  tail-call semantics; no explicit spec wording found) [?].

### 2.2 Engine support matrix

| Engine | Legacy EH | exnref EH (`try_table`) | Note |
|---|---|---|---|
| Chrome / Edge (V8) | 95 | **137** (2025-05-27) | one secondary source says 138 [?] |
| Firefox (SpiderMonkey) | 100 | **131** (2024-10-01) | |
| Safari (JSC) | 15.2 | **18.4** (2025-03-31) | |
| Node.js | 17 | **24.15** (2026-04-15) per feature table and wasm-bindgen; not in Node's notes [?] | Node 25 has it |
| Deno | 1.16 | 2.3.2 | |
| Wasmtime | never | **37** off by default (2025-09-20), **47** on by default (2026-07-20) | needs the `gc` cargo feature; exceptions at component boundaries become traps |
| Wasmer | never | **6.0** (2025-04-25) | LLVM/V8/JS backends; singlepass/cranelift unclear [?] |
| WasmEdge | – | 0.14 interpreter (2024), 0.18.0-alpha AOT/JIT (2026-08) | |
| wazero | never | **1.12.0** (2026-04-26), experimental flag | rejects legacy opcodes |
| wasmi | no | **no** (tracking issue open) | |
| WAMR | older draft behind a build flag | RFC open; not confirmed landed [?] | |
| wasm2c (wabt) | flag | `--enable-exceptions` (EHv4 in 1.0.37) | |
| Binaryen | yes | yes; `--translate-to-exnref` converts legacy → exnref | |

Baseline "widely available" for exnref in browsers is projected for 2027-11-29. [V]

### 2.3 Toolchains

- **LLVM/clang.** `-fwasm-exceptions`; LLVM 21 added the standard exnref lowering but the backend
  flag `-wasm-use-legacy-eh` still defaults to **true** on LLVM main today; pass
  `-mllvm -wasm-use-legacy-eh=false` for standard output. Wasm SjLj is built on the same machinery. [V]
- **Emscripten.** Three modes: abort on throw (default), JS-based EH via `invoke_*` trampolines
  (`-fexceptions`, high overhead, works everywhere), native `-fwasm-exceptions`. Emscripten 4.0
  added `-sWASM_LEGACY_EXCEPTIONS` (default true). JSPI is no longer experimental as of 6.0.8
  (2026-08-20). [V]
- **wasm-encoder / wasmparser (Ferlium's path).** `Instruction::TryTable`, `Throw`, `ThrowRef`,
  `Catch::{One,OneRef,All,AllRef}`, `TagSection`, `EntityType::Tag`; wasmparser enables
  `EXCEPTIONS` by default and disables `LEGACY_EXCEPTIONS`. Everything needed can be emitted and
  validated in Rust with no C++ toolchain. [V]
- **Rust.** `panic=unwind` on wasm is nightly-only (tracking issue 118168); wasm-bindgen 0.2.122
  (May 2026) emits exnref by default under `panic=unwind` and turns escaping panics into a JS
  `PanicError`; a 0.2.127 fix restored `__stack_pointer` after an unwinding export, i.e. shadow-stack
  leaks on unwind were a real bug until August 2026. Cloudflare moved Rust Workers to `panic=unwind`
  on Wasm EH in April 2026. [V]
- **Kotlin/Wasm.** Uses Wasm EH for language exceptions: `wasmJs` throws through the imported
  `JSTag` so JS `catch` sees real errors, `wasmWasi` declares its own tag with a `Throwable`
  payload, and a "traps instead of exceptions" mode exists. Kotlin 2.3 defaults `wasmWasi` to exnref;
  `wasmJs` stays legacy unless `-Xwasm-use-new-exception-proposal`. [V]
- **Go.** No Wasm EH; a panic reaching a `go:wasmexport` crashes the program. **Zig.** Errors are
  values; no unwinding. [V]

### 2.4 Unwinding without Wasm EH

| Strategy | Happy path | Throw | Size | Portability |
|---|---|---|---|---|
| Errors as values (multi-value returns) | one predicted branch per call | cheap, deterministic | moderate | universal, crosses component boundaries |
| Panic = trap (`unreachable`) | zero | instance dead | smallest | universal |
| Wasm EH | zero on V8/Cranelift; `try_call` clobbers all registers at protected sites | one allocation plus per-frame table lookups | small | Wasm 3.0 engines |
| JS-based EH (Emscripten `-fexceptions`) | JS call boundary per may-throw call | JS exception | large | browsers only |
| Asyncify | ≈50 % slowdown, 1–2× size | copies every frame's locals | large | universal |

### 2.5 Interaction with async proposals and the component model

- JSPI: a rejected promise is thrown into the suspended wasm at the suspension point as a `JSTag`
  exception, catchable with `try_table`; a wasm exception after resumption rejects the `promising`
  export's promise; traps also reject it. [V]
- Core stack switching: `resume_throw` injects an exception at a suspension point; a `try_table`
  around `resume` catches escapes; Wasmtime's stack switching depends on the exceptions feature. [V]
- Component model / WASI: **no exception concept**. Async adds `error-context` (opaque value with a
  debug message) as the error case of streams and futures; WASI 0.3 uses `result<_, error-code>`;
  Wasmtime 47 converts unhandled core exceptions at component boundaries into traps. Every WIT
  boundary must be `result`-shaped. [V]

---

## 3. Asynchrony and stack switching in WebAssembly

Full detail: [Memo 3, asynchrony in WebAssembly](memos/3-wasm-async.md).

### 3.1 Why Wasm needs special mechanisms, and the three families

A core Wasm instance has one implicit, non-addressable execution stack, structured control flow, no
first-class continuations, and synchronous imports: a JS host cannot block a wasm frame on a
Promise because the event loop cannot advance while the frame is on the JS stack. [V]

**(a) Binary-level transformation: Asyncify.** A Binaryen pass instruments every function that can
transitively reach an unwinding import so that the live wasm call stack can be *unwound* into a
linear-memory buffer and *rewound* later (a global state normal/unwinding/rewinding is checked
around every such call). Typical cost: 1–2× code size and "50 % or so" slowdown, needing `-O3` and
curated import lists; not reentrant. WordPress Playground's PHP port needed a hand-maintained
function whitelist because auto-detection instrumented ~70,000 functions. TinyGo's default wasm
scheduler is Asyncify-based. [V]

**(b) Language-level CPS / state machines.** The compiler rewrites each function that may suspend so
its live state is heap-allocated and re-enterable: LLVM's three coroutine lowerings (switched-resume
for C++20, returned-continuation for Swift `yield`, async lowering for Swift `async`), Kotlin's
`Continuation` parameter plus label state machine, Dart's `_AsyncSuspendState` with `br_table`
resumption, Rust's `poll` state machines. Go's gc compiler does a compiler-integrated Asyncify:
goroutine stacks in linear memory, every function resumable through a `PC_B` resume-point register
and an entry `br_table`. Nothing in wasm is required; a host event loop drives it. [V]

**(c) Engine-level stack switching.** JSPI (JS-API only, tied to Promises) and the core Stack
Switching proposal (typed continuations, WasmFX lineage, merged with the "fibers" design in 2024
into one proposal with both asymmetric `suspend`/`resume` and symmetric `switch`). [V]

### 3.2 JSPI

API: `new WebAssembly.Suspending(jsFn)` wraps an import; if it returns a Promise the wasm
computation suspends and the resolved value becomes the import's result. `WebAssembly.promising(export)`
wraps an export into a Promise-returning function. V8 runs each `promising` call on a separately
allocated stack (about 1 µs per suspension; stacks were ~1 MB fixed-size as of June 2024, growable
stacks were under investigation and their shipping status could not be verified [?]). Suspension is
legal only when only wasm frames lie between the `promising` entry and the `Suspending` import;
otherwise `WebAssembly.SuspendError`. Multiple promising calls may interleave, so guest globals (the
shadow stack pointer) must be re-entrant. [V]

| Runtime | JSPI status |
|---|---|
| Standard | Phase 5 (finished April 2025) |
| Chrome / Edge | **137** (2025-05-27) |
| Firefox | **153** (2026-07-21) by default; earlier behind `javascript.options.wasm_js_promise_integration` (V8's blog says "Firefox 139", which was the flagged version) |
| Safari | **27 beta** (announced 2026-06-08); stable Safari ≤ 26.6 unsupported; WebKit withdrew its objection late 2025 |
| Node.js | **25.0.0** (2025-10-15) by default; 22/24 need `--experimental-wasm-jspi` |
| Deno / Bun | not verified [?] |
| Emscripten | `-sJSPI` (needs ≥ 3.1.61); "no code size increase"; non-experimental since 6.0.8 |

### 3.3 Core stack switching

Phase 3. Instruction set: `cont` types, `cont.new`, `cont.bind`, `resume` with `on tag label`
handler clauses, `suspend tag`, `switch`, `resume_throw`; continuations are one-shot. V8 has it
behind `--experimental-wasm-wasmfx` (wasm_of_ocaml's `--effects=native` needs Chrome 148+ with the
flag); Wasmtime has an experimental, off-by-default, x86-64-Linux-only implementation with
`resume_throw` and GC integration still missing as of August 2026; no SpiderMonkey/JSC
implementation was found. Shipping in 2026 is implausible; 2027–2028 at the earliest is a reasonable
guess [inference]. Threads are orthogonal: the threads proposal gives shared memory and atomics
only, wasi-threads is withdrawn (Wasmtime removed `-Sthreads` in 47), shared-everything-threads is
Phase 1. Wasm has no native green threads. [V]

### 3.4 WASI and the component model

WASI 0.2 polls `pollable`s in-guest (each component runs its own loop, no cross-component
coordination). **WASI 0.3.0 was released 2026-06-11 (0.3.1 on 2026-08-11)**: `async func`,
`stream<T>`, `future<T>`, `error-context` in WIT; `wasi:io` removed; Wasmtime 46 (2026-06-22)
enables component-model async by default; Rust has a tier-3 `wasm32-wasip3` target with a 2026 goal
to promote it. [V]

The canonical ABI implements async **without stack switching in the guest** via the stackless
("callback") lift: the core export returns an `i32` code (`0` done, `1` yield, `2 | (waitable_set << 4)`
wait), and the runtime repeatedly calls the `callback` export with `(event_code, index, payload)`
until it returns 0. Between events the engine's native stack is empty, so the guest must be a state
machine, which is exactly what a language-level transform produces. A stackful lift exists for
languages like Go (feature-gated, 🚟 in the spec). Wasmtime's host-side `async_support` (host fibers, epoch/fuel yields) is
independent and invisible to the guest. [V]

### 3.5 How languages target Wasm async today

| Language | Mechanism | Verified detail |
|---|---|---|
| Rust (browser) | state machines + microtask executor | `js_sys::futures` queue uses `queueMicrotask`, falling back to `Promise.resolve().then`; a new `jspi_block_on_promise` escape hatch keeps JSPI out of modules that don't use it |
| Rust (WASI) | state machines + `wstd` `block_on` over pollables (0.2); wit-bindgen `async` on p3 | tier-3 `wasm32-wasip3` since Rust 1.92 |
| Swift | LLVM async lowering, no stack switching | `JavaScriptEventLoop` executor; see §4 |
| Kotlin/Wasm | CPS + state machine | dispatchers on `process.nextTick` / `Promise.resolve(0).then` + `postMessage` / `setTimeout`; needs WasmGC + EH |
| C# / Blazor | C# state machines; Promise↔Task marshalling | JSPI issue 80904 still open; .NET 10 shipped without it |
| Go (gc) | compiler-built stack unwinding, goroutines in linear memory | single-threaded; "any host function call blocks all goroutines"; reactor mode since Go 1.24 |
| TinyGo | Asyncify (default `-scheduler=asyncify`) | panics → `unreachable` |
| Python (Pyodide) | JSPI (`run_sync`), formerly Asyncify | |
| OCaml (wasm_of_ocaml) | four modes: `--effects=jspi` (default), `cps` (selective, any engine), `double-translation` (direct and CPS versions, chosen at run time), `native` (stack switching, flagged Chrome) | the best real-world data point of all three families in one compiler |
| Scheme (Guile Hoot) | minimal CPS with explicit stacks | "10× penalties in some cases"; awaits core stack switching |
| Dart | state machine (`_AsyncSuspendState` + `br_table`) | |

### 3.6 Comparison

| Property | Asyncify / Go-style | CPS / state machines | JSPI | Core stack switching | Component async (callback ABI) |
|---|---|---|---|---|---|
| Engine feature needed | none | none | JS-API feature | Phase 3 proposal | component host (Wasmtime ≥ 46, jco) |
| Browsers, 2026 | all | all | Chrome 137+, Firefox 153+, Safari 27 beta, Node 25+ | none shipped | n/a (jco polyfills) |
| Wasmtime | yes (host implements protocol) | yes | no (not a JS host) | experimental, x86-64 Linux | default in 46+ |
| Code size | +50–100 % unless pruned | modest per suspending function | ≈0 | ≈0 | ≈0 |
| Runtime cost | ~50 % on instrumented paths | heap frame per coroutine, indirect resume | ~1 µs per suspension; ~1 MB stack per in-flight call as of mid-2024, growable stacks unverified | cheapest in principle | one host round-trip per event |
| Suspend inside host frames | never | never (every frame transformed) | only across wasm frames | only across wasm frames | only at ABI boundaries |
| Reentrancy | unsafe by default | safe | allowed but guest globals must be re-entrant | safe | safe |
| Works on native too | no | **yes, same IR** | no | no | no |

---

## 4. How Swift compiles async functions

Full detail: [Memo 4, Swift async](memos/4-swift-async.md) (native) and [Memo 5, Swift and others on Wasm](memos/5-swift-on-wasm.md) (Wasm).

### 4.1 Calling convention and the async context

Registers (from `docs/ABI/CallingConventionSummary.rst`) [V]:

| Role | x86-64 | arm64 |
|---|---|---|
| async context (`swiftasync`) | r14 | x22 |
| error (`swifterror`) | r12 | x21 |
| self (`swiftself`) | r13 | x20 |

All three are callee-saved in the base C ABI, so they survive C calls. In LLVM IR they are
parameter attributes; async functions use the `swifttailcc` calling convention, which pops the
argument area so `musttail` is always possible. [V]

The `AsyncContext` on `main` today has exactly two fixed words, `Parent` and `ResumeParent` (the
widely quoted `Flags` word is gone; it survives only on `ContinuationAsyncContext`). Everything after
the header is the function's spilled frame. On arm64e both words are PAC-signed with distinct
discriminators. [V]

An async function is referenced by an **async function pointer**: a 32-bit relative pointer to the
entry function plus `ExpectedContextSize`. The caller allocates the callee's frame using that size
(`swift_task_alloc`, or in-frame when the size folds to a constant), stores `Parent` and
`ResumeParent` (the address of the caller's next partial function) into it, and tail-calls the
callee with the context in the context register. The size is a runtime datum because it is only
known after LLVM's CoroSplit computes the spill set and it may live in another, resilient module;
vtables and witness tables dispatch through AFPs too. [V]

### 4.2 Pipeline: SIL → LLVM async lowering → partial functions

SIL treats `async` as a function-type attribute with ordinary `apply`/`try_apply`, plus
`hop_to_executor`, `get_async_continuation`, `await_async_continuation`. IRGen emits each async
function as an LLVM coroutine using the **async lowering** (`llvm.coro.id.async`,
`llvm.coro.suspend.async`, `llvm.coro.async.resume`, `llvm.coro.end.async`). CoroSplit splits it
into a ramp function plus one resume function per suspend point ("partial functions"); values live
across a suspend are stored in the frame that is the tail of the async context; results of a callee
arrive as *arguments* of the caller's resume function, not through memory. Every transfer (call,
return, hop, resume) is a `musttail` call, so the native stack is at the same depth after a transfer
as before; when a function actually suspends it enqueues itself and returns to the executor loop,
and nothing on the machine stack outlives an `await`. WWDC21: "this list of async frames is the
runtime representation of a continuation." [V]

LLVM's three lowerings, precisely [V]:

| | Switched-resume (`coro.id`) | Returned-continuation (`coro.id.retcon`) | Async (`coro.id.async`) |
|---|---|---|---|
| Frame owner | ramp mallocs a frame (elidable) | caller-supplied buffer, overflow mallocs | caller-allocated async context, frame is its tail |
| Resume | `coro.resume(handle)` switches on an index | call the continuation pointer returned by the previous suspend | call the resume function; all transfers are tail calls |
| Values | via promise / memory | yielded with the continuation | as arguments through the context |
| Users | C++20 coroutines | Swift `_read`/`_modify` accessors | Swift `async` |

Async backtraces: the `swiftasync` attribute makes the target emit an extended frame record. On
AArch64 the context pointer sits directly before FP; on x86-64 bit 60 of the saved frame pointer is
set (statically or by OR-ing a runtime-provided flag word for OS back-deployment). Debuggers detect
the bit, read the context, and follow `Parent` links. [V]

### 4.3 Executors and scheduling

`Job` is a heap object with flags and a `ResumeTask`; `AsyncTask` is a `Job` with resume context
and function plus trailing fragments (child, group, future). The runtime funnels non-actor work
through `swift_task_enqueueGlobal`; the backend is chosen at build time (libdispatch with a
cores-wide concurrent queue; a single-threaded cooperative priority queue on WASI). Function-pointer
hooks (`swift_task_enqueueGlobal_hook`, `…WithDelay_hook`, `…MainExecutor_hook`, `…DrainQueue_hook`)
let a platform reroute everything; JavaScriptKit uses them. The whole executor contract is about ten
C entry points in `ExecutorImpl.h`, which is why Wasm, WASI and microcontrollers work with no
compiler changes. A Swift-level "custom main and global executors" API is still a pitch (Pitch 4,
August 2026); the delayed-enqueue part was split into SE-0505 and returned for revision. [V]

`hop_to_executor` lowers to `swift_task_switch`: if the current and target executors match, it tail-
calls the resume function immediately (same-executor hops are free); otherwise it parks the task, and
if the current executor can give up its thread and the target actor is free, the same thread takes
the actor and runs the task without enqueueing. SE-0417 task executors provide threads while serial
executors provide isolation; preferences are stored as task status records. [V]

### 4.4 Cancellation

SE-0304: "cancellation has no effect at all unless something checks for cancellation." It never
unwinds, never injects control flow, never interrupts a thread. [V]

Runtime structure [V]: every task has a 16-byte atomic `ActiveTaskStatus` (flags incl.
`IsCancelled`, `IsStatusRecordLocked`, `IsRunning`, `HasActiveTaskCancellationShield`,
`HasTaskCancellationScope`, `HasDeadline`; an execution lock word; and the head of an intrusive
linked list of status records: `ChildTask`, `TaskGroup`, `CancellationNotification`,
`EscalationNotification`, `TaskDependency`, `TaskExecutorPreference`, `Deadline`,
`TaskCancellationScope`, `CancellationShield`). Records are allocated from the task's stack
allocator and pushed/popped in scope order; the innermost record pushes and pops lock-free, anything
else takes a bit-in-atomic lock backed by a recursive mutex.

`swift_task_cancel` [V]: CAS-set the cancelled bit (idempotent, "first cancel wins on reason"),
then under the status-record lock walk the records: child-task records cancel each child recursively
and eagerly; task-group records cancel the group's children; cancellation-notification records **run
the handler closure synchronously on the cancelling thread while the lock is held** (unless a shield
is active). `withTaskCancellationHandler` pushes such a record and, if the task is already
cancelled, runs the handler immediately before the operation. Because the handler and the operation
race, every parking primitive implements a small atomic state machine; `Task.sleep` is the reference:
states `notStarted / activeContinuation / finished / cancelled / cancelledBeforeStarted`, the cancel
handler resumes the continuation with `CancellationError`, and the later timer job just observes
`.cancelled` and deallocates. Task groups: a throwing child does not cancel siblings until `next()`
surfaces it, but throwing out of the group body cancels all and still awaits every child; structured
scopes never leak running work. Task-locals are a separate parent-linked list, not status records.
Newer additions on `main` (cancellation reasons, shields, sub-scope cancellation, deadlines) show a
bare flag was not enough.

### 4.5 Errors

Synchronously, `throws` is the `swifterror` register described in §1.3. In an async function there
is no return, so the error is appended as the **last argument of the tail call to `ResumeParent`**
(`emitAsyncReturn`), with results set to `undef` on the throw path; the entry signature reserves a
context slot so a non-throwing function can be substituted for a throwing one. Typed throws
(SE-0413) change the ABI: a typed error is returned directly, merged with the result aggregate,
unless it must be indirect, in which case an extra pointer parameter is added; `throws(Never)` is
ABI-identical to non-throwing. `Task`'s future fragment stores either the result or the error;
`fatalError` traps. [V]

Continuations (SE-0300): `swift_continuation_await` CASes `Pending → Awaited` and, if the callback
already fired, tail-calls the resume path without ever suspending; `resume` writes the result, CASes
to `Resumed`, and if the awaiter had parked, enqueues the task on **its original executor**.
Cancellation does not touch continuations; only user code combining a cancellation handler with a
continuation does. [V]

### 4.6 Memory model and design rationale

`swift_task_alloc` is a bump allocator over slabs obeying a strict stack discipline (first slab 512
bytes inside the task allocation, later slabs sized to a 1 KiB malloc quantum, slabs reused not
freed). Because async calls nest LIFO it behaves as a segmented per-task stack; only `Task {}`
(own allocation) and `async let` children (pre-allocated inside the parent's frame) escape LIFO
order. Swift chose this over stackful coroutines so that threads never block, switching costs "a
function call", the runtime is C-writable, and sync code calling async is impossible by
construction; the price is a non-resilient ABI split and an indirect load plus allocation per async
call, mitigated by `coro.prepare.async` (inlining after splitting) and static-size folding. [V]

### 4.7 Swift async on WebAssembly

SwiftWasm status: Swift 6.2 (September 2025) made Wasm an official target; swift.org hosts SDKs
(`swift-6.3.3_wasm` and an Embedded variant, "Hello, World!" 9.7 kB); targets are
`wasm32-unknown-wasip1`, `wasm32-unknown-wasip1-threads` (not in the swift.org SDK; the swiftwasm
project publishes one), `wasm64-unknown-none-wasm` (Embedded), and a new `wasm32-unknown-emscripten`
(June–July 2026). Goodnotes ships 2.2 M lines of Swift to the web (≈50 MB wasm, ≈12 MB Brotli). [V]

**Tail calls, the central issue.** IRGen picks the async convention per target: if Clang reports
`CC_SwiftAsync` as supported, it uses `swifttailcc` with `musttail`; otherwise plain `swiftcc` with a
best-effort `tail` and `ret void` where `unreachable` would follow the tail call. Clang's Wasm target
answers `CC_SwiftAsync` with `HasTailCall ? CCCR_OK : CCCR_Error`, and that support is brand new:
LLVM PR 188296 "Wasm: add support for swifttailcc" merged 2026-03-31 and PR 203330 "enable
swiftasynccall for Wasm" merged 2026-06-18, closing swift issue 69333 (open since October 2023).
`-mtail-call` is not on by default in the Swift compiler nor in LLVM's `generic` Wasm CPU; the
stdlib build scripts contain no tail-call flag, and the SwiftWasm tracking issue 5568 (still open)
lists "separate stdlib builds for tail-call enabled and not" as a blocker, so released SDKs run
async **without** tail calls [V, with the shipped-stdlib status flagged ?]. The two regimes are
different LLVM calling conventions and differ in Wasm signatures, so mixing is an ABI hazard.
LLVM refuses to silently degrade `musttail` on Wasm without the feature (it fails the compile), and
CoroSplit only marks async resumes `musttail` when the target supports tail calls (Yuta Saito's
LLVM PR 81481, February 2024). [V]

**Consequence without tail calls: unbounded stack growth.** Each async→async call and each resume
is a real Wasm `call`, so a CPU-bound await loop nests frames. swiftwasm issue 5614 (November 2025,
Swift 6.1 SDK) reproduces with `for _ in 0..<500000 { try await hello() }` → "wasm trap: call stack
exhausted" with a 6,000-deep backtrace alternating `swift_task_switch` and partial functions; Saito:
"This is one of the major limitation of our Wasm target support." Workarounds: larger linker stack
sizes and `wasmtime --wasm max-wasm-stack` (one user needed 16 MiB). Real apps mostly survive
because every actual suspension returns to the executor loop, so only non-suspending await chains
accumulate depth [inference]. Tail calls themselves are standard (Wasm 3.0), shipped in Chrome 112,
Safari 18.2 (Baseline since 2024-12-11) and Wasmtime 22 [V]; Firefox 121 [PK].

**Registers become parameters.** The Wasm backend pads every `swiftcc`/`swifttailcc` function with
the special parameters even when the IR omits them, so caller and callee signatures match for
indirect calls: `func foo(_: Int)` becomes `(param i32 i32 i32)` at the Wasm level (LLVM D76049,
2020; documented in tool-conventions `SwiftABI.md`). This padding caused a real miscompile of async
typed-throws calls on wasm32 (indirect typed-error pointer and context slot at different positions
for thin versus thick callers), fixed in swift PR 89715 (2026-07-14). [V]

**Errors on Wasm.** LLVM's Wasm lowering does not override `supportSwiftError()`, so the
`swifterror` argument is an ordinary pointer to a caller-owned slot in linear memory passed as the
padded trailing `i32`; `throws` costs one extra parameter plus a load and branch after each call, with
no EH tables. `fatalError` → `abort()` → wasi-libc's `__builtin_trap()` → `unreachable`, which
poisons the instance. No use of `-fwasm-exceptions` was found in the Swift-on-Wasm build scripts
that were read, and the runtime's C++ is believed to be built without exceptions, but no build line
proving either was located [PK, ?]. WasmKit, Swift's own interpreter,
implements the EH proposal as of 0.3.0 for guests that need it. [V]

**Task allocator and executors on Wasm.** `swift_task_alloc` is unchanged: slabs come from `malloc`
in linear memory, so async frames live on the heap, not the shadow stack, and survive returning to
the host. The Wasm stdlib is built single-threaded (`SWIFT_STDLIB_SINGLE_THREADED_CONCURRENCY`,
`SWIFT_THREADING_PACKAGE=none`), so the runtime's atomics compile to plain loads and stores unless
the `-threads` stdlib (built with `-matomics -mbulk-memory -pthread`) is used. The default cooperative
executor drains a run queue and *blocks* in `_sleep` until the next timer deadline, fine for WASI
CLIs. In the browser `JavaScriptEventLoop.installGlobalExecutor()` either uses the experimental
executor-factory SPI (Swift ≥ 6.3 on wasm32, non-Embedded) or overwrites the legacy hooks; immediate
jobs go through `promise.then` on a pre-resolved promise (a microtask), delayed jobs through
`setTimeout`; per-thread event loops under the multithreaded runtime bounce jobs to the main thread
with `postMessage`. The stdlib's main drain loop calls `_exit(0)` when it finishes, so JavaScriptKit
implements `swjs_unsafe_event_loop_yield` as `throw new UnsafeEventLoopYield()`: a JS exception that
unwinds the whole Wasm stack back to the JS caller of `main`, which swallows it. Modules must be
built as WASI *reactors* (`-mexec-model=reactor`) so the instance stays alive. A `WebWorkerTaskExecutor`
(SE-0417) runs tasks on Web Workers over shared memory. Outside the browser, embedders capture jobs
via `swift_task_enqueueGlobal_hook` and export a `pump(budget:)` the host calls. [V]

**Does SwiftWasm need JSPI or Asyncify?** No: suspension is "return to the executor" and the JS
event loop resumes via exports. Blocking primitives such as `DispatchSemaphore.wait` freeze the
single-threaded module. An early 2020 SwiftWasm experiment used `wasm-opt --asyncify` for sleeping;
it is not used today [?, secondary source]. Embedded Swift on Wasm supports async through the hook
API; its timer branch is compiled out, so timers need a host. [V]

**Cancellation on Wasm.** Unchanged: the cooperative flag and status records; the only target-
specific aspect is the non-atomic lowering of the status word in single-threaded builds. [V]

---

## 5. Colorless async and effect-typed suspension

Full detail: [Memo 6, colorless and effect-typed async](memos/6-colorless-effects.md) and [Memo 7, Teodorescu's spawn/await model](memos/7-hylo-spawn-await.md).

### 5.1 The three escapes from function colouring

Nystrom's essay names the cure Go, Lua and Ruby share: "multiple independent callstacks that can
be switched between." An effect-typed language reframes the problem: suspension is still a property
of a function but is inferred and polymorphic. Under any *stackless* strategy the colour still exists in the compiled
artefact (a suspending `map` cannot share machine code with a non-suspending one); only stackful
designs (Go, Lua, Loom, OCaml 5 fibers, the Hylo model) let one body serve both. Either way it
vanishes from the source. [V]

- **Stackful.** Go (2 KB initial contiguous stacks, prologue stack checks, `morestack` copying with
  pointer adjustment, which requires GC-grade stack maps); Lua (one `lua_State` per coroutine, error
  on "yield across a C-call boundary" because the host's native stack cannot be captured); Java Loom
  (virtual-thread stacks frozen into heap `StackChunk`s, thawed lazily; the basis of Scala's Ox and
  Gears); OCaml 5 fibers (heap stacks with prologue overflow checks). [V]
- **Zig's two eras.** Zig 0.9 was colorless in exactly Ferlium's sense: a function became async if
  it contained `suspend`/`await`; frames were caller-allocated with `@Frame(f)` sizes; function
  pointers needed `@asyncCall` with an explicit frame buffer because the convention differed. It
  was removed because it tied the language to stackless coroutines and could not solve frame sizes
  for recursion/indirect calls or the calling convention leaking into every function pointer. Zig
  0.16's `std.Io` (2025–26) makes I/O an injected vtable like `Allocator`; `io.async` decouples
  call from completion without promising concurrency; `Future.cancel` is idempotent; the shipped
  implementation is thread-based, with stackful coroutine implementations as proofs of concept and
  compiler-lowered stackless frames (`@asyncFrameSize`, `@asyncResume`, …) proposed in issue 23446
  precisely because they lower to synchronous constructs on WebAssembly and SPIR-V. [V]
- **Compiler-driven CPS / state machines.** Kotlin (`Continuation` parameter, `COROUTINE_SUSPENDED`
  marker, label state machine; a suspend function whose only suspension is a tail call to another
  suspend function gets no state machine; `inline` lambdas are the escape hatch for higher-order
  code); C#; Rust (poll-based, chosen over green threads for FFI/embedding cost and over CPS
  because "CPS too often required allocating the callback"; cancellation = drop); Swift (§4). [V]
- **Engine-level.** JSPI, core stack switching, OCaml fibers, Loom. [V]

### 5.2 Effect handlers as the general mechanism

| System | Continuations | Representation |
|---|---|---|
| OCaml 5 | one-shot; resuming twice raises `Continuation_already_resumed` | fiber = heap stack chunk; capture is a pointer grab |
| Koka | multi-shot supported | evidence passing + yield bubbling + monadic translation to C; multi-shot copies the resumption stack |
| Effekt | one-shot O(1); multi-shot by copying | capability passing; JS monadic runtime; LLVM via a machine IR (ICFP 2025 "Multiple Resumptions … Directly") |
| Flix | multi-shot, deep, dynamically scoped | JVM; compilation strategy not verified [?] |
| Unison | abilities | interpreted |

Koka's async is a 2017 design (structured asynchrony with handlers over libuv) whose `std/async`
branch is unfinished in Koka 3 [V]. wasm_of_ocaml ships four lowerings of the same effect semantics:
`--effects=jspi` (default), `--effects=cps` (selective: an analysis keeps code that cannot involve
effects in direct style), `--effects=double-translation` (both versions, chosen at run time), and
`--effects=native` (core stack switching behind a V8 flag) [V]. Scala goes the other way: capture checking tracks capabilities statically and Loom does the
suspension [V].

**One-shot vs multi-shot is the decisive cost axis.** Async/await, generators, exceptions and
cancellation are all one-shot; only backtracking needs multi-shot and every system that supports it
pays with stack copying. Ferlium should commit to one-shot (linear) continuations: that is what makes
"cancellation = drop the frame" and "the frame owns its temporaries" well-defined.

### 5.3 Effect-row specialisation (the Koka approach), as an optimisation

This subsection describes how an effect system can *limit* the coroutine transformation to functions
whose row contains a suspend effect. It is not what issue #18 intends (the candidates are "every
function is a coroutine" and the Hylo model, both of which make every function suspendable), but it
is the natural optimisation of option A once the uniform design works, so it is kept here.

Koka's generated C (ICFP 2021 "Generalized Evidence Passing", §2.10–2.11) [V]:

```c
int expr(unit_t u, context_t* ctx) {
  int x = perform_ask(ctx->w[0], unit, ctx);
  if (ctx->is_yielding) { yield_extend(&join2, ctx); return 0; }
  int y = perform_ask(ctx->w[0], unit, ctx);
  if (ctx->is_yielding) { yield_extend(alloc_closure_join1(x, ctx), ctx); return 0; }
  return x + y;
}
```

Properties: a type-selective transform leaves total functions untouched; the pure fast path does no
allocation and preserves tail recursion; continuations are built lazily by pushing join points as
the yield bubbles up, so a frame costs a closure only when a real suspension happens; evidence
offsets are static for closed rows and looked up for polymorphic rows; the per-call flag check "seems
quite cheap on modern processors and the condition can be predicted well."

This is structurally Ferlium's `fallible` lowering with one addition: on a `Suspended` status the
caller must spill its live locals into a heap continuation frame and push a resume point before
returning the status upward. Two ways to spill:

- **Lazy, bubbling (Koka).** Allocate a join-point closure at each check only when suspension
  actually happens. Zero cost until then; resumption re-enters join points (not inlined).
- **Eager frame (Kotlin/Rust/Swift).** The state-machine frame exists up front (caller-sized as in
  Zig 0.9 and Swift, or task-allocated); locals live in it; suspension is "store label, return".
  Constant per-call cost even when nothing suspends, no allocation at suspension, trivial
  cancellation (drop the frame).

Because Ferlium monomorphises per effect row it can choose per instantiation: `map<e = {}>` is
untouched direct style; `map<e = {suspend}>` gets checks and spill code. This is Kotlin's `inline`
benefit obtained generally.

**Code size multipliers to budget:** one copy per distinct effect row per function (already paid for
`fallible`); within a suspending copy, naive monadic translation duplicates continuations at each
bind (Koka's join-point sharing reduces 2^N to 2N for N sequential effectful statements); Asyncify
instead would cost ~50 % globally. [V]

**First-class function values of unknown effect: the real problem.** A closure of type `a -> e b`
stored in a data structure needs one ABI at the call site. Precedents: Kotlin makes
`suspend () -> T` a distinct type (the colour reappears at the function-type level); Swift makes sync
and async function types distinct with implicit sync→async thunking only; Zig 0.9 needed
`@asyncCall`; Rust must box `dyn Future` and `async fn` in traits are not object-safe (hence
`async-trait`/`dynosaur`); **Koka gives every function one ABI** (all take `ctx`, all may set the
yielding flag), and effect types only decide whether the callee gets checks and binds, so the caller
of an unknown-effect value always emits the check. [V]

If specialisation is ever pursued, the ABI question resolves as follows: adopt Koka's uniform ABI
for function values whose effect row is open or contains `suspend`: the `suspend`-instantiated ABI is "status-return, may have suspended", and a
non-suspending closure is coercible into it by a thunk that never sets the flag (Swift's sync→async
direction). Closed suspend-free rows keep the plain ABI. Monomorphic code stays zero-cost;
higher-order and dynamic code pays one predictable branch per call rather than a boxing allocation;
frame size for dynamic callees is not a problem because Koka-style frames are allocated by the callee
at suspension time.

### 5.4 Cancellation semantics compared

| System | Mechanism | What the compiler must provide |
|---|---|---|
| Rust | drop the future; cancel-safety hazards (`select!` drops losers); `AsyncDrop` nightly-only and incomplete | complete synchronous drop glue for all live temporaries at every suspension point |
| Swift | cooperative flag; `checkCancellation()` throws `CancellationError` | nothing beyond error propagation |
| Kotlin | cooperative; parked coroutines resumed immediately with `CancellationException`; `Job`/`coroutineScope` | exception deliverable into a parked continuation |
| Go / C# | `context.Context` / `CancellationToken` | none |
| OCaml Eio | cancellation-context tree; any fiber switch may raise `Cancelled`; `Cancel.protect` | exceptions unwind the fiber |
| Koka / Effekt | a handler simply does not resume; `finally` handlers, linear effects | non-resumed one-shot continuation must be finalised |
| Zig `std.Io` | `Future.cancel` request; implementation decides | none |

With a status-return `fallible`, three encodings exist and differ only in where cleanup is
synthesised:

1. **Await returns a cancelled status** (Kotlin/Eio). The resume entry accepts a status; on
   `Cancelled` the frame runs its existing cleanup CFG from the suspension point and propagates.
   Requires every suspension point to have a cleanup edge, i.e. the resume-with-error edge joins
   the cleanup CFG Ferlium already builds for fallible calls. Cheapest; cleanup reused.
2. **Polled flag** (Swift/Go). Library-level only. Weak: a frame parked on a host event is never
   resumed unless the host resumes it.
3. **Drop the frame without resuming** (Rust). Requires per-state drop functions for a
   self-contained frame value. Strongest (host can discard a script coroutine at any time), most
   demanding; Rust's missing `AsyncDrop` shows the residual gap (cleanup that itself suspends).

Because Ferlium frames will be host-owned in the Candli scenario, encoding 3's requirement ("drop of
a handle is always safe") must hold regardless of whether frames are compiler-managed (option A) or
fiber stacks (option B). The pragmatic hybrid is 3 as the safety floor plus 1 as the normal path:
the host may drop, but the polite API is `resume(handle, Cancelled)`. Section 6.2 applies this to
both options.

### 5.5 Exceptions and panics through suspension

C++20 converts exceptions to values at the coroutine boundary; CPS'd programs have no stack to
unwind so errors are values threaded through continuations (Kotlin `resumeWithException`); Rust
panics unwind out of `poll` and executors catch per task; Koka exceptions are an effect; OCaml
`discontinue k exn` injects an exception into a suspended continuation, the same "resume with error"
primitive as Kotlin. For a language with no unwinding the conclusion is clean: panics abort, errors
are statuses, and a suspended frame is resumed with a value or an error status. Exceptions and
cancellation become one mechanism. [V]

### 5.6 Generators and the host boundary

`yield` is the one-shot, synchronous, single-consumer special case of suspension (Python
generators with `throw()`, C# iterator blocks, Kotlin `sequence {}` under `@RestrictsSuspension`,
Rust `gen` blocks still nightly-only). Terminology: a coroutine frame is the storage for a suspended
activation; *stackless* means the frame is not a machine stack, suspension can only happen in the
coroutine's own body (or in callees that are themselves coroutines), and the compiler chooses the
layout; *stackful* means the coroutine owns a real stack so any callee at any depth may suspend. An
effect system lets a stackless design look stackful because the transform applies transitively
along the inferred `suspend` row. [V]

Host-driven scripting precedents [V]:

- **Lua hosts** (Roblox/Luau, Defold): the engine owns the scheduler, stores the `lua_State*` and
  resumes it on the next heartbeat or timer.
- **Godot 4 GDScript**: any function containing `await` becomes a coroutine transparently. The VM
  copies its byte stack into a heap `GDScriptFunctionState` (`stack`, `ip`, `line`, `result`, a
  completion `Signal`), connects to the awaited signal, and `resume(value)` re-enters `call` with the
  saved state. Colorless from the user's view; known costs are zombie states when the owning object
  dies before resumption.
- **Unity**: `IEnumerator` coroutines resumed after `Update`; `StopCoroutine` discards the enumerator.
- **Wasm guest without JSPI**: with a CPS/state-machine transform, a suspending export returns a
  `Suspended` status having left a continuation handle plus a wait reason in a known place; the host
  later calls `resume(handle, value_or_error) -> status` until `Done`. The host is the scheduler
  (Godot/Lua model) or a guest-side run queue is driven by a `tick()` export. Identical for a Rust host
  calling a native Ferlium backend and for a browser host calling Wasm; JSPI can later make a
  host→guest→host round trip look synchronous to legacy host code without changing guest codegen.
  This is Zig's injected `Io` seen from the other side: the host chooses the execution model.

### 5.7 The Hylo model: spawn/await with thread inversion

Detail and citations: [Memo 7](memos/7-hylo-spawn-await.md).

Teodorescu's model (Overload 174, 2023; Overload 181, 2024) is the stackful answer to function
colouring. Its goals include "Concurrent code shall be expressed using the same syntax and semantics
as non-concurrent code", "Function colouring shall not be required", no blocking of threads, bounded
oversubscription, no synchronisation code inside tasks, and (only partially met) no dynamic
allocation. The mechanism [V]:

- **"All functions are coroutines, even if the user doesn't explicitly mark them."** They are
  *stackful*: any function at any depth may suspend, so nothing needs a marker and no caller must
  change.
- **Two primitives.** `spawn f()` enqueues work on a thread pool (or a chosen scheduler);
  `handle.await()` joins it. The future is neither movable nor copyable, so spawn and await sit in
  one scope: one entry, one exit, local reasoning (`escaping_spawn` relaxes this at the cost of a
  heap allocation; `bulk_spawn(n, f)` spawns `n` items).
- **`await` never blocks.** Three cases: the child already finished (continue); the child has not
  been picked up (extract it from the queue and run it inline on the current thread); the child is
  running on a worker. In the third case the awaiting thread captures its own continuation, jumps
  onto the worker's original stack and becomes a pool worker, and when the child finishes the worker
  thread continues the awaiting flow after `await`: "we essentially switch the threads". Hence "a
  function may enter on one thread and exit on a different thread", threads "are not persistent for the duration of a function",
  and thread-local storage is banned (it also breaks the law of exclusivity).
- **Implementation (concore2full).** Boost.Context `make_fcontext`/`jump_fcontext` through a C
  shim; a 1 MiB malloc'd stack per spawned task by default; a per-thread work-line pool; an atomic
  handshake with five states (`initial`, `async_started`, `async_finished`, `main_finishing`,
  `main_finished`; `initial` is what allows inline execution at `await`)
  between the two continuations; `suspend(token)`/`notify()` so I/O and timers can park a flow while
  the thread helps the pool; `sync_execute(f)`/`thread_snapshot` to get back to the original thread
  (a blocking wait) when thread-bound host code calls in; an `inversion_checkpoint()` in the pool
  loop that hands threads back. A C API with an opaque 10-word frame is the compiler-facing surface.
- **Costs and results.** Skynet (10 million leaf tasks) runs without deadlock or large stacks and is
  ~20 % slower than hand-written senders/receivers; Mandelbrot scales near-ideally to 8 cores.
  Costs are paid only at spawn, completion and thread switches.
- **Not there yet.** Cancellation ("we have to add cancellation to the entire model"; the sketch in
  the repository threads explicit hierarchical stop tokens), copyable futures, conditional
  concurrency, I/O and timer integration beyond the example, and exceptions (the coroutine entry is
  `noexcept`; an escaping exception terminates). Hylo's documentation marks the whole design as
  "still under design"; the old Hylo compiler binds the C API in a `Concurrency` stdlib module
  (`Future`, `EscapingFuture`, a 10-pointer `SpawnFrame`, results `Int`-only so far) and the new
  compiler has no concurrency code yet. Hylo has no WebAssembly target, and Boost.Context has no
  WebAssembly or Emscripten backend at all (Emscripten's own fibers require Asyncify and cannot be
  resumed from another thread).

What the model needs from a language is small and Ferlium already has most of it: no aliasing of
mutable state between concurrent tasks (mutable value semantics plus capture-by-value closures give
this statically), no observable thread identity, and an error model in which a suspended function can
be told to fail. What it needs from a target is large: per-coroutine stacks and a context switch,
which native has for free and WebAssembly does not (§5.8).

### 5.8 Design options

Two options are the candidates from issue #18 (A and B); the rest are the alternatives the survey
found, kept for comparison.

| Option | Guest codegen | Wasm today | Native | Cancellation / drop | Host integration | Cost profile |
|---|---|---|---|---|---|---|
| **A. Every function is a coroutine (stackless, compiler-managed frames)** | every function keeps locals that live across calls in an explicit frame on a task stack in linear memory; after every call, check `Suspended` and return with a saved resume index; entry `br_table` on the resume index (Go's wasm backend) or Swift-style direct resume of the innermost frame with return-to-driver | every engine, no proposals | same code; or real fibers with the same host ABI | frame is a value: `resume(handle, Cancelled)` runs the existing fallible cleanup; per-state drop glue for abandonment | host holds an opaque handle; `resume(handle, value_or_status) -> status`; host is the executor | one predictable branch per call plus memory-resident locals; Asyncify measured ~50 % for a generic post-pass, a compiler-integrated scheme should be well below that [inference]; frames on a bump allocator (Swift: 512 B first slab) |
| **B. Hylo model: stackful spawn/await with thread inversion** | none; `spawn`/`await`/`suspend` are runtime calls | **needs stack switching**: core proposal (Phase 3, unshipped), JSPI (JS hosts, Chrome 137+/Firefox 153+/Node 25+, ~1 µs and ~1 MiB per in-flight task, single-threaded), or falls back to A | fibers via a context-switch library; thread pool; thread inversion for multi-threaded hosts | not in concore2full (a repository sketch threads explicit stop tokens); for Ferlium, deliver `Cancelled` at the suspension point and run cleanup by status propagation or by native unwinding (§6.2) | `sync_execute` blocks to return to the caller's thread, or a Lua-style `resume(handle)` driver without inversion | switch cost ~ns; 1 MiB stack per task unless pooled/segmented; ~20 % vs senders/receivers on Skynet |
| C. Asyncify post-pass | none in Ferlium | everywhere | n/a | unwind/rewind only | `asyncify_start_rewind` protocol | ~50 % size and speed, up to 5× worst case |
| D. JSPI / stack switching as the foundation | none | JS hosts only; stack switching unshipped | n/a | engine-defined | JS Promise-shaped | best runtime performance |
| E. Effect-row-specialised CPS (§5.3) | only `suspend`-row instantiations transformed | every engine | same | as A | as A | zero on non-suspending code, but cannot suspend inside pure code and needs a uniform ABI for open-row function values |

---

## 6. Implications for Ferlium

### 6.1 What Ferlium already has, mapped to the survey

| Ferlium today | Equivalent in the survey |
|---|---|
| `fallible` as an inferred effect, lowered to `invoke … error bN` + `propagate_error`, status return `(status, value)` with multi-value on Wasm | Swift `swifterror` on Wasm (padded pointer param + branch), Koka's `is_yielding` check, Rust `Result` |
| Sandbox violations poison the domain and never run guest cleanup; backend may trap | Rust `panic=abort` → `unreachable`; Swift `fatalError` → trap; Wasm traps are uncatchable anyway |
| Mutable value semantics, capture-by-value closures, borrow checker | Hylo's law of exclusivity: the precondition Teodorescu's model needs for race freedom ("no two concurrent tasks access the same memory location" with a writer) |
| Every function has an unconditional `@ret` out-pointer and operands are places; MIR is "independent of the direct/indirect physical ABI" | most of the cost of option A (locals in memory rather than registers) is already the shape of the IR |
| Every CFG cycle crosses `check_fuel`; recursion bounded by `check_call_depth` | with A or B every function can suspend, so a fuel check can become a *yield* rather than only a trap |
| Compiled topology: Rust runtime and generated module are separate Wasm instances sharing one memory; host supplies memory, allocator, native wrappers, abort | the task stack and continuation handles live in the shared memory; the host needs only a `resume` export |
| HIR/MIR reference interpreters carry the pending error explicitly | the interpreters should carry a pending *suspension* the same way (or, in the HIR interpreter, simply use Rust-level fibers) so all execution modes share one semantics |

### 6.2 The two candidates compared

**Semantics first.** Both candidates can share one language-level semantics, and the survey suggests
taking it from Teodorescu's model because it is the more constrained one: colorless functions;
`spawn`/`await` structured in one scope (plus an escaping variant for host callbacks); `await` may run
the child before returning, **but always on the child's own task stack or fiber** (concore2full runs
it on the awaiting stack; Ferlium should not, so that call-depth accounting is per task and the
inline-versus-worker choice is unobservable); no observable thread identity, which must extend to
host natives: a native is either registered as thread-agnostic or thread inversion is disabled for
that host (otherwise code after `await` may run on a pool worker and a thread-bound native such as a
DOM or `!Send` binding breaks); every function may suspend and therefore every function may be
cancelled while suspended. Defining the semantics this way keeps the door open to either
implementation per target.

**Option A on Wasm: every function is a coroutine.** Concretely: locals that live across a call are
stored in an explicit frame on a per-task bump-allocated stack in linear memory (Swift's task
allocator, Go's goroutine stacks in linear memory); every call is followed by a status check that
Ferlium already emits for fallible calls, now for all calls; on `Suspended` the function stores its
resume index and returns the status; resumption either re-enters from the outermost frame with a
`br_table` per function (Go, Asyncify: O(depth) per resume, no tail calls needed) or resumes the
innermost frame directly and returns to a driver loop that continues the parent (Swift's scheme, which relies on `musttail`; without the `tail-call` feature it needs a
trampoline, otherwise the stack grows as §4.7 shows: O(1) per resume). The frame layout is
compiler-known, so unlike Binaryen's Asyncify nothing is copied at suspension beyond the resume
index; the standing cost is memory-resident locals and one predicted branch per call. Ferlium's MIR
already routes results through out-pointers and keeps operands in places, so the delta from today's
lowering is smaller than it would be for a register-oriented language. This design needs no Wasm
proposal, no tail calls, works in Wasmtime and every browser, maps directly onto the WASI 0.3
callback ABI, and transfers unchanged to native.

**Option B natively: fibers.** On native the same semantics can use real stacks: a context-switch
primitive (Boost.Context-style assembly; a Rust crate such as `corosensei` [PK]) and a pooled stack
allocator instead of concore2full's 1 MiB malloc per task. Thread inversion is worth adding only
for multi-threaded hosts; for a single-threaded embedder the same API is plain fibers with a
Lua-style `resume(handle)` driver. Panics must be caught at the fiber boundary and converted to the
poison path, because unwinding across a context switch is not supported by libunwind [PK].

**Option B on Wasm.** Not implementable without an engine feature: the core stack-switching
proposal is the exact primitive but is Phase 3 with no shipping engine (2027–2028 at the earliest
[inference]); JSPI can host a JS-side scheduler (each `promising` call gets an engine stack, `await`
is a `Suspending` import whose promise the child resolves) but only on JS hosts, single-threaded,
with about 1 µs and ~1 MiB per in-flight task and Safari still in beta; Asyncify is option A done
worse. So on Wasm, B is A. The practical plan is therefore **one semantics, two runtimes**: A on Wasm
(and optionally native), fibers on native where stacks are cheap.

**Host boundary.** The host-facing ABI should be the same for both runtimes:
`call(f, args) -> status` and `resume(handle, Ok(v) | Err(status)) -> status`, with the host owning
liveness (the Godot/Lua/Unity model, also what JavaScriptKit does for Swift and what the WASI 0.3
callback lift expects). Thread inversion's blocking `sync_execute` wrapper is exactly the interop
penalty Teodorescu flags; a host-driven `resume` avoids it. If the Rust host is itself multi-threaded
and wants inversion, that is a runtime option, not an ABI change.

**Exceptions and panics.** Unchanged by either option: errors are statuses, panics are traps or
poison. In A the status propagates through frames as today; in B the fiber entry converts a
status into the future's result and traps never cross the switch. Wasm EH remains useful only to
catch JS exceptions from imports (`JSTag`) and turn them into `Err`.

**Cancellation.** Ferlium has no catch construct: source failures propagate to the host after
cleanup. Cancellation should therefore be a **fourth runtime outcome**, next to source failure,
sandbox violation and failure-during-cleanup: like a sandbox violation it is not a source effect
and cannot be observed or handled by Ferlium code, so effect rows stay as they are (every function
being suspendable does *not* make every function `fallible`); unlike a sandbox violation it runs
semantic cleanup. Delivery is uniform across the options: the suspended computation is resumed with
`Cancelled` at its suspension point and cleanup runs through the same cleanup blocks the fallible
lowering builds. What differs is how the outcome travels up the frames. Under A every call site
already has a status check and a cleanup edge (that is what "every function is a coroutine" costs),
so `Cancelled` propagates like a status. Under B on native there are two choices: the same status
checks in every frame (then B's "per call: none" holds only for the happy path), or native
unwinding of the fiber's real stack (Cranelift `try_call`, memo 1), which costs nothing per call and
runs the same cleanup blocks as landing pads. Structured `spawn`/`await` gives the propagation tree
for free: cancelling a scope cancels its children, and `await` still joins them (Swift's rule:
cancelled children are awaited, never leaked). Abandoning a handle *without* resuming can only run
cleanup by executing guest code in both options (drop glue is compiled guest code too, but
`Value::drop` is infallible by contract, so it is bounded); if the computation cannot be resumed at
all, for example because it is parked inside a host native, the fallback is the existing poison
path: memory-safe reclamation, no guest cleanup. concore2full's own sketch (explicit stop tokens
checked in loops) shows the alternative that needs no runtime support at all.

**Preemption.** Because every function can suspend under A or B, a fuel check can yield to the host
instead of poisoning, which is what a game engine time-slicing scripts wants. This is the main
behavioural difference from effect-row-specialised CPS, which cannot suspend inside pure code.

**Cost summary.**

| | A on Wasm | B on native (fibers) |
|---|---|---|
| Per call | one status branch; locals in memory | none on the happy path; cancellation via unwinding (no per-call cost) or via status checks (one branch per call) |
| Per spawn | frame allocation on the task stack | stack allocation (pooled) + enqueue |
| Per suspend/resume | store index, return; re-entry O(depth) or O(1) with a driver | context switch, ~ns |
| Memory per task | frames only (hundreds of bytes upward) | a full stack (concore2full: 1 MiB default) |
| Engine/OS needs | none | context-switch assembly per platform |
| Multi-threading | host workers with separate instances; no shared suspended frames | thread pool with inversion |

### 6.3 Recommended staging

1. **Fix the semantics** as structured `spawn`/`await` with colorless functions, one-shot
   continuations, unspecified sibling order, inline execution allowed at `await` but always on the
   child's own task stack, no observable thread identity (including for natives), cancellation as a
   non-source outcome delivered at suspension points that runs cleanup, per-task call-depth budgets,
   and a host-driven `resume` ABI. Write it down before choosing runtimes; it is
   what makes A and B interchangeable.
2. **Prototype option A in the MIR → Wasm lowering**: explicit task-stack frames, resume index,
   status check after every call, `br_table` re-entry first (no tail calls, simplest), direct resume
   later if profiles demand it. Measure against today's lowering on the benchmark suite; the
   Asyncify 50 % figure is the number to beat by a wide margin.
3. **Reuse the same frames in the HIR interpreter** or use Rust fibers there; either way keep the
   pending-suspension status explicit so both reference interpreters stay comparable.
4. **Native later**: fibers with pooled stacks behind the same host ABI; add thread inversion only if
   a multi-threaded Rust host needs it.
5. **Keep JSPI and stack switching as optional accelerators** (a JSPI shim for legacy synchronous
   JS callers; core stack switching if and when it ships), never as the foundation.
6. **Do not add Wasm EH for control flow**; use it only to convert JS exceptions from imports.

### 6.4 Open questions this research cannot settle

- **Frame sizes and recursion under A.** Compiler-managed frames need a size per function
  instantiation; deep recursion or large aggregates in frames stress the task stack. Swift's answer
  is a runtime `(function, context size)` pair and slab growth; Zig 0.9's failure to solve frame
  sizes for indirect calls is the cautionary tale. Ferlium's monomorphisation and absence of
  dynamic dispatch make this easier than in either.
- **Native callbacks.** Host natives that call back into Ferlium (higher-order natives) cannot be
  suspended across unless the native side is re-enterable (option A) or runs on the fiber (option B).
  Which natives may receive suspending closures, and which natives are thread-agnostic enough to be
  called after an `await` under thread inversion, are registration-time policies either way.
- **Threads on Wasm.** Suspended frames in shared memory could in principle be resumed by another
  worker under A; under the stack-switching proposal continuations are not shareable. Whether
  Candli needs cross-worker task migration at all decides how much of the inversion machinery is
  worth porting.
- **Escaping spawns.** Host callbacks and event handlers are the `escaping_spawn` case; they need
  heap-allocated futures and a rule for who awaits them.

### 6.5 Measured: what option A costs in Swift

Full method, raw numbers, environment and caveats: [bench/RESULTS.md](../bench/RESULTS.md); sources
and scripts in `bench/`, all of it re-runnable.

Ten programs were written once in async form (every function `async`, every call site `await`) and
every other variant generated from the same file by deleting or adding tokens, so no variant differs
from another in anything but the calling convention. All variants of each program print identical
checksums. Swift 6.5-dev, `-O -wmo`, one core of an i9-12900H, min of 7 runs. `NI` marks variants
with `@inline(never)` on every function, modelling calls the optimizer cannot inline.

| program | async / sync | async / sync, NI | wasm32 in Chrome | shape |
|---|---:|---:|---:|---|
| matmul | 1.02x | 1.07x | 1.14x | arithmetic over arrays, almost no calls |
| nbody | 0.99x | 1.38x | 1.18x | numeric kernel, one call per step |
| collision | 1.02x | 4.63x | 0.95x | grid broadphase, small predicates per pair |
| sort | 1.17x | 6.01x | 2.57x | quicksort with a comparison function |
| ecs | 1.16x | 14.00x | 0.99x | 100k entities, one call per component per tick |
| astar | 1.43x | 3.74x | 43.18x | grid pathfinding with a binary heap |
| binarytrees | 2.65x | 2.68x | 69.99x | allocation-heavy recursion |
| particles | 3.67x | 13.09x | 1.34x | 200k particles, six vector helpers each |
| parser | 4.19x | 13.33x | 110.68x | recursive-descent parsing, character-level helpers |
| fib | 20.58x | 19.76x | **traps** | a function that only calls itself |

Unit costs on x86-64: a non-inlinable sync call is 0.84 ns, the same call made async is 18.36 ns, so
**async adds 17.5 ns per call**; an async call the optimizer can inline costs what a sync call costs
(0.10 ns); a real suspension and resume through the executor costs 342 ns. The whole-program numbers
agree: 19.1 ns per call in `particles`, 29.5 ns in `ecs` (whose helpers take `inout` arguments). Text
sections grew 23-101%, peak RSS by 0.35-0.6 MB regardless of workload.

Four conclusions bear on the choice between options A and B.

**The penalty tracks calls per unit of work, not "asyncness".** Loop-heavy numeric and
data-structure code pays nothing once inlining is allowed. Code that calls a small function per
element pays 1.2-4.2x. A function with no body but a call pays 21x, because there is nothing to
amortise 17.5 ns against. For a scripting language whose users write per-entity update functions,
the middle row is the one that matters.

**Inlining decides the outcome, and it matters more than the calling convention.** Where the
optimizer inlines, the frame and the suspension point disappear together and the cost is zero;
`particles` is 12.6x slower in the *synchronous* variant when inlining is forbidden. Ferlium
monomorphises, has no dynamic dispatch and compiles a whole session as one module, so it sits on the
favourable side of this line by construction, provided the coroutine transformation runs late enough
not to block inlining.

**On WebAssembly the same design is a different proposition.** Built for `wasm32-unknown-wasip1`
with Swift 6.3.3 and run in headless Chrome 151 through a minimal WASI shim, the programs whose
awaits inline away are still free, but a non-inlinable async call costs **556 ns**, thirty times its
native cost, and recursive programs land between 43x and 111x. Naive recursive `fib` does not run at
all: it dies with `Maximum call stack size exceeded`, in Chrome and in Wasmtime alike, and the trap
backtrace alternates each function's ramp and resume partial functions, the shape you get when a
coroutine returns by *calling* its continuation instead of tail-calling it. The cause is the absence
of guaranteed tail calls: Swift's async lowering wants `musttail` at every suspension and resume,
`-mtail-call` is off by default, and enabling it in Swift 6.3.3 produced a module Wasmtime rejects as
malformed. This is direct evidence for §6.2's recommendation: a Wasm lowering must make a suspending
call an ordinary call and resumption a re-entry from a driver loop, which needs no tail calls at all.
Porting a CPS-style async ABI to Wasm unchanged does not work.

**The await point is where the money goes, and the cost model is brittle.** The first run of this
suite left the workload in Swift's MainActor-isolated `main`, and `nbody` came out 49x slower, with
the hot loop ending in `jmp swift_task_switch` and each iteration costing 2.2 µs instead of 20 ns.
The condition turned out to be narrow and worth knowing: it appears only when the async callee is
*inlined into* the actor-isolated caller, which turns the callee's suspension points into
suspensions of the enclosing isolated task so that each resume takes a full executor round trip.
Blocking that one inlining decision restores 1.00x, as does moving the workload off-actor. Two
lessons: a resume that is a plain call into a host-driven loop, as §6.2 proposes, never enters this
regime; and a design whose cost depends this sharply on one inlining decision is hard for a
programmer to reason about.

Two things bound how far these numbers transfer. Swift's async is an upper bound for a new language:
its frames are dynamically sized and reached through async function pointers to keep async
signatures ABI-stable and resilient, they come from a per-task slab allocator, and the default
executor is a thread pool. Ferlium needs none of that and can use statically sized frames. In the
other direction, the transformation left initialisers, property accessors and all standard-library
calls synchronous, so a language where genuinely everything suspends would pay more.

**Verdict for Ferlium.** Not prohibitive natively, and a clear constraint on the Wasm lowering. For a
high-level scripting language in a game engine, "every function is a coroutine" costs roughly
1.0-1.5x on loop-shaped work and up to ~4x on call-dense work under a compiler that can inline, with
a floor of about 17.5 ns per call wherever inlining fails. At 60 Hz that floor buys roughly a million
non-inlined async calls per frame before the frame budget is gone. The design work that pays for
itself is not avoiding the transformation but making the await point trivial, letting the inliner see
through small leaf functions, and — on Wasm — never depending on tail calls.

## 7. Verification notes and disagreements between sources

- **JSPI in Firefox.** The V8 blog says "Firefox 139"; MDN release notes and Bugzilla (bug 2044809)
  say enabled by default in **Firefox 153 (2026-07-21)** with earlier versions behind a pref. This
  document uses 153.
- **Safari and JSPI.** Announced for Safari 27 beta (WWDC26); stable Safari ≤ 26.6 unsupported per
  Can I Use at the time of research.
- **WASI 0.3 date.** Verified 2026-06-11 from wasi.dev; a claim that it "shipped February 2026 in
  Wasmtime 37" comes from low-quality aggregators and is wrong.
- **exnref in Chrome.** 137 per the web-features explorer; one Cloudflare post says 138.
- **Node exnref.** 24.15 per the feature table and wasm-bindgen; Node's own notes do not mention it.
- **Swift shipped-stdlib tail calls.** Evidence (build scripts, open issue 5568) says released SDKs
  are built without tail calls; not confirmed by a direct statement.
- **Swift `AsyncContext` layout.** Current `main` has only `Parent` and `ResumeParent`; the
  commonly cited `Flags` word is stale.
- **Swift executor proposal numbers.** "Custom Main and Global Executors" is still a pitch (no SE
  number); SE-0472 is `Task.immediate`; SE-0505 is delayed enqueuing.
- **Native throw cost "1–2 µs per frame"** could not be verified; sources give ~1 µs per shallow
  throw plus a linear per-frame component.
- **Midori's codegen**, Flix's handler compilation, Bun/Deno JSPI, V8 growable JSPI stacks, and
  WAMR's exnref status could not be verified.
- **Boost.Context on WebAssembly**: verified absent. Boost's architecture table and build file know
  only `fcontext` (assembly for arm, aarch64, i386, x86_64, loongarch64, mips, ppc, riscv64, s390x,
  sparc64), `ucontext` and `winfib`; nothing in concore2full or context-core-api mentions
  WebAssembly. Emscripten's fiber API requires Asyncify and is thread-bound.
- **Hylo integration**: the old Hylo compiler (head 2026-07-13) ships a `Concurrency` stdlib module
  bound to concore2full's C API; the new compiler (head 2026-09-04) has none yet.
- **Node.js 24.15** release notes (2026-04-15) do not mention exnref; the only Wasm change is JS
  string-constant ESM imports. The 24.15 date for exnref therefore rests on the feature table and
  wasm-bindgen alone.
- **Memo 1 versus this synthesis.** Memo 1 recommends panics as table-based unwinding by default and
  async as poll-style state machines; §1.6 and §6 explain why this document departs from both.
- **LLVM version for the exnref switch.** Memo 2 cites the LLVM 21 release notes for the
  `-wasm-use-legacy-eh` flag; memo 5 says the flag (PR 122158, merged January 2025) is in LLVM 20.
  The PR predates the LLVM 20 branch date, so LLVM 20 is likely, but the release-notes entry is in 21.
- **wasm_of_ocaml modes.** Memo 3 lists `jspi`, `cps`, `native`; memo 6 lists `jspi`, `cps`,
  `double-translation`. All four exist; this document lists all four.
- **JSPI stack size.** The ~1 MB per in-flight call figure is V8's June 2024 statement; whether
  growable stacks have since shipped is unverified, so the figure may be stale.
- **Swift runtime C++ exceptions flag**: `-fno-exceptions` was not found in the five CMake files
  checked (`AddSwift.cmake`, `AddSwiftStdlib.cmake`, `SwiftSharedCMakeConfig.cmake`,
  `stdlib/CMakeLists.txt`, `stdlib/public/runtime/CMakeLists.txt`); the claim that the runtime is
  built without exceptions stays [PK].
- **JVM exception tables**: verified from JVMS §4.7.3 (`start_pc`, `end_pc` exclusive, `handler_pc`,
  `catch_type`).

## 8. Primary sources (selection; full lists in each memo)

- Itanium C++ ABI EH: https://itanium-cxx-abi.github.io/cxx-abi/abi-eh.html · LLVM EH: https://llvm.org/docs/ExceptionHandling.html · MaskRay on unwinding: https://maskray.me/blog/2020-11-08-stack-unwinding · P2544R0: https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2022/p2544r0.html · Rust RFC 2945: https://rust-lang.github.io/rfcs/2945-c-unwind-abi.html · Cranelift exceptions: https://cfallin.org/blog/2025/11/06/exceptions/
- Wasm 3.0: https://webassembly.org/news/2025-09-17-wasm-3.0/ · EH explainer: https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md · feature table: https://webassembly.org/features/ · proposals: https://github.com/WebAssembly/proposals · Wasmtime exceptions: https://bytecodealliance.org/articles/wasmtime-exceptions · wasm-encoder: https://docs.rs/wasm-encoder
- JSPI: https://github.com/WebAssembly/js-promise-integration/blob/main/proposals/js-promise-integration/Overview.md · https://v8.dev/blog/jspi · Firefox 153: https://developer.mozilla.org/en-US/docs/Mozilla/Firefox/Releases/153 · Safari 27: https://webkit.org/blog/17967/news-from-wwdc26-webkit-in-safari-27-beta/ · Node 25: https://nodejs.org/en/blog/release/v25.0.0 · Stack switching: https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Explainer.md · Asyncify: https://kripken.github.io/blog/wasm/2019/07/16/asyncify.html · WASI 0.3: https://wasi.dev/releases/wasi-p3 · Component async: https://github.com/WebAssembly/component-model/blob/main/design/mvp/Concurrency.md
- Swift: https://github.com/swiftlang/swift/blob/main/docs/ABI/CallingConventionSummary.rst · https://llvm.org/docs/Coroutines.html · SE-0296/0300/0304/0311/0392/0413/0417 at https://github.com/swiftlang/swift-evolution · runtime sources under `stdlib/public/Concurrency/` · WWDC21 "Swift concurrency: Behind the scenes" · swifttailcc on Wasm: https://github.com/llvm/llvm-project/pull/188296, https://github.com/llvm/llvm-project/pull/203330, https://github.com/swiftwasm/swift/issues/5614 · JavaScriptKit event loop: https://github.com/swiftwasm/JavaScriptKit/blob/main/Sources/JavaScriptEventLoop/JavaScriptEventLoop.swift
- Hylo model: https://accu.org/journals/overload/30/168/teodorescu/ · https://accu.org/journals/overload/31/174/teodorescu/ · https://accu.org/journals/overload/32/181/teodorescu/ · https://github.com/hylo-lang/concore2full · https://github.com/lucteo/context-core-api · https://docs.hylo-lang.org/language-tour/concurrency
- Colorless/effects: https://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/ · Xie & Leijen ICFP 2021: https://dl.acm.org/doi/10.1145/3473576 · Kotlin KEEP: https://github.com/Kotlin/KEEP/blob/master/proposals/coroutines.md · Zig new async: https://andrewkelley.me/post/zig-new-async-io-text-version.html, https://github.com/ziglang/zig/issues/23446 · wasm_of_ocaml effects: https://ocsigen.org/js_of_ocaml/6.0.1/manual/effects · Godot coroutines: https://github.com/godotengine/godot/blob/master/modules/gdscript/gdscript_function.h · Rust async design: https://without.boats/blog/why-async-rust/
