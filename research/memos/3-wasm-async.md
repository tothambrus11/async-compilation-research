# Research Memo: Asynchrony, Coroutines and Stack Switching in WebAssembly (status as of 2026-09-04)

**Audience:** Ferlium implementers (Rust interpreter with effect inference; planned WASM backend via `wasm-encoder`; possible native backends).
**Conventions:** Claims marked **[V]** were verified against the cited source during this research pass. Claims marked **[PK]** are prior knowledge with a citation but not re-verified today. Claims marked **[UNVERIFIED]** could not be confirmed.

---

## 1. Why WASM needs special mechanisms, and the three families

A core WebAssembly instance has exactly one implicit execution stack, which is not addressable from wasm code; control flow is structured (`block`/`loop`/`if`/`br`, plus EH `try_table`/`throw`), there are no first-class continuations, and every call into a host import is synchronous: the import must return before the wasm frame continues. A JS host, in particular, cannot "block" a wasm frame waiting on a Promise because the event loop cannot advance while the wasm frame is on the JS stack. The JSPI overview describes the resulting problem as "WebAssembly applications that were written assuming synchronous access to external functionality" needing to run "in an environment where the functionality is actually asynchronous" **[V]** (https://github.com/WebAssembly/js-promise-integration/blob/main/proposals/js-promise-integration/Overview.md).

Three families of solutions exist:

### (a) Binary-level transformation: Binaryen Asyncify
Asyncify is a `wasm-opt` pass (`wasm-opt in.wasm -O1 --asyncify`) that instruments the module so it can *unwind* the live wasm call stack into linear memory and later *rewind* it. Per Alon Zakai's design post **[V]** (https://kripken.github.io/blog/wasm/2019/07/16/asyncify.html):
- A small data structure in linear memory holds `[start, end)` of an "asyncify stack" region (analogous to a `jmp_buf`); overflow executes `unreachable`.
- A global state (normal / unwinding / rewinding) is checked around every potentially-unwinding call; on unwind each instrumented function saves its locals and returns; on rewind each function re-enters, skips already-executed code, restores locals and re-executes the call.
- It does whole-program call-graph analysis; only functions that can transitively reach an unwinding import are instrumented. `--pass-arg=asyncify-imports=...` restricts which imports may unwind; `--pass-arg=asyncify-ignore-indirect` assumes indirect calls never unwind.
- Overhead: "typical code size increases of 1-2x", approaching zero with good configuration.

Emscripten wraps this as `-sASYNCIFY` with `ASYNCIFY_IMPORTS`, `ASYNCIFY_ONLY`, `ASYNCIFY_ADD`, `ASYNCIFY_REMOVE`, `ASYNCIFY_IGNORE_INDIRECT`, `ASYNCIFY_STACK_SIZE`, `ASYNCIFY_ADVISE`; it documents roughly "50% or so" overhead in both size and speed, insists on `-O3`, and warns "It is *not* safe to start an async operation while another is already running" (no reentrancy) **[V]** (https://emscripten.org/docs/porting/asyncify.html). WordPress Playground's PHP port illustrates the practical pain: a curated `ASYNCIFY_ONLY` list is needed because auto-detection would instrument ~70,000 functions and push startup to 4.5 s, and omitting one function from the list crashes at runtime; they maintain a `fix-asyncify` test loop to repair the list **[V]** (https://wordpress.github.io/wordpress-playground/developers/architecture/wasm-asyncify/). Because Asyncify is a post-pass on any `.wasm`, it is used well beyond C/C++: TinyGo's default wasm scheduler is `-scheduler=asyncify`, "based off of Binaryen's Asyncify Pass" **[V]** (https://tinygo.org/docs/reference/usage/important-options/), and the `asyncify` JS wrapper pattern from GoogleChromeLabs is generic **[V]** (https://web.dev/articles/asyncify). wasmtime-py: I could not verify any Asyncify-specific support in wasmtime-py **[UNVERIFIED]**; Asyncify usage with Python hosts appears to be ad hoc (the host just implements the unwind/rewind protocol against the exported `asyncify_*` functions).

### (b) Language-level CPS / state-machine transformation
Nothing in wasm is required: the compiler rewrites each `async`/`suspend` function so that its live state is heap-allocated and the function is re-enterable. Verified examples:
- **LLVM coroutine lowerings** **[V]** (https://llvm.org/docs/Coroutines.html): *switched-resume* (C++20: ramp/resume/destroy functions, suspend index stored in the frame, resume switches on it); *returned-continuation* (Swift `yield`-style: each suspend returns the next continuation pointer); *async lowering* (Swift `async`: ramp + one resume function per suspend point, frame stored as a tail of the async context passed as an argument).
- **Kotlin**: every `suspend fun` gets an extra `Continuation` parameter and returns `Any?` (either `COROUTINE_SUSPENDED` or the value); the body is a state machine with a `label` field and `resumeWith()`; "the actual implementation of the suspending function is not allowed to invoke the continuation in its stack frame directly" **[V]** (https://github.com/Kotlin/KEEP/blob/master/proposals/coroutines.md).
- **Dart (dart2wasm)**: async functions become a wrapper that allocates an `_AsyncSuspendState` (target index, context, exception, stack trace, return value) and an inner state-machine function that resumes via `br_table` **[V]** (https://raw.githubusercontent.com/dart-lang/sdk/main/pkg/dart2wasm/lib/async.dart).
- **Rust** `async fn` → generator state machine polled by an executor (**[PK]**, standard).
- **Go's gc compiler** does something in between: it keeps goroutine stacks in linear memory and makes every function resumable through a `PC_B` "resume point" register and a `BrTable` at function entry; calls become `ARESUMEPOINT`s, and the backend "attempt[s] to unwind WebAssembly stack" to switch goroutines **[V]** (https://raw.githubusercontent.com/golang/go/master/src/cmd/internal/obj/wasm/wasmobj.go; design doc https://docs.google.com/document/d/131vjr4DH6JFnb-blm_uRdaC0_Nv3OUwjEY5qVCxCup4 **[PK]**, could not be fetched today). This is effectively a compiler-integrated Asyncify.

All of these run on a host event loop (browser microtask/macrotask queue, or a guest-side executor loop).

### (c) Engine-level stack switching
Two proposals: **JSPI** (JS-API only, ties suspension to Promises) and **core stack switching / typed continuations (WasmFX)** (first-class `cont` values in core wasm). The Stack Switching explainer notes the primary use case is "modular compilation of advanced non-local control flow idioms, such as coroutines, async/await, generators, lightweight threads" **[V]** (https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Explainer.md). The historical "typed continuations vs fibers" split: the two competing designs (WasmFX's effect-handler-style `suspend`/`resume`, and the more symmetric "fibers"/`switch` design from Francis McCabe) were merged into a single proposal in 2024 that has both asymmetric `suspend`/`resume` and symmetric `switch` **[V]** for the merged instruction set (Explainer), **[PK]** for the history (https://effect-handlers.org/talks/stack-switching-wasmcg-feb2025.pdf).

---

## 2. JSPI (JavaScript Promise Integration): details and status

### API and semantics **[V]** (Overview.md above; https://v8.dev/blog/jspi; https://v8.dev/blog/jspi-newapi)
- `new WebAssembly.Suspending(jsFn)` wraps an *import*. When wasm calls it and it returns a Promise, the wasm computation is suspended; the resolved value becomes the import's return value. If it returns a non-Promise, no suspension occurs ("suspends only when functions actually return Promises").
- `WebAssembly.promising(wasmExport)` wraps an *export*: calling it returns a Promise that settles when the wasm computation completes, "even if multiple suspensions occur internally".
- The current API (V8 ≥ M126, June 2024) replaced the older explicit `Suspender`-object API and no longer needs Type Reflection.

### How the engine implements it **[V]**
V8 runs each `promising` call on a separately allocated stack; on suspension the engine detaches that stack and attaches a callback to the Promise that will re-attach it later. Cost: "approximately 1μs" per suspended call in the V8 fib demo (https://v8.dev/blog/jspi). Stacks were "rather large" fixed-size (~1 MB each) as of June 2024; V8 was investigating segmented "growable stacks" for coroutine stacks (main stack stays non-growable) (https://v8.dev/blog/jspi-newapi). I could not verify whether growable stacks have shipped by 2026 **[UNVERIFIED]**.

### Rules and limitations **[V]**
- Suspension is only legal when *only wasm frames* lie between the `promising` entry and the `Suspending` import; if a JS frame is in between, the engine traps. The observable error in V8 is `SuspendError` ("trying to suspend without WebAssembly.promising") (https://github.com/emscripten-core/emscripten/issues/24302). Safari's implementation exposes `WebAssembly.SuspendError` too (https://webkit.org/blog/17967/news-from-wwdc26-webkit-in-safari-27-beta/).
- "it is *not* permitted to cause JavaScript code to be suspended by using JSPI" (V8 blog).
- Reentrancy: multiple `promising` calls may be in flight and interleave; the proposal provides no ordering guarantees, so guest state (e.g., the C shadow stack pointer in linear memory) must be re-entrant. Pyodide had to add machinery to "keep the linear memory stack in sync" with the native stack switch (https://blog.pyodide.org/posts/jspi-with-c-runtime/ — page fetch blocked today; summary from search snippet **[PK]**).
- Promise rejection: the rejection reason is "thrown ... as an exception according to the JS API of the Exception Handling proposal", i.e., it lands in wasm as a catchable exception (`try_table`/`catch_all_ref` sees a JS-tagged exnref) (Overview.md).

### Shipping status **[V]**
| Runtime | Status |
|---|---|
| Standard | Phase 5 (standardized) in the WebAssembly CG proposals list (https://github.com/WebAssembly/proposals); finished April 2025 (Pyodide blog snippet gives 2025-04-08 **[PK]**). |
| Chrome / Edge | Shipped in **Chrome 137, 2025-05-27** (https://developer.chrome.com/blog/new-in-chrome-137; Can I Use lists Chrome/Edge 137+, https://caniuse.com/wf-wasm-jspi). Origin trial ran Chrome 123–128. |
| Firefox | Enabled by default in **Firefox 153 (2026-07-21)**; MDN release notes and Bugzilla 2044809 (target milestone 153; previously Nightly-only via bug 2015877) (https://developer.mozilla.org/en-US/docs/Mozilla/Firefox/Releases/153; https://bugzilla.mozilla.org/show_bug.cgi?id=2044809). Note: the V8 blog says "Firefox 139" — that was behind the `javascript.options.wasm_js_promise_integration` pref (Pyodide docs snippet); Can I Use confirms 153+. |
| Safari | **Safari 27 beta (announced 2026-06-08, WWDC26) adds JSPI** (https://webkit.org/blog/17967/news-from-wwdc26-webkit-in-safari-27-beta/). Can I Use still lists stable Safari/iOS Safari ≤ 26.6 as unsupported. WebKit initially objected, removed its objection late 2025 (https://platform.uno/blog/the-state-of-webassembly-2025-2026/; position issue https://github.com/WebKit/standards-positions/issues/422). |
| Node.js | **Enabled by default in Node 25.0.0 (2025-10-15)**, V8 14.1, PR #59941 (https://nodejs.org/en/blog/release/v25.0.0). Node 22/24 need `--experimental-wasm-jspi` (https://scala-cli.virtuslab.org/docs/guides/advanced/scala-wasm/; Pyodide docs). |
| Deno | V8-based; JSPI availability tracks the embedded V8 (Chrome 137 ≈ V8 13.7). No Deno-specific release note found **[UNVERIFIED]**. |
| Bun | JavaScriptCore-based; JSPI arrives only with WebKit's implementation. Nothing found for Bun **[UNVERIFIED]**. |

### Emscripten **[V]**
`-sJSPI` (originally `-sASYNCIFY=2`) enables JSPI with "no code size increase"; async boundaries must be declared explicitly via `JSPI_IMPORTS`/`JSPI_EXPORTS` (Asyncify infers them from `ASYNCIFY_IMPORTS`). Requires Emscripten ≥ 3.1.61 (V8 blog). With JSPI, Embind exports marked `emscripten::async()` always return a Promise, whereas under Asyncify a Promise is returned only if a suspension actually happened (https://emscripten.org/docs/porting/asyncify.html; settings reference https://emscripten.org/docs/tools_reference/settings_reference.html).

### Performance versus Asyncify
- V8: ~1 µs per suspension; JSPI has no instrumentation, so the non-suspending fast path is unaffected (https://v8.dev/blog/jspi).
- Emscripten: Asyncify costs "50% or so" size and speed; JSPI "should be faster" and "significantly smaller Wasm output" (https://emscripten.org/docs/porting/asyncify.html; https://groups.google.com/g/emscripten-discuss/c/EGZjZ9DO6T0).
- Binaryen: 1–2x code size for Asyncify (Zakai post). I did not find a V8 blog post with head-to-head benchmark tables beyond the 1 µs figure **[UNVERIFIED that such numbers exist]**.

---

## 3. Core stack switching (typed continuations / WasmFX)

### Status **[V]**
- **Phase 3 (Implementation Phase)** in the CG proposals list, champions Francis McCabe and Sam Lindley (https://github.com/WebAssembly/proposals). It reached Phase 2 in August 2024 (WasmFX site, https://wasmfx.dev/) and Phase 3 during 2025 (secondary source: https://platform.uno/blog/the-state-of-webassembly-2025-2026/; the exact vote date was not verified **[UNVERIFIED]**).
- **V8**: implemented behind `--experimental-wasm-wasmfx` (flag `stack_switching`, experimental section, owners thibaudm/fgm) (https://raw.githubusercontent.com/v8/v8/master/src/wasm/wasm-feature-flags.h). wasm_of_ocaml's README says its `--effects=native` mode needs "Chrome 148+ or Node.js canary with V8 14.7.100+" with that flag (https://github.com/ocsigen/js_of_ocaml/blob/master/README_wasm_of_ocaml.md). Not shipped, not staged.
- **Wasmtime**: `Config::wasm_stack_switching`, disabled by default, "experimental", x86_64 Linux only, no Winch/Pulley/Windows; `resume_throw`, continuation deallocation and GC integration were still missing on the tracking issue; v48.0.0 (2026-08-20) notes "work continues on stack-switching" (https://github.com/bytecodealliance/wasmtime/issues/10248; https://docs.wasmtime.dev/stability-wasm-proposals.html; https://github.com/bytecodealliance/wasmtime/releases). Upstreaming from the `wasmfxtime` fork (https://github.com/wasmfx/wasmfxtime).
- **SpiderMonkey**: no evidence of a WasmFX implementation was found **[UNVERIFIED]**. Firefox's JSPI implementation is stack-switching based internally (Bugzilla mentions a regression on "unbounded stack-switching recursion").
- Reference interpreter, Wizard, Binaryen and wasm-tools support exist (https://wasmfx.dev/ via search snippet **[PK]**). `wasm-encoder`/`wasmparser` therefore already know the encoding — relevant to Ferlium.
- Formal work: WasmFXCert (Rocq soundness) and Iris-WasmFX (https://dl.acm.org/doi/10.1145/3808271).

### Instruction set **[V]** (Explainer.md)
- Type: `(cont $ft)` referencing a function type; heap types `cont`/`nocont`.
- `cont.new $ct`: create a continuation from a typed `funcref`.
- `cont.bind $ct $ct'`: partially apply a prefix of arguments.
- `resume $ct (on $tag $label)* (on $tag switch)*`: run a continuation with a handler clause per control tag; on `suspend $tag` inside it, control returns to the matching `on` label with the tag's payload plus the remaining continuation (asymmetric, effect-handler style).
- `suspend $tag`: capture the current stack up to the nearest handler for `$tag`.
- `switch $ct $tag`: symmetric, direct switch to a peer continuation.
- `resume_throw $ct $exntag` / `resume_throw_ref`: resume by *throwing* into the continuation — this is how a suspended coroutine is aborted/unwound and how EH composes with continuations.
- Tags are generalized to carry result types (resumable exceptions); continuations are one-shot.

Timeline: no engine has shipped; Phase 4 requires two web VMs. Given V8 is experimental-only in Sept 2026 and Firefox has no public implementation, shipping in 2026 is implausible; 2027–2028 at the earliest is a reasonable guess **[inference]**.

### The other concurrency axis: threads
- **Threads proposal** (shared memory + atomics + `memory.atomic.wait/notify`) is Phase 4/standardized; it provides no thread spawning — hosts spawn Workers (web) or use wasi-threads (https://github.com/WebAssembly/proposals; Wasmtime `wasm_threads` docs note it "does not actually include the ability to spawn threads", https://docs.rs/wasmtime/latest/wasmtime/struct.Config.html).
- **wasi-threads** (`wasm32-wasip1-threads` in Rust) is a "legacy proposal" retained for preview1; Wasmtime removed `-Sthreads` in 47.0.0 (https://github.com/WebAssembly/wasi-threads; https://doc.rust-lang.org/beta/rustc/platform-support/wasm32-wasip1-threads.html).
- **shared-everything-threads** (shared GC objects/tables/globals, `thread.spawn`-style builtins, TLS) is **Phase 1** in the proposals list; Wasmtime has an off-by-default `wasm_shared_everything_threads` option (https://github.com/WebAssembly/shared-everything-threads; https://chromestatus.com/feature/5163209685467136).
- Wasm has **no native green threads**; the only in-engine mechanisms are JSPI (Promise-tied) and the unshipped stack-switching proposal. Everything else is a compiler transformation.

---

## 4. WASI and the Component Model async story

### WASI 0.2 (preview 2): polling **[V]/[PK]**
`wasi:io/poll` exposes `pollable` resources; `wasi:io/streams` input/output streams offer `subscribe()` returning a pollable, and `poll(list<pollable>)` blocks the guest until one is ready. Guests build event loops in-guest: the `wstd` crate ("an async standard library for Wasm Components and WASI 0.2") provides `block_on` and `AsyncPollable` wrapping `subscribe()` (https://github.com/bytecodealliance/wstd; design rationale https://blog.yoshuawuyts.com/building-an-async-runtime-for-wasi/). The problem: each component has its own loop with no way to coordinate across components (https://bytecodealliance.org/articles/WASI-0.3).

### WASI 0.3 (preview 3): native async **[V]**
- **Released 2026-06-11 (0.3.0); 0.3.1 on 2026-08-11** (https://wasi.dev/releases/wasi-p3; https://github.com/WebAssembly/WASI/releases/tag/v0.3.0).
- Adds `async func`, `stream<T>`, `future<T>` and `error-context` to WIT; **`wasi:io` is removed entirely**, its role absorbed by the canonical ABI. HTTP handler and CLI `run` become `async func`; filesystem descriptor methods become async; sockets collapse from seven interfaces to two.
- **Wasmtime 46.0.0 (2026-06-22)** ships WASI 0.3.0 with component-model-async **enabled by default**; 41–45 required flags (https://github.com/bytecodealliance/wasmtime/releases/tag/v46.0.0). jco supports 0.3 on JS hosts.
- Toolchains: Rust `wit-bindgen` maps `async func` to `async fn`; `componentize-go` uses stackful goroutines; Python/JS/C use stackless coroutines "through the same ABI" (https://bytecodealliance.org/articles/WASI-0.3). Rust has a **tier-3 `wasm32-wasip3` target** (PR #147205) with a proposal to promote it to tier 2 as a 2026 project goal (https://doc.rust-lang.org/nightly/rustc/platform-support/wasm32-wasip3.html; https://github.com/rust-lang/compiler-team/issues/1001; https://rust-lang.github.io/rust-project-goals/2026/wasm-components.html). The `wasip3` crate is generated by wit-bindgen; `wit-bindgen`'s `async` option ("The resulting bindings will use the component model async ABI") can be set globally or per function (https://docs.rs/wit-bindgen/latest/wit_bindgen/macro.generate.html; https://docs.rs/wasip3).

### How the canonical ABI does async *without* guest stack switching **[V]** (https://github.com/WebAssembly/component-model/blob/main/design/mvp/Concurrency.md; https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md)
- Every export call creates a **task**; each import call creates a **subtask**. Built-ins: `task.return`, `waitable-set.new/wait/poll/drop`, `waitable.join`, `subtask.cancel/drop`, `stream.new/read/write/cancel-read/cancel-write/drop-readable/drop-writable`, `future.*` likewise, `error-context.new/debug-message/drop`, `backpressure.inc/dec` (older spec: `backpressure.set`), `context.get/set` (per-task "TLS" slots), `thread.*`.
- **Stackless ("callback") lift**: `canon lift ... async callback $f`. The core export returns an `i32` code: `0` = completed, `1` = yield, `2 | (waitable_set_idx << 4)` = wait on that waitable-set. The runtime then repeatedly calls the `callback` export with `(event_code, index, payload)` until it returns 0. Between events the engine's native stack is empty, so **no stack switching is required in the engine or the guest** — the guest must be a state machine (exactly what Rust/Kotlin/C# style compilation produces).
- **Stackful lift** (`async` without `callback`, gated by the 🚟 feature): the core export simply calls `task.return` as an import and the engine parks the whole stack when the guest calls `waitable-set.wait`; this is what Go's goroutines need, and Wasmtime implements it using its own host fibers.
- The spec is "specified in terms of" core stack switching but "doesn't depend on it"; engines can elide fiber creation. Sync-ABI code calling async imports takes an exclusive lock (run-to-completion invariant), which is how a plain synchronous component stays usable.
- **Wasmtime host side**: `wasmtime::component` gains `Accessor` (store access from a host task), `StreamReader/StreamWriter`, `FutureReader/FutureWriter`, `ErrorContext`, `JoinHandle`, `StreamProducer/Consumer` traits, and concurrent call/run APIs, all behind the `component-model-async` cargo feature (https://docs.rs/wasmtime/latest/wasmtime/component/index.html). The `Config` docs still say support is "*very* incomplete" (docstring not updated after v46 — treat as stale **[V]** quote).

### Wasmtime host-only async **[V]**
Independent of the guest: `Config::async_support` runs each call on a separate host fiber (`async_stack_size` default 2 MiB; host functions get `async_stack_size − max_wasm_stack`), and `epoch_interruption` / `consume_fuel` let the embedder yield the guest cooperatively (`Store::set_epoch_deadline`, `fuel_async_yield_interval`). This lets a Rust host `await` inside a host import while the guest is parked — but the guest itself sees a synchronous call (https://docs.rs/wasmtime/latest/wasmtime/struct.Config.html).

---

## 5. How languages target WASM async today

| Language | Mechanism | Verified detail |
|---|---|---|
| **Rust (browser)** | (b) state machines + `wasm-bindgen-futures` executor | `spawn_local`, `future_to_promise`, `JsFuture`; single-threaded executor driven from the JS microtask queue (**[PK]** that it uses `queueMicrotask`/`Promise.then`; source fetch failed today) (https://docs.rs/wasm-bindgen-futures). JSPI support tracked in https://github.com/rustwasm/wasm-bindgen/issues/3633. |
| **Rust (wasip1/wasip2)** | (b) + WASI polling | `wstd::runtime::block_on` over pollables (https://github.com/bytecodealliance/wstd). |
| **Rust (wasip3)** | (b) + callback ABI | `wit-bindgen` `async` option; tier-3 `wasm32-wasip3` (above). |
| **Swift** | (b) LLVM async lowering | `JavaScriptEventLoop` is a `SerialExecutor` that hands jobs to the JS event loop; install with `JavaScriptEventLoop.installGlobalExecutor()` (https://github.com/swiftwasm/JavaScriptKit/blob/main/Sources/JavaScriptEventLoop/JavaScriptEventLoop.swift; https://book.swiftwasm.org/getting-started/concurrency.html). No stack switching. |
| **Kotlin/Wasm** | (b) CPS + state machine | KEEP design; `kotlinx-coroutines-core-wasm-js` provides `promise{}`/`asPromise()`; `Dispatchers.Default/IO` behave like `Main` on wasm (https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/%5Bwasm-js%5Dpromise.html). |
| **C# / .NET (Blazor, browser-wasm)** | (b) C# async state machines; JS interop via Promise↔Task | JSPI for sync-over-async is issue #80904, still **open, "Future" milestone**; .NET 10 shipped without JSPI (https://github.com/dotnet/runtime/issues/80904; https://platform.uno/blog/the-state-of-webassembly-2025-2026/). "Uses JSPI" in .NET 9/10 — **not verified; appears false**. |
| **Go (gc)** | compiler-built stack copying/unwinding (Asyncify-like) | `PC_B` resume points, `BrTable` dispatch, Go stacks in linear memory; `wasm_exec.js` bridges the browser loop; single-threaded, "any host function calls will cause all goroutines to block" (https://raw.githubusercontent.com/golang/go/master/src/cmd/internal/obj/wasm/wasmobj.go; https://go.dev/blog/wasi). |
| **TinyGo** | (a) Binaryen Asyncify | default `-scheduler=asyncify` for wasm (https://tinygo.org/docs/reference/usage/important-options/). |
| **Python (Pyodide)** | (c) JSPI, previously Asyncify | `pyodide.ffi.run_sync(awaitable)` blocks Python until the awaitable settles; requires JSPI and an async (`promising`) entry from JS; Pyodide 0.27.7 supports Chrome 137, Node 24 (flagged), Firefox (pref) (https://blog.pyodide.org/posts/jspi/; https://blog.pyodide.org/posts/jspi-with-c-runtime/ — pages returned 403 today; details from docs/search **[PK]**). |
| **OCaml (wasm_of_ocaml)** | three modes | `--effects=jspi` (default; Chrome 137+, Node 25+), `--effects=cps` (selective CPS, "slower, larger", any engine), `--effects=native` (core stack switching; "best performance"; needs `--experimental-wasm-wasmfx`, Chrome 148+/V8 14.7.100+) (https://github.com/ocsigen/js_of_ocaml/blob/master/README_wasm_of_ocaml.md). This is the best real-world data point of all three families on one compiler. |
| **Scheme (Guile Hoot)** | (b) CPS with explicit stacks | Minimal CPS so all calls are tail calls; three explicit stacks (numeric in memory, refs in a table, return continuations); slicing gives delimited continuations and fibers; "10x penalties in some cases"; JSPI seen as only partial; awaits core stack switching (https://wingolog.org/archives/2024/05/27/cps-in-hoot). |
| **Koka** | (b) via its C backend | Evidence-passing / yield-bubbling monadic translation compiled through Emscripten — effect handlers need no stack switching (https://github.com/koka-lang/koka; https://dl.acm.org/doi/10.1145/3622814 for the WasmFX contrast). Koka wasm target details **[PK]**. |
| **Scala.js (Wasm backend)** | (c) JSPI | `js.async {}` / `js.await()` require `--experimental-wasm-jspi` on Node (https://scala-cli.virtuslab.org/docs/guides/advanced/scala-wasm/). |
| **Dart (dart2wasm)** | (b) state machine | `_AsyncSuspendState` + `br_table` (above). |
| **PHP (WordPress Playground)** | (a) → (c) | Asyncify with curated `ASYNCIFY_ONLY`; JSPI auto-enabled where available (above). |
| **Lua and other C interpreters** | (a) or (c) | Interpreters written in C (e.g., Lua via Emscripten) typically rely on `-sASYNCIFY`/`-sJSPI` **[PK, unverified per project]**. |

---

## 6. Exceptions across async boundaries

- **Asyncify + EH**: Asyncify instruments calls, not `try_table`; an unwind returning through a `try_table` region is just a normal return (Asyncify does not throw), so EH itself is unaffected. However, unwinding *inside* a `catch` handler or across `setjmp` is only supported to the extent the toolchain instruments those paths; Emscripten's JS-based `-fexceptions` (`invoke_*` trampolines) breaks JSPI/`ASYNCIFY=2` ("Missing __sig for invoke_diii", "invalid suspender object"), whereas `-fwasm-exceptions` works (https://github.com/emscripten-core/emscripten/issues/19672). Rule of thumb: keep the JS glue out of the wasm call chain between the async boundary and the suspension point.
- **JSPI + rejected Promises**: the rejection becomes a wasm exception "according to the JS API of the Exception Handling proposal" — catchable with `try_table` + `catch_all_ref`/JS-tag matching; if not caught it propagates to the `promising` wrapper, which rejects its Promise (Overview.md). Exceptions thrown by wasm inside a `promising` call also reject the Promise (V8 blog). Suspending illegally raises `WebAssembly.SuspendError`.
- **Core stack switching + EH**: `resume_throw` injects an exception at the suspension point; a suspended continuation that is never resumed is simply garbage (one-shot); unwinding a coroutine = `resume_throw` with an "abort" tag (Explainer).
- **State machines + `Result`/exceptions**: exceptions do not cross a suspension point naturally; Kotlin/Dart store the pending exception in the state object and rethrow on resume (Dart's `_AsyncSuspendState` has `currentException`/`currentExceptionStackTrace` fields) — i.e., the compiler must thread failures explicitly (Rust `Result`, Kotlin `resumeWithException`).
- **Component-model async**: errors on streams/futures are `error-context` values, not exceptions; traps in a subtask tear down the component instance (CanonicalABI.md).

---

## 7. Comparison table

| Property | (a) Asyncify / compiler-built unwinding (Go) | (b) CPS / state machines | (c1) JSPI | (c2) Core stack switching | Component-model async (callback ABI) |
|---|---|---|---|---|---|
| Needs engine feature | No (MVP wasm) | No | JS-API feature | Core proposal (Phase 3) | Component host (wasmtime ≥ 46, jco) |
| Browser support 2026 | All | All | Chrome/Edge 137+, Firefox 153+, Safari 27 (beta), Node 25+ | None shipped; V8 flag only | N/A on the web (jco polyfills) |
| Wasmtime | Yes (host implements protocol) | Yes | No (not a JS host) | Experimental, x86_64 Linux, off by default | Yes, default in 46+ |
| Code size | +50–100% (up to 2x) unless pruned | +modest per suspend fn (frame structs, resume dispatch) | ≈0 | ≈0 | ≈0 (bindings glue only) |
| Runtime cost | ~50% slowdown on instrumented paths; unwind/rewind cost per switch | Heap frame per coroutine, virtual dispatch; no cost on non-async code | ~1 µs per suspension; ~1 MB stack per in-flight call | Expected cheapest (native switch) | One host round-trip per event |
| Suspend inside deep native/host frames | Only through instrumented wasm; never across host frames | Never (every frame must be transformed) | Only across wasm frames; traps if JS frame in between | Only across wasm frames (host calls from continuation stacks restricted in wasmtime) | Only at ABI boundaries via `waitable-set.wait` |
| Debugging | Poor (control flow mangled; missing-function crashes) | Medium (split functions, DWARF confusion) | Good (real stacks; DevTools show suspended stacks) | Good in principle; immature tools | Medium (event loop indirection) |
| Interaction with EH | Works with wasm EH; broken with JS-glue EH | Manual exception threading | Rejection → wasm exception | `resume_throw`; designed together | `error-context` values |
| Interaction with threads | Independent (single linear stack per thread) | Independent | Per-thread; no sharing of suspended stacks across workers | Continuations not shareable (shared-everything integration TODO) | Threads via `thread.*` builtins, still early |
| Reentrancy | Unsafe by default (Emscripten warning) | Safe | Allowed, but guest globals (shadow stack) must be re-entrant | Safe by construction | Safe (tasks) |

---

## 8. Implications for Ferlium

1. **Do not depend on core stack switching for the first backend.** It is Phase 3 with an experimental V8 flag and an x86_64-only experimental wasmtime path; no browser ships it. Design the IR so a `cont.new/suspend/resume` backend can be added later (wasm-encoder already encodes it), but ship without it.

2. **Prefer family (b) — a compiler-level transformation — as the baseline.** Ferlium already does effect inference, which is precisely the information needed to make a *selective* CPS/state-machine transformation cheap: only functions whose inferred effect row includes the "may suspend" effect need splitting, exactly as wasm_of_ocaml's selective CPS and Hoot's minimal CPS do. This works identically on browsers, wasmtime, and future native backends, needs no engine features, is reentrant, and composes with the WASI 0.3 callback ABI (stackless lift) without any bridge. Costs to budget: heap-allocated frames for suspendable functions, explicit exception threading across suspension points, and no suspension across host frames (host callbacks must be non-suspending or CPS-aware).

3. **Layer JSPI as an optional accelerator, not a foundation.** JSPI is now standard and shipping in all three engines (Safari only in the 27 beta), but it (i) only exists on JS hosts, (ii) ties suspension to Promises, (iii) traps if a JS frame sits between `promising` and the suspending import, and (iv) reserves ~1 MB per in-flight call (segmented stacks unverified). It is ideal for the "call an async Web API from synchronous-looking Ferlium code" use case and for a JS host runtime, exactly as wasm_of_ocaml uses it. Follow wasm_of_ocaml's precedent: `--effects={cps|jspi|native}` selectable per build.

4. **For the wasmtime/WASI target, target the WASI 0.3 callback ABI directly.** The stackless lift (`async callback`) requires the guest to return codes and be re-entered with events, which is naturally produced by a state-machine transformation. Emit `task.return`, `waitable-set.*`, `stream.*`/`future.*` calls through `wasm-encoder`'s component support, or emit a core module plus WIT and let `wasm-tools component new` do the wrapping. Wasmtime 46+ makes this the default, and Rust `wit-bindgen` is the reference for what bindings should look like.

5. **Native backends**: family (b) transfers directly (Rust's own async is family (b)). If a native backend wants stackful coroutines, use a fiber library (as wasmtime does for `async_support`), but keep the wasm backend stackless so one IR serves both.

6. **Exceptions**: define Ferlium's effect/exception semantics so that a suspended computation can be resumed with an injected error (the `resume_throw` shape). This maps to `Result`-threading in family (b), to JS rejection → wasm exception under JSPI, and to `resume_throw` under core stack switching — one semantic model, three lowerings.

7. **Threads are orthogonal and far off**: the threads proposal gives shared memory and atomics only; shared-everything-threads is Phase 1; wasi-threads is withdrawn. Do not couple the async design to threads; plan for single-threaded event loops plus Workers/wasmtime threads at the host level.

### Items I could not verify (flagged)
- Whether V8 shipped growable/segmented JSPI stacks after June 2024.
- Any SpiderMonkey/JSC implementation of core stack switching.
- Deno/Bun JSPI release notes.
- Exact date of the stack-switching Phase 3 vote.
- Direct fetch of Pyodide JSPI blog posts (403) and Go's design doc — content taken from search snippets and Go source comments respectively.
- .NET/Blazor: no evidence JSPI is used; issue remains open.
- wasmtime-py Asyncify support; Lua/wasmoon specifics.

### Primary sources used
- JSPI: https://github.com/WebAssembly/js-promise-integration/blob/main/proposals/js-promise-integration/Overview.md · https://v8.dev/blog/jspi · https://v8.dev/blog/jspi-newapi · https://developer.chrome.com/blog/new-in-chrome-137 · https://developer.mozilla.org/en-US/docs/Mozilla/Firefox/Releases/153 · https://bugzilla.mozilla.org/show_bug.cgi?id=2044809 · https://webkit.org/blog/17967/news-from-wwdc26-webkit-in-safari-27-beta/ · https://caniuse.com/wf-wasm-jspi · https://nodejs.org/en/blog/release/v25.0.0
- Stack switching: https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Explainer.md · https://github.com/WebAssembly/proposals · https://raw.githubusercontent.com/v8/v8/master/src/wasm/wasm-feature-flags.h · https://github.com/bytecodealliance/wasmtime/issues/10248 · https://docs.wasmtime.dev/stability-wasm-proposals.html · https://wasmfx.dev/
- Asyncify/Emscripten: https://kripken.github.io/blog/wasm/2019/07/16/asyncify.html · https://emscripten.org/docs/porting/asyncify.html · https://github.com/emscripten-core/emscripten/issues/19672 · https://wordpress.github.io/wordpress-playground/developers/architecture/wasm-asyncify/
- WASI/Component Model: https://bytecodealliance.org/articles/WASI-0.3 · https://wasi.dev/releases/wasi-p3 · https://github.com/WebAssembly/component-model/blob/main/design/mvp/Concurrency.md · https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md · https://github.com/bytecodealliance/wasmtime/releases/tag/v46.0.0 · https://docs.rs/wasmtime/latest/wasmtime/struct.Config.html · https://docs.rs/wit-bindgen/latest/wit_bindgen/macro.generate.html · https://doc.rust-lang.org/nightly/rustc/platform-support/wasm32-wasip3.html · https://github.com/bytecodealliance/wstd · https://github.com/WebAssembly/wasi-threads · https://github.com/WebAssembly/shared-everything-threads
- Languages: https://github.com/ocsigen/js_of_ocaml/blob/master/README_wasm_of_ocaml.md · https://wingolog.org/archives/2024/05/27/cps-in-hoot · https://raw.githubusercontent.com/golang/go/master/src/cmd/internal/obj/wasm/wasmobj.go · https://tinygo.org/docs/reference/usage/important-options/ · https://github.com/Kotlin/KEEP/blob/master/proposals/coroutines.md · https://raw.githubusercontent.com/dart-lang/sdk/main/pkg/dart2wasm/lib/async.dart · https://llvm.org/docs/Coroutines.html · https://github.com/swiftwasm/JavaScriptKit/blob/main/Sources/JavaScriptEventLoop/JavaScriptEventLoop.swift · https://github.com/dotnet/runtime/issues/80904 · https://blog.pyodide.org/posts/jspi/ · https://scala-cli.virtuslab.org/docs/guides/advanced/scala-wasm/ · https://platform.uno/blog/the-state-of-webassembly-2025-2026/