# Research memo: WebAssembly exception handling and unwinding, as of 2026‑09‑04

Audience: Ferlium implementers (Rust interpreter today; planned WASM backend via `wasm-encoder`; possible native backends). Notation: **[V]** = verified this session against the cited source; **[PK]** = my prior knowledge, not re‑verified; **[?]** = could not verify / sources disagree.

---

## 1. The proposal, its history, and precise semantics

### 1.1 Timeline

- **Legacy design (2019–2023).** The original Phase‑3 design used `try` / `catch` / `catch_all` / `delegate` / `rethrow` structured blocks. It shipped in Chrome 95, Firefox 100 and Safari 15.2 (feature table: https://raw.githubusercontent.com/WebAssembly/website/main/features.json, row `exceptions`) **[V]**. The feature table now lists that row as *Inactive* **[V]**. (The task brief said Safari 15.4; the feature table says 15.2 **[?]**.)
- **Redesign to `exnref` (Oct 2023).** The explainer states it "reflects the up-to-date version of the exception handling proposal agreed on Oct 2023 CG meeting" (https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md) **[V]**. The redesign introduced `try_table`, `throw_ref`, and the first‑class `exnref` value; per the Uno "State of WebAssembly" summary and the explainer, the motivation was JS‑API identity problems for thrown exceptions and reduced spec/engine complexity **[V]**.
- **Phase 4/5 and merger into the spec.** The proposal repository was archived on 2025‑04‑25 (GitHub banner on the explainer) **[V]**, and the text now lives at https://github.com/WebAssembly/spec/blob/wasm-3.0/proposals/exception-handling/Exceptions.md **[V]**. The `exnref` row in the feature table is Phase 5 **[V]**. Exception handling is one of the headline features of **Wasm 3.0, announced 2025‑09‑17** as "the new 'live' standard": "Previously, there was no efficient way to compile exception handling to Wasm … Wasm 3.0 hence provides native exception handling within Wasm" (https://webassembly.org/news/2025-09-17-wasm-3.0/) **[V]**. One secondary source (devnewsletter.com) claims the 3.0 spec "landed on June 13, 2026"; I treat the webassembly.org post as authoritative and the other as an error or a reference to a later W3C document stage **[?]**. Whether Wasm 3.0 has formally reached W3C Recommendation status (vs. the CG/WG "live standard") I could not confirm **[?]**.

### 1.2 Instruction semantics (final, exnref design)

Source: explainer + spec branch above; MDN reference (https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/Exception_handling/try_table) **[V]**.

- **Tags.** A new *tag section* (section id 13, placed after memory and before global) declares tags; each tag has an attribute byte (0 = exception) and a type index naming a function type whose *parameters* are the payload types **[V]**. Tags can be imported/exported. Identity: "For tag indices that are not imported/exported, the corresponding exception tag is guaranteed to be unique over all loaded modules. Exceptions that are imported or exported alias the respective exceptions defined elsewhere, and use the same tag" **[V]**. Identity is dynamic (per instance), which is why Wasmtime notes it "cannot statically optimize handler lists because imported tags may have identical dynamic identities" (https://bytecodealliance.org/articles/wasmtime-exceptions) **[V]**.
- **`throw tagidx`** (0x08): pops payload values matching the tag's parameter types, allocates an exception, and throws **[V]**.
- **`throw_ref`** (0x0a): pops an `exnref` and rethrows it; "If the operand is null, a trap occurs" **[V]**.
- **`try_table bt catch*`** (0x1f): a normal structured block (branch target, block type) whose immediates are a vector of catch clauses. Encoding: `0x1f bt:blocktype n:u32 (ct:catch)^n instr* 0x0b`. Clauses: `catch tag label` (0x00), `catch_ref tag label` (0x01), `catch_all label` (0x02), `catch_all_ref label` (0x03). A caught exception does not "land" inside the `try_table`; it **branches to the enclosing label** with the payload on the stack (`catch`), payload plus an `exnref` (`catch_ref`), nothing (`catch_all`), or only an `exnref` (`catch_all_ref`). Clauses are tried in order **[V]**. The body of the `try_table` has no separate "handler" region; handlers are just ordinary blocks that the `catch` labels point to, which is why the design composes cleanly with `br`/`br_if`.
- **`exnref`** (type opcode −0x17) is a reference value: nullable, first‑class, usable in locals; with the GC proposal it forms its own heap‑type hierarchy `exn` / `noexn` (`nullexnref` = −0x0c), disjoint from `any`/`func`/`extern` **[V]**. Whether `exnref` may be a table element type or global type: the explainer text I fetched did not state this **[?]**; I believe it is allowed as a local/global but not as a table element type in Wasm 3.0 **[PK]**. The JS API forbids `exnref` (and `v128`) as payload values of `WebAssembly.Exception` **[V]**.
- **Traps vs exceptions.** "the `try_table` instruction does not catch exceptions generated from traps," nor "JavaScript exceptions generated from stack overflow and out of memory." Rationale: "traps are not locally recoverable"; implementations must "specially mark non-catchable exceptions" **[V]**. So `unreachable`, OOB memory access, integer divide by zero, stack exhaustion, `throw_ref` on null, etc. unwind the whole wasm stack up to the host regardless of any `try_table`.
- **Foreign (JS) exceptions.** `try_table` "catches foreign exceptions generated from calls to function imports as well, including JavaScript exceptions" **[V]**. In the JS API, a JS value thrown by an import is wrapped as a wasm exception with the reserved tag `WebAssembly.JSTag`, whose single payload slot holds the JS value; a `catch (JSTag)` therefore yields the JS value as an `externref`. Conversely, a wasm exception carrying `JSTag` that escapes to JS is unwrapped back to the original JS value (https://webassembly.github.io/exception-handling/js-api/) **[V]**. `WebAssembly.Exception` cannot be constructed with `JSTag` from JS **[V]**.
- **Uncaught wasm exceptions in JS.** They surface as `WebAssembly.Exception` objects (with `.is(tag)` and `.getArg(tag, i)`); traps surface as `WebAssembly.RuntimeError` **[V]**. `new WebAssembly.Exception(tag, payload, {traceStack: true})` requests a stack trace on `.stack`; by default no trace is captured, for performance (JS‑API spec; MDN `Exception/stack`) **[V]**.
- **Single‑phase unwinding.** The design is one‑pass (no search phase, no filters). This is explicitly discussed as a limitation for .NET's two‑pass model (https://github.com/dotnet/runtimelab/issues/1983; https://github.com/WebAssembly/exception-handling/issues/123) **[V]**. `std::set_terminate` cannot be fully supported in Emscripten for the same reason (https://emscripten.org/docs/porting/exceptions.html) **[V]**.
- **Tail calls inside `try_table`.** I found no spec statement **[?]**. Since `return_call` "first return[s] from the current function before actually performing the respective call" (tail‑call overview), any `try_table` in the caller is necessarily gone when the callee runs; a tail call inside a protected region silently drops the handler **[inference]**.

---

## 2. Engine/runtime support matrix

Primary source: https://raw.githubusercontent.com/WebAssembly/website/main/features.json (rendered at https://webassembly.org/features/) **[V]**, cross‑checked where noted.

| Engine | Legacy EH (`try/catch/delegate`) | exnref EH (`try_table`) | Notes |
|---|---|---|---|
| Chrome / V8 | 95 (Oct 2021) | **137** (2025‑05‑27) | Web‑features explorer confirms 137; Cloudflare's blog says 138 **[?]** (https://web-platform-dx.github.io/web-features-explorer/features/wasm-exnref-exceptions/) |
| Edge | 95 | 137 (2025‑05‑29) | Baseline "Newly available" since 2025‑05‑29 **[V]** |
| Firefox / SpiderMonkey | 100 | **131** (2024‑10‑01) | Bugs 1853454, 1873776 **[V]** |
| Safari / JSC | 15.2 (table) | **18.4** (2025‑03‑31) | https://webkit.org/blog/16574/webkit-features-in-safari-18-4/ **[V]** |
| Node.js | 17.0 | **24.15** (table; wasm‑bindgen says 22.22.3+/24.15.0+) | Node 24 ships V8 13.6, so exnref appears to have been enabled by backported flag flip in 24.15 (2026‑04‑15); the 24.15 notes do not mention it **[?]** |
| Deno | 1.16 | 2.3.2 | table only **[V]** |
| Bun (JSC) | — | — | Not verifiable; JSC has exnref since the Safari 18.4 era, so a current Bun very likely has it **[?]** |
| Wasmtime | never | **37** implemented, off by default (2025‑09‑20); **47** on by default (2026‑07‑20) | https://github.com/bytecodealliance/wasmtime/releases/tag/v37.0.0, …/v47.0.0 **[V]** |
| Wasmer | never | **6.0** (2025‑04‑25), LLVM/V8/JS backends | https://wasmer.io/posts/announcing-wasmer-6-closer-to-native-speeds **[V]**; unclear whether singlepass/cranelift backends support it **[?]** |
| WasmEdge | — | **0.14.0** interpreter only (2024‑05‑22); 0.15.0 serializer/exnref (2025‑08‑04); **0.18.0‑alpha.1** AOT/JIT (2026‑08‑28) | https://github.com/WasmEdge/WasmEdge/blob/master/Changelog.md **[V]** |
| WAMR | interpreter impl of an *older* draft behind `-DWAMR_BUILD_EXCE_HANDLING=1` | RFC to update to current spec (#3753, opened 2024‑08‑23), interpreter first | I could not confirm the exnref version has landed **[?]** |
| wazero | never (snapshot/restore for setjmp/longjmp since v1.7.0) | **v1.12.0** (PR #2489 merged 2026‑04‑26): exnref/`try_table`, interpreter + wazevo compiler, behind `experimental.CoreFeaturesExceptionHandling`; legacy opcodes rejected with a hint to run `wasm-opt --translate-to-exnref` **[V]** | https://github.com/tetratelabs/wazero/pull/2489 |
| wasmi | no | **no** (tracking issue #1137) **[V]** | |
| wasm3 | — | table says 0.9.1 **[?]** (could not corroborate) | |
| wasm2c (wabt) | flag | `--enable-exceptions`; wabt 1.0.37 "wasm2c: Implement EHv4" **[V]** | |
| Wizard | 24 | 24 | table only |
| GraalWasm | flag `--wasm.LegacyExceptions=true` | 25.1 | table only |
| Binaryen | yes | yes | |

Notes: Wasmtime's `Config::wasm_exceptions` "is `true` by default" and is gated on the `gc` cargo feature (docs for 49.0.0‑dev, https://docs.wasmtime.dev/api/wasmtime/struct.Config.html) **[V]**; the CLI equivalent is `-W exceptions` (`wasmtime -W help`) **[PK]**. Wasmtime 47 also "converts unhandled wasm exceptions at component boundaries to traps" (#13613) **[V]**. I found no evidence that V8/SpiderMonkey/JSC have removed legacy EH; Chrome, Firefox, Safari still accept both encodings **[PK/?]**.

---

## 3. Toolchain support

### 3.1 LLVM / clang
- `-fwasm-exceptions` enables Wasm EH (sets `-mllvm -wasm-enable-eh`). LLVM 21 added the standardized exnref lowering and a new backend flag `-wasm-use-legacy-eh` (replacing the older `-wasm-enable-exnref`), which "is turned on by default for the moment" because browsers defaulted to legacy (https://releases.llvm.org/21.1.0/docs/ReleaseNotes.html; https://github.com/llvm/llvm-project/pull/122158) **[V]**.
- **Default still legacy as of today:** LLVM `main` `WebAssemblyTargetMachine.cpp` has `WasmUseLegacyEH … cl::init(true)` with a comment that it "will later change to false" **[V]**; LLVM 22.1.0 release notes mention nothing about it **[V]**. To get standard output from clang today: `-fwasm-exceptions -mllvm -wasm-use-legacy-eh=false` **[V]**.
- Wasm SjLj (`-mllvm -wasm-enable-sjlj`) is built on the same EH machinery (https://reviews.llvm.org/D108582) **[V]**.

### 3.2 Emscripten
- Three modes (https://emscripten.org/docs/porting/exceptions.html) **[V]**: (a) default `-sDISABLE_EXCEPTION_CATCHING=1`: throws abort; (b) `-fexceptions`: JS‑based EH — every potentially‑throwing call goes through JS `invoke_*` trampolines with `try/catch`; "works on all JavaScript engines with WebAssembly support" but "relatively high overhead"; (c) `-fwasm-exceptions`: native EH, "can reduce code size and performance overhead".
- Emscripten 4.0.0 (2025‑01‑14) added `-sWASM_LEGACY_EXCEPTIONS` (default `true`, replacing the inverted `-sWASM_EXNREF`); the settings reference still shows default `true` today (https://emscripten.org/docs/tools_reference/settings_reference.html; ChangeLog) **[V]**. So Emscripten also still emits legacy EH unless you pass `-sWASM_LEGACY_EXCEPTIONS=0`.
- setjmp/longjmp: `-sSUPPORT_LONGJMP=wasm|emscripten`; since 3.1.32 the default follows the EH mode (`wasm` if `-fwasm-exceptions`, else `emscripten`); Wasm SjLj cannot call `setjmp` inside a C++ `catch` clause (https://emscripten.org/docs/porting/setjmp-longjmp.html) **[V]**.
- Stack traces in uncaught exceptions need `-sASSERTIONS` or `-sEXCEPTION_STACK_TRACES` **[V]**.
- Async: `-sASYNCIFY=2` was deprecated in 3.1.59 in favour of `-sJSPI`; JSPI "is no longer considered experimental" as of 6.0.8 (2026‑08‑20) **[V]**.

### 3.3 Binaryen
`wasm-opt --translate-to-exnref` (earlier name `--translate-to-new-eh`, pass `TranslateEH.cpp`) rewrites legacy `try/catch/delegate/rethrow` into `try_table`/`throw_ref` "without recompiling" (https://github.com/WebAssembly/binaryen/blob/main/src/passes/TranslateEH.cpp) **[V]**. This is the bridge everyone (wazero, Kotlin, Rust users) relies on while LLVM's default lags.

### 3.4 wasm‑tools / `wasm-encoder` (your backend)
`wasm-encoder` 0.258.0 (https://docs.rs/wasm-encoder/latest/wasm_encoder/enum.Instruction.html) **[V]** provides:
- `Instruction::TryTable(BlockType, Cow<'a, [Catch]>)`, `Instruction::Throw(u32)`, `Instruction::ThrowRef`;
- `Catch::One { tag, label }`, `Catch::OneRef { tag, label }`, `Catch::All { label }`, `Catch::AllRef { label }` (https://docs.rs/wasm-encoder/latest/wasm_encoder/enum.Catch.html);
- `TagSection::new().tag(TagType { kind: TagKind::Exception, func_type_idx })`, and `EntityType::Tag(TagType)` for imports (exports use the tag export kind) (https://docs.rs/wasm-encoder/latest/wasm_encoder/struct.TagSection.html, …/enum.EntityType.html);
- legacy `Try/Catch/CatchAll/Delegate/Rethrow` variants remain available;
- `ValType::EXNREF` / heap types `Exn`/`NoExn` **[PK]**.
`wasmparser::WasmFeatures::EXCEPTIONS` defaults to `true` and is in the `WASM3` set; `LEGACY_EXCEPTIONS` defaults to `false` (https://docs.rs/wasmparser/latest/wasmparser/struct.WasmFeatures.html) **[V]**. So you can emit and validate exnref EH entirely in Rust with no C++ toolchain.

### 3.5 Rust
- Tracking issue https://github.com/rust-lang/rust/issues/118168: compiler support (#111322) and std support (#121438) merged; "LLVM support for newest EH iteration", docs and stabilization still open **[V]**.
- Status: **nightly‑only**. The rustc book says: `RUSTFLAGS='-Cpanic=unwind -Cllvm-args=-wasm-use-legacy-eh=false' cargo +nightly build --target wasm32-unknown-unknown -Zbuild-std`, because the shipped std is `panic=abort`, and "as of 2025-10-03 LLVM is still using the 'legacy exception instructions' by default" (https://doc.rust-lang.org/nightly/rustc/platform-support/wasm32-unknown-unknown.html) **[V]**. Docs PR #147309 states "there are no concrete proposals at this time to adding a new set of targets which support unwinding" **[V]**. PR #146457 (rollup #147169, merged 2025‑09‑30) makes rustc skip EH cleanups unless `panic=unwind` or `+exception-handling` is on **[V]**.
- wasm‑bindgen 0.2.122 (2026‑05‑22): "`-Cpanic=unwind` on wasm targets now emits modern (exnref) exception handling by default … requires Node.js 22.22.3+ (for `WebAssembly.JSTag`)"; legacy via `-Cllvm-args=-wasm-use-legacy-eh` (https://github.com/wasm-bindgen/wasm-bindgen/releases) **[V]**. Whether this reflects a rustc default change or a wasm‑bindgen post‑processing step I could not determine **[?]**. Panics escaping exports become JS `PanicError`; async exports reject; arguments must be `UnwindSafe`; stack overflow/OOM/`unreachable` still kill the instance (https://wasm-bindgen.github.io/wasm-bindgen/reference/catch-unwind.html) **[V]**. Cloudflare's write‑up of the walrus/descriptor changes: https://blog.cloudflare.com/making-rust-workers-reliable/ (2026‑04‑22) **[V]**. 0.2.127 (2026‑08‑08) fixed `__stack_pointer` restoration after an unwinding export, i.e. shadow‑stack leaks were a real bug until recently **[V]**.
- Emscripten target: wasm EH became unconditional; `-Zemscripten-wasm-eh` was removed (#156928, merged 2026‑06‑03) **[V]**.

### 3.6 Other languages
- **Kotlin/Wasm** (Beta since 2.2.20): supports both flavours; `wasmJs` defaults to *legacy*, `wasmWasi` defaults to the new proposal; switch with `-Xwasm-use-new-exception-proposal` (https://kotlinlang.org/docs/wasm-configuration.html) **[V]**. Kotlin is the best precedent for a GC‑language backend using Wasm EH for language exceptions.
- **.NET**: Blazor/Mono‑wasm builds use Emscripten; NativeAOT‑LLVM tracked "support wasm exceptions instead of exceptions through javascript" (#1983) and documents that .NET's two‑pass filter semantics cannot map directly onto single‑pass Wasm EH **[V]**. Current shipping default in .NET 9/10 I did not verify **[?]**.
- **Go**: no Wasm EH; panics use Go's own runtime. "If a panic reaches the top-level of the `go:wasmexport` call, the program crashes because there are no mechanisms allowing the guest application to propagate the panic to the Wasm host" (https://github.com/golang/go/issues/65199) **[V]**.
- **Zig**: errors are values (error unions); no unwinding on wasm **[V, secondary source]**.
- **Wasmer's WASIX** reimplemented setjmp/longjmp on Wasm EH instead of Asyncify **[V]**.

---

## 4. Unwinding without (or beside) Wasm EH

| Strategy | Mechanism | Happy‑path cost | Throw cost | Code size | Portability |
|---|---|---|---|---|---|
| **Errors as values** (`Result`/multi‑value returns) | Every call returns a status; caller branches | one branch per call (usually predicted); extra return slot | cheap, deterministic | moderate growth (checks after every call) | universal, works in every engine and in components |
| **Panic = trap** (`unreachable`) | abort the instance; host sees `RuntimeError`/trap | zero | instance is dead | smallest | universal; this is what Rust `panic=abort` and Go effectively do |
| **Wasm EH** (`try_table`/`throw`) | engine side tables; handler = block label | "zero-cost … when no errors occur" (Cranelift article) **[V]**; in Wasmtime, `try_call` "clobber[s] all registers" so there is some register‑allocation pressure at protected call sites **[V]** | allocation of an exception object + stack walk with per‑frame table lookup (Wasmtime "always allocates an exception object") **[V]** | small (tables in engine, not in code) | needs Wasm 3.0 engine; see matrix |
| **JS‑based EH** (Emscripten `-fexceptions`) | `invoke_*` JS trampolines with JS `try/catch` around every may‑throw call | JS call boundary per call — "relatively high overhead" **[V]** | JS exception | large | any browser; not usable off‑web |
| **Asyncify** (Binaryen) | instruments code to unwind/rewind its own stack through linear memory | "something like 50% or so" slowdown; unoptimized builds "very large" (https://emscripten.org/docs/porting/asyncify.html) **[V]**; Wasmer measured "20-50% slower" for Asyncify‑based longjmp **[V]** | slow (copies every frame's locals) | large | universal; still the only portable non‑local exit for engines without EH |
| **Snapshot/restore** (wazero experimental) | host‑side stack snapshot, used for WASIX setjmp/longjmp | none in code | host cost | none | wazero‑specific **[V]** |

Comment on V8 performance **[PK]**: V8 implements wasm exceptions as heap objects and reuses its JS exception‑handler tables, so `try_table` costs nothing on the non‑throwing path in TurboFan; Liftoff spills across protected calls. Throwing is a full unwind with handler‑table lookup per frame, comparable to JS `throw`. I did not find a public V8 design document for exnref to cite **[?]**. Two known cost centres are (a) stack‑trace capture — the JS API's `traceStack` option exists precisely because capturing traces is expensive, and the CG discussed "Inefficiency Due to Eager Stack Tracing" (https://github.com/WebAssembly/exception-handling/issues/102) **[V]**; and (b) allocation per throw (both V8 **[PK]** and Wasmtime **[V]**).

Design pattern for "panic = trap, errors = values": emit `unreachable` (or an imported `abort` host call followed by `unreachable`) for unrecoverable failures; lower fallible operations to multi‑value returns `(result T i32)` or a tagged `Result` in memory/GC struct; reserve Wasm EH for genuinely non‑local control flow. This is exactly the split Rust (`panic=abort`), Go and Zig ship today **[V]**.

---

## 5. Interaction with other proposals

- **JSPI** (`WebAssembly.promising` / `WebAssembly.Suspending`): now **Phase 5** in the proposals index (https://github.com/WebAssembly/proposals) **[V]**; shipped in Chrome 137 and Firefox 139 per V8's blog (https://v8.dev/blog/jspi) **[V]** (features.json still says Firefox is behind a flag **[?]**). Semantics: when the awaited promise rejects, the rejection is thrown into the suspended wasm at the suspension point as a `JSTag` exception, so `try_table (catch JSTag)` around the suspending import works; if wasm throws after resumption, the `promising` export's promise is rejected with the exception (https://github.com/WebAssembly/js-promise-integration/blob/main/proposals/js-promise-integration/Overview.md) **[V]**. Traps also reject the promise **[V]**.
- **Stack switching** (core continuations): **Phase 3** **[V]**. `resume_throw tag` and `resume_throw_ref` (exnref operand) abort a suspended continuation by raising an exception at its suspension point; a `try_table` around `resume` catches exceptions escaping the continuation (https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Explainer.md) **[V]**. Wasmtime's `wasm_stack_switching` is `false` by default and "depends on function_reference_types and exceptions" **[V]**. Exceptions do not cross a *suspended* continuation: a suspended stack has no active handlers until resumed; propagation is along the resumer chain **[inference from explainer]**.
- **GC**: `exnref` is a reference type in the same universe of `ref` types, with its own `exn`/`noexn` hierarchy; Wasmtime's implementation makes `ExnRef` a GC‑managed object and therefore **requires the GC heap when EH is enabled** (`gc` cargo feature) **[V]**. Payloads can be GC references, so a language can throw a `(ref $MyError)` directly.
- **Component model / WASI**: there is **no exception concept** at the component level. Component‑model Async adds `error-context` (`error-context.new`, `.debug-message`, `.drop`) as an opaque value with a debug message, "included in every result's error case" for streams/futures (https://github.com/WebAssembly/component-model/blob/main/design/mvp/Explainer.md) **[V]**; WASI 0.3 (released 2026‑06‑11) uses `result<_, error-code>` plus `future`/`stream` (https://wasi.dev/releases/wasi-p3) **[V]**. Wasmtime 47 converts unhandled core exceptions at component boundaries into traps **[V]**. Practical meaning: exceptions are a *within‑component* implementation detail; every WIT boundary must be `result`‑shaped.
- **Tail calls**: Phase 5, widely shipped (Chrome 112, Firefox 121, Safari 18.2, Wasmtime 22, Wasmer 7.1, wazero flag) **[V]**; a `return_call` inside a `try_table` discards the handler (see §1.2) **[inference]**.

---

## 6. Debugging

- **DWARF in wasm**: `.debug_*` custom sections embedded in the module, or an `external_debug_info` custom section pointing at a separate file; source maps via a `sourceMappingURL` custom section (https://github.com/WebAssembly/tool-conventions/blob/main/Debugging.md) **[V]**. Chrome DevTools consumes DWARF (stepping, breakpoints, resolved stack traces) with no flags since Chrome 114 (https://developer.chrome.com/docs/devtools/wasm) **[V]**; "Pause on exceptions / caught exceptions" works for wasm exceptions in DevTools **[V]**. Firefox's debugger added exnref support (bug 1885589) **[V]**.
- **Stack traces through wasm exceptions**: only captured if the exception was created from JS with `{traceStack: true}` or when the engine chooses to; the `stack` property is `DOMString | undefined` **[V]**. Exceptions thrown by wasm `throw` do not carry a trace by default in the JS API; Emscripten's `-sEXCEPTION_STACK_TRACES` adds them **[V]**. Traps (`RuntimeError`) always carry a normal JS stack trace **[PK]**. Off‑web, Wasmtime attaches a `WasmBacktrace` to traps; for exceptions caught by the host it returns a `ThrownException` sentinel with the pending exception in the `Store` (https://bytecodealliance.org/articles/wasmtime-exceptions) **[V]**.
- A language implementer can emit its own trace: put a frame‑id list in the exception payload as it unwinds through `catch_all_ref` → append → `throw_ref`, at the cost of one handler per frame (this is what "eager stack tracing" would cost in the engine, issue #102) **[V/PK]**.

---

## 7. Implications for Ferlium (a new language emitting WASM with `wasm-encoder`)

1. **Emit the exnref form only; never the legacy form.** The legacy design is Inactive and rejected by new non‑browser engines (wazero errors out on legacy opcodes; wasmparser disables `LEGACY_EXCEPTIONS` by default) **[V]**. Every browser has shipped exnref since Chrome 137/Firefox 131/Safari 18.4; Baseline will be "widely available" on 2027‑11‑29 **[V]**. `wasm-encoder` has everything you need (`TryTable`, `Catch::*`, `Throw`, `ThrowRef`, `TagSection`, `EntityType::Tag`) **[V]**. You avoid LLVM's and Emscripten's still‑legacy defaults entirely because you are not going through them.

2. **Separate "panics" from "errors" at the language level and lower them differently.**
   - *Errors = values*: lower `Result`/`Option`‑style errors to plain multi‑value returns. This is the only representation that survives component/WIT boundaries (no exception concept there; Wasmtime traps on escaping exceptions) **[V]**, works on wasmi/WAMR/old engines, and is what your native backends will do anyway.
   - *Panics = trap by default*: `unreachable` after an imported `abort(msg_ptr, len)`; zero cost, universal. Offer a `panic=unwind` mode implemented with one exception tag per module (e.g. `$ferlium_panic (param (ref $PanicPayload))` or `(param i32 i32)`) so `catch_unwind`‑like constructs and resource cleanup can work when the engine supports EH. This mirrors Rust's abort/unwind split and its nightly‑only unwind status **[V]**.
   - *Language exceptions* (if Ferlium has them): use Wasm EH directly, Kotlin‑style, with a single tag whose payload is the exception object (GC ref or linear‑memory pointer). Do dispatch on the exception's *type* in your own code after `catch_ref`, not by multiplying tags: tag identity is dynamic per instance and imported tags alias, so engines cannot optimize handler lists anyway **[V]**. Use `catch_all_ref` + `throw_ref` for `finally`/destructor semantics; `throw_ref` on null traps, so never rethrow an uninitialised local.

3. **Remember what EH cannot catch.** Traps, stack overflow and OOM bypass `try_table` **[V]**. If Ferlium code is expected to survive deep recursion or OOB from unsafe code, that must be prevented statically or by explicit checks, not by a catch. wasm‑bindgen's experience: even with `panic=unwind`, `unreachable`/stack overflow/OOM permanently kill the instance, and unwinding out of an export must restore the shadow stack pointer (`__stack_pointer`) or you leak frames **[V]** — if you keep a shadow stack in linear memory, save/restore it at every handler.

4. **Host interop.** In browsers, catching `JSTag` lets Ferlium code observe JS errors thrown by imports; escaping Ferlium exceptions arrive as `WebAssembly.Exception` (`ex.is(tag)`, `ex.getArg(tag, 0)`) — export your panic/exception tags so the JS glue can decode them **[V]**. In Wasmtime, model errors as values across component boundaries; core `ExnRef`/`Tag` host APIs exist but require the `gc` feature and only work module‑to‑host, not component‑to‑component **[V]**.

5. **Async strategy.** For browser targets, prefer JSPI (Phase 5, Chrome 137/Firefox 139, Emscripten non‑experimental as of 6.0.8) over Asyncify (≈50% slowdown, big binaries) **[V]**; a rejected promise becomes a `JSTag` exception at the await point, so your `await` lowering can wrap the suspending import in `try_table (catch JSTag)` and convert to a language error value **[V]**. Off‑web, core stack switching is Phase 3 and off by default in Wasmtime; use it only as an experimental backend, and note it *requires* the exceptions feature **[V]**. Design your async runtime so that a suspended task holds no active handlers (they are not visible until resumed).

6. **Costs to budget for.** Happy path: zero on V8/Cranelift; Cranelift's `try_call` clobbers all registers at protected call sites, so avoid wrapping every call in a handler — coalesce handlers at function level where semantics allow **[V]**. Throw path: one allocation + per‑frame table lookups; do not use exceptions for hot control flow (iteration termination etc.). Disable trace capture unless in a debug build (`traceStack` / engine‑specific) **[V]**.

7. **Portability fallback.** Keep a codegen switch (`--no-eh`) that lowers panics to `unreachable` and language exceptions to an error‑value ABI, for wasmi, WAMR, older embedders and Go‑hosted wazero without the experimental flag. Because `try_table` is a plain block, a single Ferlium IR (with explicit `Throw`/`Try` nodes) can be lowered either way; Binaryen's `--translate-to-exnref` is the only cross‑flavour bridge and it goes one direction (legacy → exnref) **[V]**.

8. **Debugging.** Emit DWARF `.debug_*` custom sections (or `sourceMappingURL`) via `wasm-encoder`'s custom‑section support so DevTools/Wasmtime resolve frames; for panics, capture the trace in your own runtime before throwing (or rely on the trap's `RuntimeError` stack in abort mode), because engine‑side traces on wasm‑originated exceptions are not guaranteed **[V]**.

### Items I could not verify (summary)
Safari legacy version (15.2 vs 15.4); Chrome exnref 137 vs 138; the exact Node minor where exnref flipped on (24.15 per feature table and wasm‑bindgen, unconfirmed in Node's notes); whether the "exnref by default" in wasm‑bindgen 0.2.122 comes from rustc or from wasm‑bindgen; whether WAMR has landed the new‑spec implementation; wasm3 0.9.1 support; Bun's status; Wasm 3.0's formal W3C Recommendation status; V8‑internal EH implementation details; `exnref` legality as table element type; explicit spec wording on `return_call` inside `try_table`.

### Key sources
- Wasm 3.0 announcement: https://webassembly.org/news/2025-09-17-wasm-3.0/
- EH explainer (final): https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md ; spec branch: https://github.com/WebAssembly/spec/blob/wasm-3.0/proposals/exception-handling/Exceptions.md
- JS API: https://webassembly.github.io/exception-handling/js-api/ ; MDN: https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/Exception_handling/try_table
- Feature table: https://webassembly.org/features/ (data: https://raw.githubusercontent.com/WebAssembly/website/main/features.json) ; browser dates: https://web-platform-dx.github.io/web-features-explorer/features/wasm-exnref-exceptions/
- Proposal phases: https://github.com/WebAssembly/proposals
- Wasmtime: https://github.com/bytecodealliance/wasmtime/releases/tag/v37.0.0 , https://github.com/bytecodealliance/wasmtime/releases/tag/v47.0.0 , https://bytecodealliance.org/articles/wasmtime-exceptions , https://bytecodealliance.org/articles/wasmtime-gc , https://docs.wasmtime.dev/api/wasmtime/struct.Config.html
- Wasmer 6.0: https://wasmer.io/posts/announcing-wasmer-6-closer-to-native-speeds ; WasmEdge: https://github.com/WasmEdge/WasmEdge/blob/master/Changelog.md ; wazero: https://github.com/tetratelabs/wazero/pull/2489 ; WAMR: https://github.com/bytecodealliance/wasm-micro-runtime/issues/3753 ; wasmi: https://github.com/wasmi-labs/wasmi/issues/1137
- LLVM: https://releases.llvm.org/21.1.0/docs/ReleaseNotes.html , https://github.com/llvm/llvm-project/pull/122158 , https://raw.githubusercontent.com/llvm/llvm-project/main/llvm/lib/Target/WebAssembly/WebAssemblyTargetMachine.cpp
- Emscripten: https://emscripten.org/docs/porting/exceptions.html , https://emscripten.org/docs/porting/setjmp-longjmp.html , https://emscripten.org/docs/porting/asyncify.html , https://emscripten.org/docs/tools_reference/settings_reference.html , https://github.com/emscripten-core/emscripten/blob/main/ChangeLog.md
- Binaryen: https://github.com/WebAssembly/binaryen/blob/main/src/passes/TranslateEH.cpp
- wasm-encoder / wasmparser: https://docs.rs/wasm-encoder/latest/wasm_encoder/enum.Instruction.html , https://docs.rs/wasm-encoder/latest/wasm_encoder/enum.Catch.html , https://docs.rs/wasm-encoder/latest/wasm_encoder/struct.TagSection.html , https://docs.rs/wasmparser/latest/wasmparser/struct.WasmFeatures.html
- Rust: https://github.com/rust-lang/rust/issues/118168 , https://doc.rust-lang.org/nightly/rustc/platform-support/wasm32-unknown-unknown.html , https://github.com/rust-lang/rust/pull/147169 , https://github.com/rust-lang/rust/pull/156928 , https://wasm-bindgen.github.io/wasm-bindgen/reference/catch-unwind.html , https://github.com/wasm-bindgen/wasm-bindgen/releases , https://blog.cloudflare.com/making-rust-workers-reliable/
- Kotlin: https://kotlinlang.org/docs/wasm-configuration.html ; .NET: https://github.com/dotnet/runtimelab/issues/1983 ; Go: https://github.com/golang/go/issues/65199
- JSPI: https://github.com/WebAssembly/js-promise-integration/blob/main/proposals/js-promise-integration/Overview.md , https://v8.dev/blog/jspi ; stack switching: https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Explainer.md
- Component model / WASI: https://github.com/WebAssembly/component-model/blob/main/design/mvp/Explainer.md , https://wasi.dev/releases/wasi-p3
- Debugging: https://github.com/WebAssembly/tool-conventions/blob/main/Debugging.md , https://developer.chrome.com/docs/devtools/wasm , https://github.com/WebAssembly/exception-handling/issues/102