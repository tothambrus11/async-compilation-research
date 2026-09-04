# How Swift Compiles Async Functions: Calling Convention, Cancellation, Errors, and Runtime Structure

Research memo, 2026-09-04. Sources were fetched directly (Swift/LLVM `main` branches, Swift Evolution, forums, WWDC transcript). Each claim is tagged:

- **[V]** verified against the cited primary source during this research
- **[PK]** prior knowledge, consistent with sources but not directly re-verified
- **[?]** could not verify; treat with caution

---

## 1. The async calling convention and ABI

### 1.1 Registers

Swift's `docs/ABI/CallingConventionSummary.rst` gives the register assignment **[V]**:

| Register role | x86-64 | ARM64 |
|---|---|---|
| Async context | `r14` | `x22` |
| Error return (`swifterror`) | `r12` | `x21` |
| `self` (`swiftself`) | `r13` | `x20` |

Source: https://github.com/swiftlang/swift/blob/main/docs/ABI/CallingConventionSummary.rst (the older `RegisterUsage.md` now just redirects there **[V]**). All three are callee-saved registers in the base C ABI, which is deliberate: they survive across ordinary C calls, so Swift can leave them live around calls into C without spilling. The table only claims macOS/iOS; other targets (RISC-V, Wasm, 32-bit ARM) follow the LLVM target's `swiftcc` implementation and Wasm has no such register **[PK]**.

In LLVM IR these are parameter attributes, not registers. LangRef **[V]** (https://llvm.org/docs/LangRef.html):

- `swiftasync`: "This indicates that the parameter is the asynchronous context parameter and triggers the creation of a target-specific extended frame record to store this pointer."
- `swifterror`: "can be applied to a parameter with pointer-to-pointer type or a pointer-sized alloca ... These constraints allow the calling convention to optimize access to swifterror variables by associating them with a specific register at call boundaries rather than placing them in memory. ... a function which uses the swifterror attribute on a parameter is not ABI-compatible with one which does not."
- `swifttailcc`: "like swiftcc in most respects, but also the callee pops the argument area of the stack so that mandatory tail calls are possible as in tailcc." For `musttail`, "if the calling convention is swifttailcc or tailcc: Only these ABI-impacting attributes are allowed: sret, byval, swiftself, and swiftasync. Prototypes are not required to match."

The Clang-level `swiftasynccall` attribute maps to LLVM `swifttailcc` + a `swiftasync` parameter; the Clang docs note swiftasynccall functions always return void **[V]** (https://www.mail-archive.com/cfe-commits@lists.llvm.org/msg419025.html; https://reviews.llvm.org/D95443). Swift's own IRGen emits async functions with `swifttailcc` and the `SWIFT_CC(swiftasync)` macro expands to `__attribute__((swiftasynccall))` in the runtime **[V]** (`include/swift/Runtime/Config.h`).

### 1.2 The `AsyncContext`

`include/swift/ABI/Task.h` **[V]** (https://github.com/swiftlang/swift/blob/main/include/swift/ABI/Task.h):

```cpp
/// An asynchronous context within a task.  Generally contexts are
/// allocated using the task-local stack alloc/dealloc operations, but
/// there's no guarantee of that, and the ABI is designed to permit
/// contexts to be allocated within their caller's frame.
class alignas(MaximumAlignment) AsyncContext {
public:
  AsyncContext * __ptrauth_swift_async_context_parent Parent;
  TaskContinuationFunction * __ptrauth_swift_async_context_resume ResumeParent;
  ...
  SWIFT_CC(swiftasync) void resumeParent() { return ResumeParent(Parent); }
};
```

Notes:
- The header today has exactly two fixed words: `Parent` and `ResumeParent`. The older `Flags` and `ResumeParentExecutor` fields that appeared in 2021 sources are gone from the ABI header **[V]**; the comment "arguments are always written into the context, and so the type is always the same" survives. So the widely-repeated "parent, resume, flags" layout is stale.
- Subclasses: `YieldingAsyncContext` adds `YieldToParent` (for async coroutines with yields); `ContinuationAsyncContext` (used by `withUnsafeContinuation`) adds `Flags` (CanThrow, IsExecutorSwitchForced), `std::atomic<ContinuationStatus> AwaitSynchronization`, `SwiftError *ErrorResult`, `OpaqueValue *NormalResult`, `SerialExecutorRef ResumeToExecutor` **[V]**.
- Everything after the header is the function's spilled frame (see 2.2). `MaximumAlignment` is 16 **[PK]**.
- On arm64e the two words carry distinct pointer-auth discriminators: `AsyncContextParent = 0xbda2`, `AsyncContextResume = 0xd707`, `AsyncContextYield = 0xe207`, plus `TaskResumeFunction = 0x2c42`, `TaskResumeContext = 0x753a` for the fields in `AsyncTask` **[V]** (`include/swift/ABI/MetadataValues.h`). IRGen signs the parent pointer with the `AsyncContextParent` schema when storing it and signs the resume function with `AsyncContextResume` before saving it into the callee's context; `emitAsyncReturn` authenticates `ResumeParent` before tail-calling it **[V]** (`lib/IRGen/GenCall.cpp`).

The runtime places a small prefix *before* the first context of a task: `AsyncContextPrefix { asyncEntryPoint; closureContext; SwiftError *errorResult; }` (3 words) and, for tasks with a future, `FutureAsyncContextPrefix` (4 words, adds `OpaqueValue *indirectResult`) **[V]** (`Task.h` lines ~1183-1200; `Task.cpp` asserts `sizeof(AsyncContextPrefix) == 3 * sizeof(void *)`). This is the adapter between the compiler's convention (closure context passed directly) and the runtime's `ResumeTask` interface.

### 1.3 Async function pointers

An async function is not referenced by a code address but by an `AsyncFunctionPointer` **[V]** (`include/swift/ABI/Executor.h`):

```cpp
template <class AsyncSignature>
class AsyncFunctionPointer {
public:
  /// The function to run.
  TargetCompactFunctionPointer<InProcess, AsyncFunctionType<AsyncSignature>, false, int32_t> Function;
  /// The expected size of the context.
  uint32_t ExpectedContextSize;
};
```

i.e. a 32-bit relative pointer to the entry ("ramp") function plus the byte size of the context frame the callee needs. LLVM documents the same shape ("`struct async_function_pointer { uint32_t relative_function_pointer_to_async_impl; uint32_t context_size; }`") and states: "The frontend is responsible for allocating the memory for the async context but can use the async function pointer struct to obtain the required size" and "Lowering will update the size entry with the coroutine frame requirements" **[V]** (https://llvm.org/docs/Coroutines.html, Async Lowering). The symbol emitted for a function `f` is `f`'s mangled name with a `Tu` suffix ("async function pointer") **[PK]**.

**Why the pair?** Because the *caller* allocates the callee's frame. The frame size is only known after LLVM's CoroSplit has computed the spill set, so it cannot be a compile-time constant at the call site (it may even live in a different module or be resilient). IRGen's call emission **[V]** (`GenCall.cpp`, `emitIndirectAsyncFunctionPointer` / call setup around lines 3150-3210) loads the function address and `ExpectedContextSize` from the AFP; if the size folds to a constant it uses a static allocation, otherwise `emitAllocAsyncContext` calls `swift_task_alloc`. The `TargetMethodDescriptor` for async class methods stores an `AsyncImpl` relative pointer to such a struct, so vtables and witness tables dispatch through AFPs too **[V]** (`Metadata.h`). A low bit on an AFP pointer marks "indirect AFP" for some platforms (`IndirectAsyncFunctionPointer` option) **[V]**.

### 1.4 The call sequence

Caller side, per call **[V]** (GenCall.cpp `setArgs` for async callees, ~line 3395):
1. Allocate callee context (`swift_task_alloc(size)` from the task allocator, or in-frame when static).
2. Store `Parent = current context` (signed on arm64e).
3. Store `ResumeParent = llvm.coro.async.resume()` — the address of *this function's* next partial function.
4. Issue `llvm.coro.suspend.async(...)` whose "suspend function" tail-calls the callee's ramp with the new context in the context register.
5. On resume, the partial function receives results as *arguments* (see 2.2) and the caller calls `swift_task_dealloc` on the callee context.

Callee return, `emitAsyncReturn` **[V]** (GenCall.cpp ~6664): load `ResumeParent` from own context, authenticate it, build `coro.end.async(handle, /*unwind*/false, mustTailCallFn, fnPtr, ctx, results...)`, then `unreachable` — "If target doesn't support musttail (e.g. WebAssembly), the function passed to coro.end.async can return control back to the caller. So use ret void instead of unreachable to allow it." Note the comment in `AsyncContext::resumeParent`: "FIXME: force tail call" — the runtime's C++ side relies on the compiler's tail-call behavior.

---

## 2. The compilation pipeline

### 2.1 SIL

Async is a function-type attribute (`@async`). Calls use ordinary `apply` / `try_apply` (the SIL `begin_apply` instruction is for `@yield_once` coroutines such as `_read`/`_modify` accessors, not for async calls — async functions with yields are a separate, newer feature) **[V]/[PK]** (https://github.com/swiftlang/swift/blob/main/docs/SIL/Instructions.md). Async-specific SIL instructions **[V]**:

- `hop_to_executor %0 : $T` — "Ensures that all instructions, which need to run on the actor's executor actually run on that executor. This instruction can only be used inside an @async function." `T` is `Builtin.Executor` or an `Actor`.
- `extract_executor` — pulls the `Builtin.Executor` out of an actor.
- `get_async_continuation [throws]? $T` / `get_async_continuation_addr` — "Begins a suspension of an @async function"; yields an `UnsafeContinuation<T>` (or `UnsafeThrowingContinuation`). "Between get_async_continuation and await_async_continuation ... The function cannot return, throw, yield, or unwind."
- `await_async_continuation %c, resume bb1, error bb2` — the suspension point; the error block receives the thrown error for throwing continuations **[PK]** for the exact operand syntax.
- Builtins `startAsyncLet(WithLocalBuffer)`, `endAsyncLet(Lifetime)`, `createAsyncTask`, `withUnsafeContinuation`, `taskAddCancellationHandler` etc. lower to runtime calls **[V]** (visible in `TaskSleep.swift`, `TaskCancellation.swift`).

### 2.2 LLVM async lowering

Swift IRGen emits every `async` SIL function as an LLVM coroutine using the **async lowering** (`llvm.coro.id.async`). The LLVM Coroutines doc **[V]** (https://llvm.org/docs/Coroutines.html#async-lowering):

> "In async-continuation lowering, signaled by the use of `llvm.coro.id.async`, handling of control-flow must be handled explicitly by the frontend. In this lowering, a coroutine is assumed to take the current `async context` as one of its arguments ... It is used to marshal arguments and return values of the coroutine. Therefore, an async coroutine returns `void`."

> "Values live across a suspend point need to be stored in the coroutine frame to be available in the continuation function. This frame is stored as a tail to the `async context`."

> "Lowering will split an async coroutine into a ramp function and one resume function per suspend point."

> "The suspend point takes a function and its arguments. The function is intended to model the transfer to the callee function. It will be tail called by lowering and therefore must have the same signature and calling convention as the async coroutine."

Intrinsics used **[V]**: `llvm.coro.id.async(size, align, ctx-arg-index, afp)`, `llvm.coro.suspend.async(resume, ctx-projection, transfer-fn, args...)`, `llvm.coro.async.resume()`, `llvm.coro.end.async(handle, unwind, must-tail-fn, args...)`, `llvm.coro.prepare.async` (blocks inlining of async coroutines until after splitting), `llvm.coro.async.size.replace`, and `llvm.coro.async.context.alloc/dealloc` for the yield-once-async path. Swift IRGen calls `coro_suspend_async` at every `await` (GenCall.cpp line 257) **[V]**.

The result: each Swift async function becomes N+1 LLVM functions ("partial functions" / "funclets"; the runtime calls them `TaskContinuationFunction`s). The value returned by `llvm.coro.suspend.async` is a struct of the resumed context plus the callee's result registers — `emitCallToUnmappedExplosion` reads results from "suspendResultTy->element_begin() + numAsyncContextParams" **[V]**. In other words, *return values of async functions travel as arguments of the caller's resume function*, not in memory, except when the native schema requires indirection.

### 2.3 Consequences: no stack switching, no stack growth

Because every transfer — call, return, hop, resume — is a `musttail` call with `swifttailcc`, the native stack is at the same depth after the transfer as before it. When an async function suspends (e.g. it enqueues itself and returns to the executor loop), the native stack unwinds completely back to the executor. Nothing on the machine stack outlives an `await`; all state is in the linked list of async contexts. WWDC21 "Swift concurrency: Behind the scenes" states it from the runtime's view **[V]** (https://developer.apple.com/videos/play/wwdc2021/10254/): "Since all information that is maintained across a suspension point is stored on the heap, it can be used to continue execution at a later stage. This list of async frames is the runtime representation of a continuation." And: "When threads execute work under Swift concurrency they switch between continuations instead of performing a full thread context switch."

SE-0296 frames the same design at the language level **[V]** (https://github.com/swiftlang/swift-evolution/blob/main/proposals/0296-async-await.md): "asynchronous functions are able to completely give up that stack and use their own, separate storage", and it explicitly notes the ABI consequence: "The ABI for an async function is completely different from the ABI for a synchronous function ... so the addition or removal of async from a function or type is not a resilient change."

### 2.4 Async backtraces and the extended frame record

The debugger/backtracer needs to walk the *async* chain, not the machine stack. LLVM's `swiftasync` attribute "triggers the creation of a target-specific extended frame record to store this pointer" **[V]**. Concretely:

- AArch64: "Swift's async context is directly before FP, so allocate an extra 8 bytes for it" and "A Swift asynchronous context extends the frame record with a pointer directly before FP" **[V]** (`AArch64FrameLowering.cpp`). So the frame record is `[async ctx][saved fp][saved lr]`, with FP pointing at the saved fp.
- x86-64: in `SwiftAsyncFramePointerMode::Always` the prologue emits `BTS64ri8 rbp, 60` — sets bit 60 of the saved frame pointer — and asserts "win64 prologue does not set the bit 60 in the saved frame pointer" **[V]** (`X86FrameLowering.cpp`). In the dynamic mode it ORs the frame pointer with the runtime symbol `swift_async_extendedFramePointerFlags` loaded through the GOT **[V]**.
- The runtime defines that symbol as `0x1000000000000000` (bit 60) on 64-bit Apple platforms, `0x10000000` on arm64_32, and `0x0` otherwise / for back-deployment **[V]** (`stdlib/public/Concurrency/Task.cpp` lines 60-88). The dynamic scheme exists so that binaries compiled with the flag can run on OSes whose unwinders don't understand the bit (old OS: flag resolves to 0) **[PK]**.
- Unwinders (lldb, Swift 5.9's built-in backtracer) detect the bit, read the context pointer from the slot next to the saved FP, then follow `Parent` links, using each context's `ResumeParent` to symbolicate the "caller" **[PK]**; lldb's Windows x86-64 port discussion confirms "LLDB currently has special extended frame support for Swift async frames for x86_64 and arm64" using the `fp - 8` slot **[V]** (https://forums.swift.org/t/lldb-support-for-swift-async-frames-for-windows-x86-64/69799). The Swift 5.9 backtracer is "concurrency-aware and will correctly step back through asynchronous frames", and on non-Apple platforms needs symbols "to determine whether or not a given frame is asynchronous" (no reserved FP bit there) **[V]** (https://www.swift.org/blog/swift-5.9-backtraces/).
- On arm64e, the `Parent`/`ResumeParent` fields are PAC-signed with the discriminators above, and the AFP itself is authenticated before use (`ptrauth_auth_data` in `Task.cpp` line ~1303) **[V]**.

Original design talk: McCall & Schwaighofer, "Async Functions in Swift", LLVM Dev Meeting 2021 (https://llvm.org/devmtg/2021-11/slides/2021-AsyncFunctionsInSwift.pdf) — the PDF could not be text-extracted in this session **[?]**, but the LLVM docs above were written by the same authors.

---

## 3. Executors and scheduling

### 3.1 Jobs, executors, protocols

`Job` is a `HeapObject` with `JobFlags` (kind + priority) and either `RunJob` or `ResumeTask`; "Schedulers may assume the memory location of the Flags in order to avoid a runtime call" **[V]** (`Task.h`). `AsyncTask` is a `Job` with `ResumeContext`/`ResumeTask` (the pointer to the context and partial function to resume) and optional trailing fragments: Child, GroupChild, Future, Name **[V]**.

SE-0392 (Swift 5.9) exposes this as `Executor`, `SerialExecutor` (mutual exclusion + happens-before ordering between jobs), `ExecutorJob` (move-only), `UnownedJob`, `UnownedSerialExecutor` with `init(ordinary:)` (pointer identity) and `init(complexEquality:)` + `isSameExclusiveExecutionContext(other:)`; actors expose `unownedExecutor`, which "must always evaluate to the same executor for a given actor instance" **[V]** (https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md). SE-0424 adds `checkIsolated()`/`isIsolatingCurrentContext()` so custom executors can answer `assumeIsolated` checks **[V]** (runtime: `swift_task_invokeSwiftCheckIsolated`, `IsIsolatingCurrentContextDecision {Unknown=-1, NotIsolated=0, Isolated=1}` in `GlobalExecutor.cpp`).

### 3.2 The global executor and its hooks

The runtime funnels all non-actor work through `swift_task_enqueueGlobal(Job*)`. The C++ implementation is selected at build time; each backend must define **[V]** (`DispatchGlobalExecutor.cpp`, `CooperativeGlobalExecutor.cpp` headers):

```
swift_task_asyncMainDrainQueueImpl, swift_task_checkIsolatedImpl,
swift_task_donateThreadToGlobalExecutorUntilImpl, swift_task_enqueueGlobalImpl,
swift_task_enqueueGlobalWithDeadlineImpl, swift_task_enqueueGlobalWithDelayImpl,
swift_task_enqueueMainExecutorImpl, swift_task_getMainExecutorImpl, swift_task_isMainExecutorImpl
```

`ExecutorImpl.h` "Contains the declarations you need to write a custom global executor in plain C" **[V]**.

- **Dispatch backend** (Apple, Linux, Windows): enqueues via `dispatch_async_swift_job` when libdispatch exports it, else `dispatch_async_f`; on non-Apple/back-deploy it creates "Swift global concurrent queue" with `dispatch_queue_set_width(newQueue, DISPATCH_QUEUE_WIDTH_MAX_LOGICAL_CPUS)` **[V]**. WWDC21: "The new thread pool will only spawn as many threads as there are CPU cores ... with Swift threads can always make forward progress" and "the language allows us to uphold a runtime contract that threads will always be able to make forward progress" **[V]**.
- **Cooperative backend**: a single-threaded priority queue (`PriorityQueue<SwiftJob*>` with 5 priority buckets) drained by `swift_task_asyncMainDrainQueue`; used for WASI and other no-Dispatch targets **[V]** (`CooperativeGlobalExecutor.cpp`). SwiftWasm documents it as "a simple single-threaded cooperative task executor" that "won't yield control to the host environment during execution" **[V]** (https://book.swiftwasm.org/getting-started/concurrency.html).
- **Hooks**: `ConcurrencyHooks.def` declares function-pointer hooks `swift_task_enqueueGlobal_hook`, `swift_task_enqueueGlobalWithDelay_hook`, `swift_task_enqueueGlobalWithDeadline_hook`, `swift_task_enqueueMainExecutor_hook`, `swift_task_getMainExecutor_hook`, `swift_task_isMainExecutor_hook`, `swift_task_checkIsolated_hook`, `swift_task_isIsolatingCurrentContext_hook`, `swift_task_isOnExecutor_hook`, `swift_task_donateThreadToGlobalExecutorUntil_hook` **[V]**. Each hook receives the `original` implementation as its last argument. SwiftWasm's `JavaScriptEventLoop.installGlobalExecutor()` installs these to route jobs through the JS microtask/`setTimeout` machinery **[V]** (https://github.com/swiftwasm/JavaScriptKit/blob/main/Sources/JavaScriptEventLoop/JavaScriptEventLoop.swift; https://forums.swift.org/t/global-executor-hooks-swiftnio/67600). The hooks are "unofficial but long-stable" **[V]** (https://forums.swift.org/t/strange-behavior-with-swift-task-enqueueglobal-hook/87528).
- **Custom Main and Global Executors**: still a *pitch* (Pitch 4, Aug 2026, https://forums.swift.org/t/pitch-4-custom-main-and-global-executors/89107; SE PR #2654). It proposes `ExecutorFactory` (static `mainExecutor: any MainExecutor`, `defaultExecutor: any TaskExecutor`), `MainExecutor`, `ThreadDonationExecutor`, keeps the C hooks as a migration path, and Doug Gregor raised Embedded-Swift concerns about existential indirection **[V]**. The delayed-enqueue part was split into **SE-0505 "Delayed Enqueuing for Executors"** (`SchedulingExecutor`, `enqueue(_:after:tolerance:clock:)`), currently "Returned for revision" **[V]** (https://github.com/swiftlang/swift-evolution/blob/main/proposals/0505-delayed-enqueuing.md). The stdlib on `main` already consults `Task.currentSchedulingExecutor` in `Task.sleep` gated on `StdlibDeploymentTarget 6.3` **[V]** (`TaskSleep.swift`). There is **no SE-0472/SE-0491 for this**: SE-0472 is "Starting tasks synchronously from caller context" (`Task.immediate`, Swift 6.2) **[V]**, and SE-0491 is "Module selectors" **[V]** (proposal filename list).

### 3.3 Hopping: `swift_task_switch`

`hop_to_executor` lowers to a call to `swift_task_switch(resumeContext, resumeFunction, newExecutor)` **[PK]**, whose implementation **[V]** (`Actor.cpp`, `swift_task_switchImpl`):

1. Read the current executor from thread-local `ExecutorTrackingInfo`; read the task's preferred `TaskExecutor`.
2. If `!mustSwitchToRun(current, new, currentTaskExec, newTaskExec)`: "we can just immediately continue running with the resume function we were passed in" — `return resumeFunction(resumeContext); // 'return' forces tail call`. Same-executor hops are therefore free.
3. Otherwise park: `task->ResumeContext = resumeContext; task->ResumeTask = resumeFunction;`.
4. If the current executor "can give up its thread" (a default actor or the generic executor) and the target actor is free (`tryAssumeThreadForSwitch`), the *same thread* takes the new actor's lock and runs the task (`runOnAssumedThread`) — no enqueue. (A build option `SWIFT_CONCURRENCY_ACTORS_AS_LOCKS` makes this always succeed **[V]**, visible on `main`.)
5. Else `enqueue` the task on the new executor and return to the executor loop.

WWDC21 describes this "thread reuse": "When you call a method on an actor that is not running, the calling thread can be reused to execute the method call. In the case where the called actor is already running, the calling thread can suspend the function it is executing and pick up other work" **[V]**.

Which executor an `await` targets is a language rule: SE-0338 made nonisolated async functions run on the generic executor; SE-0461 (Swift 6.2) reverses this under the `NonisolatedNonsendingByDefault` upcoming feature: `nonisolated(nonsending)` functions "will always run on the caller's actor" while `@concurrent` functions "always switch off of an actor to run" **[V]** (https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md). SIL carries this as `callee_isolation`/`caller_isolation` apply attributes and an implicit isolated parameter **[V]**.

### 3.4 Task executor preference (SE-0417)

`TaskExecutor: Executor` provides *threads*, while `SerialExecutor` provides *isolation*. `withTaskExecutorPreference(exec) { }` stores the preference as a status record (`TaskExecutorPreference` record kind; `HasTaskExecutorPreference` bit in `ActiveTaskStatus`) **[V]**; child tasks (`addTask`, `async let`) inherit it, unstructured tasks do not; default actors' isolated code runs on the preferred executor's thread while the actor still guarantees exclusion **[V]** (https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md). `swift_task_switch` consults both (`getPreferredTaskExecutor()`) **[V]**. The task-to-thread build (`SWIFT_STDLIB_TASK_TO_THREAD_MODEL_CONCURRENCY`) is a separate, mostly-Apple-internal configuration where each task owns a thread; `Task.sleep` is compiled out there **[V]** (`TaskSleep.swift` `#if !SWIFT_STDLIB_TASK_TO_THREAD_MODEL_CONCURRENCY`).

### 3.5 Priority and escalation

`ActiveTaskStatus` holds the task's current max priority (`PriorityMask 0xFF`) and `IsEscalated`; `swift_task_escalate` short-circuits when "the stored priority is already at least as high", escalates the running thread via dispatch lock overrides on Apple, and for suspended tasks propagates through `TaskDependencyStatusRecord` → `swift_executor_escalate` **[V]** (`TaskStatus.cpp`). SE-0304: "If a task is created with a task handle, and a higher-priority task waits for that task to complete, the priority of the task will be permanently increased" **[V]**. Actors reorder their queue by priority ("the runtime may choose to move the higher-priority item to the front of the queue") **[V]** WWDC21.

### 3.6 Structured concurrency shapes

- `Task {}` / `Task.detached {}` are unstructured; `Task {}` inherits priority, task-locals and actor isolation; detached inherits nothing **[V]** SE-0304.
- `withTaskGroup`/`withThrowingTaskGroup`: child tasks record themselves in the parent's `TaskGroup` status record; leaving the body waits for all children **[V]** (`TaskGroup.swift`).
- `async let` (SE-0317): the child task and its first slab are pre-allocated *inside the parent's async frame* — `Task.cpp` uses `asyncLet->getPreallocatedSpace()` when big enough, else `_swift_task_alloc_specific(parent, amountToAllocate + initialSlabSize)` **[V]**, so async-let children cost no malloc in the common case.
- Every task's first slab is 512 bytes (`initialSlabSize = 512`), and later slabs are sized to fit "into a 1024-byte malloc quantum" (`SlabCapacity = 1024 - 8 - slabHeaderSize`) **[V]** (`Task.cpp`, `TaskPrivate.h`).
- SE-0472 `Task.immediate` (Swift 6.2): "begins running immediately on the calling executor (and thread) without any scheduling delay" until "a real suspension happens" **[V]**.

---

## 4. Cancellation in depth

### 4.1 The model

SE-0304 **[V]** (https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md): "The effect of cancellation within the cancelled task is fully cooperative and synchronous. That is, cancellation has no effect at all unless something checks for cancellation." Cancellation never unwinds, never injects control flow, never interrupts a thread: it sets a bit and runs registered handlers. Consequences: you "can always look at a function and see the places where cancellation can occur"; libraries must poll (`Task.isCancelled`), throw (`try Task.checkCancellation()` → `CancellationError`), or register handlers.

### 4.2 Runtime data structure: `ActiveTaskStatus` + status records

Every task has a 16-byte (on 64-bit) atomic `ActiveTaskStatus` **[V]** (`TaskPrivate.h`): `uint32_t Flags`, a `dispatch_lock_t ExecutionLock` (thread identity for escalation), and `TaskStatusRecord *Record` — the head of an intrusive singly-linked list of records. Flag bits **[V]**: `IsCancelled 0x100`, `IsStatusRecordLocked 0x200`, `IsEscalated 0x400`, `IsRunning 0x800`, `IsDirectlyEnqueued 0x1000`, `IsComplete 0x2000`, `HasTaskDependency 0x4000`, `HasTaskExecutorPreference 0x8000`, `HasActiveTaskCancellationShield 0x10000`, `HasTaskCancellationScope 0x80000`, `HasDeadline 0x1000000`, `CancelReasonDeadlineExpired 0x2000000`. Record kinds: `ChildTask`, `TaskGroup`, `CancellationNotification`, `EscalationNotification`, `TaskDependency`, `TaskExecutorPreference`, `Deadline`, `TaskCancellationScope`, `CancellationShield` **[V]** (`TaskStatus.cpp`). Records are allocated with `swift_task_alloc` (LIFO) and pushed/popped in scope order.

**The status-record lock** is a bit in the atomic plus a real mutex behind it **[V]**: "We need to acquire the lock AND set the is-locked bit in the status so that other threads attempting lockless operations can atomically check whether another thread holds the lock." `addStatusRecord` tries a lock-free CAS push first ("We have to use a release on success to make the initialization of the new record visible"); if the lock bit is set it takes the lock. Removal of the innermost record is lock-free; anything else takes the lock. `withStatusRecordLock` spins on CAS to set the bit, and `swift_task_cancel` pairs `consume` with that `release`. (The user's phrase "spinning" is accurate for setting the bit; the lock body itself is a `RecursiveMutex statusLock` in `PrivateStorage` **[V]**.)

### 4.3 `swift_task_cancel`

Verbatim structure **[V]** (`TaskStatus.cpp`, `swift_task_cancelWithFlagsImpl`):

1. CAS loop: "Are we already cancelled? ... return" → **cancellation is idempotent**, and "first cancel wins on reason". `newStatus = oldStatus.withCancelled(reason)` — "the flag is set regardless" of whether the record lock is held.
2. If no records: return.
3. `withStatusRecordLock(task, ...) { for (auto cur : status.records()) performCancellationAction(newStatus, cur, reason); }` with the note "cancellation is happening from outside of the task so we know that no new records will be added since that's only possible while on task."

`performCancellationAction` **[V]**:
- `ChildTask`: `for (AsyncTask *child : childRecord->children()) swift_task_cancelWithFlags(child, reason);` — **structured propagation is recursive and eager**.
- `TaskGroup`: `_swift_taskGroup_cancel(group, reason)` — "we do not want to formally cancel the task group itself; that property is under the synchronous control of the task that owns the group."
- `CancellationNotification`: `notification->run(reason)` — **the handler closure runs synchronously on the cancelling thread, while the status lock is held**, unless a cancellation shield is active ("cancellation shielded: skip cancellation handler invocation").

### 4.4 `withTaskCancellationHandler`

Stdlib **[V]** (`TaskCancellation.swift`):

```swift
// unconditionally add the cancellation record to the task.
// if the task was already cancelled, it will be executed right away.
let record = unsafe Builtin.taskAddCancellationHandler(handler: handler)
defer { unsafe Builtin.taskRemoveCancellationHandler(record: record) }
return try await operation()
```

SE-0304: if the task is already cancelled, "the cancellation handler is invoked immediately, before the operation block is executed" **[V]**. The runtime's `addStatusRecord` takes a `shouldAddRecord` predicate evaluated under the CAS so the "already cancelled" check and the record push are atomic **[V]** (structure); that the runtime then invokes the handler inline when the predicate observes `IsCancelled` is **[PK]**. The doc comment warns: "This onCancel closure might execute concurrently with the operation." — the handler is the one place in Swift concurrency where user code runs on a foreign thread with no isolation, so it must be `Sendable`-safe and must not block; typical handlers flip an atomic or resume a continuation with `CancellationError`. Because handler and operation race, the canonical pattern is a small atomic state machine — exactly what `Task.sleep` does.

Newer (Swift 6.4/6.5, on `main`) additions **[V]**: `CancellationError.Reason` carried in the low 3 bits of cancel flags; `withTaskCancellationShield` (`HasActiveTaskCancellationShield`: "Cancellation shields do not prevent the task from becoming cancelled, but only prevent observing the" status); `TaskCancellationScope` records for cancelling a sub-scope without cancelling the task (walks records "innermost first; stop when we hit the scope itself"); and `Deadline` records. Some of these are not yet in a shipped release **[?]**.

### 4.5 `Task.sleep` as the model implementation

`TaskSleep.swift` **[V]**: state word ∈ {`notStarted`, `activeContinuation(ptr)`, `finished`, `cancelled`, `cancelledBeforeStarted`}, manipulated with `cmpxchg`. The body is `withTaskCancellationHandler { withUnsafeThrowingContinuation { ... } } onCancel: { onSleepCancel(token) }`: the sleeper CASes `notStarted → activeContinuation` and enqueues a delayed job; the wake job CASes `activeContinuation → finished` and resumes; the cancel handler CASes `activeContinuation → cancelled` and calls `continuation.resume(throwing: CancellationError())`, or `notStarted → cancelledBeforeStarted` so the sleep never parks. This is the reference for how library code should marry continuations, timers and cancellation: **cancellation completes the pending operation with an error; it does not abort the timer, and the timer job later sees `.cancelled` and just deallocates.**

### 4.6 Task groups and errors/cancellation

`withThrowingTaskGroup` **[V]** (`TaskGroup.swift`): `do { let result = try await body(&group); await group.awaitAllRemainingTasks(); ... } catch { group.cancelAll(); await group.awaitAllRemainingTasks(); ...; throw error }`. Doc comment: a child throwing "doesn't immediately cancel the other tasks in that group", only surfacing from `next()`; but "throwing out of the body of the withThrowingTaskGroup method does cancel" the rest. A cancelled group still accepts `addTask` (the child "is immediately canceled after creation"); use `addTaskUnlessCancelled` **[V]**. Even cancelled children are awaited: structured scopes never leak running work.

### 4.7 Task-local values (SE-0311)

Not status records. `AsyncTask::PrivateStorage` has a dedicated `TaskLocal::Storage Local` ("Currently one word") next to the `TaskAllocator` **[V]** (`TaskPrivate.h`). Bindings are `Item`s in a linked list allocated from the task allocator, pushed/popped by `withValue`; a child's list initially *points at its parent's list* (`initializeLinkParent`), so lookup walks up through parents, skipping empty tasks; detached tasks "cannot and will not inherit task-local values" **[V]** (https://github.com/swiftlang/swift-evolution/blob/main/proposals/0311-task-locals.md; `TaskLocal.cpp`). A thread-local `FallbackTaskLocalStorage` supports task-locals in synchronous code with no current task **[V]**.

---

## 5. Errors in async functions

### 5.1 Synchronous baseline

Swift has no unwinder. `throws` is a second return channel: the callee receives a `swifterror` pointer-sized slot bound to a register (`r12` / `x21`), writes the error box pointer into it, and returns normally; the caller tests the register for non-null **[V]** register table; LangRef `swifterror` semantics **[V]**. `fatalError`, failed preconditions and overflow checks compile to `ud2`/`brk` traps and terminate the process; Swift's crash backtracer, not a language unwind, produces the report **[V]** (Swift 5.9 backtrace blog, `swift_Concurrency_fatalError` uses in the runtime).

### 5.2 Async: the error is an argument of the continuation

In the async convention there is no return, so there is no error register at the return boundary. Instead **[V]** (`emitAsyncReturn`, GenCall.cpp ~6725-6815): the native result components are pushed into `nativeResultsStorage`, then `if (!error.empty()) nativeResultsStorage.push_back(error.claimNext());` — the error value is appended as the *last argument* of the tail call to `ResumeParent`. On the throw path the results are `undef` ("When we throw, we set the return values to undef"). IRGen comments: "For now we continue to store the error result in the context to be able to reuse non throwing functions" (`expandAsyncEntryType`) — i.e. the *entry* signature reserves a context slot so a non-throwing function can be substituted for a throwing one **[V]**. On the caller side the resume partial function's extra parameter is checked for null and branches to the `try_apply` error block **[PK]**.

The runtime's own adapters mirror this: `swift_task_future_wait_throwing` resumes waiters with `resumeFunction(callerContext, error)` (a `ThrowingTaskFutureWaitContinuationFunction`), and `AsyncContextPrefix::errorResult` / `FutureFragment::error` (`SwiftError *`) store the error of a completed task **[V]** (`Task.cpp`, `Task.h`).

### 5.3 Typed throws (SE-0413)

"The ABI between a function with an untyped throws and one that uses typed throws will be different, so that typed throws can benefit from knowing the precise type." **[V]** (https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md). IRGen **[V]** (`hasIndirectTypedErrorResultSlot`): a typed error is returned *directly* — combined with the normal result into one aggregate (`combineResultAndTypedErrorType`) — unless the result or error is indirect or `nativeError.shouldReturnTypedErrorIndirectly()`, in which case an extra opaque pointer parameter ("indirect typed error result slot") is added. `throws(Never)` is ABI-identical to non-throwing **[V]** SE-0413. In async functions the same rule applies to the resume-function arguments (`emitAsyncReturn` has the typed-error direct path first) **[V]**. Wasm cannot take the trailing indirect slot, hence thunks **[V]** (https://github.com/swiftlang/swift/pull/73162).

### 5.4 `try await` and `rethrows`

`await` must follow `try`: "If both await and a variant of try ... are applied to the same subexpression, await must follow the try" **[V]** SE-0296. `rethrows` composes unchanged; `reasync` was left as a future direction **[V]**.

### 5.5 Where an unstructured task's error goes

`Task<Success, Failure>`'s `FutureFragment` stores either the result (trailing storage, destroyed via the type's value witness) or `SwiftError *error`; `completeTaskImpl` stores `asyncContextPrefix->errorResult = error` and `completeFuture` moves it into the fragment and wakes waiters **[V]** (`Task.cpp`). `task.value` is `try await` over `swift_task_future_wait_throwing`; `task.result` wraps it in `Result` **[PK]**. A never-awaited error is simply dropped when the task is released.

---

## 6. Continuations bridging callbacks (SE-0300)

API contract **[V]** (https://github.com/swiftlang/swift-evolution/blob/main/proposals/0300-continuation.md): "exactly one resume method must be called exactly-once on every execution path"; unsafe double-resume "is undefined behavior"; never resuming leaves "the task ... suspended until the process ends"; "resume immediately returns control to the caller after transitioning the task out of its suspended state; the task itself does not actually resume execution until its executor reschedules it"; resume may legally happen before `with*Continuation` even returns.

Implementation **[V]**:
- `Builtin.withUnsafeContinuation` → SIL `get_async_continuation` + `await_async_continuation`; the compiler allocates a `ContinuationAsyncContext` in the current frame. `swift_continuation_init` sets `ResumeToExecutor` to the current executor and `AwaitSynchronization = Pending`.
- `swift_continuation_await` CASes `Pending → Awaited`; if it observes `Resumed` (the callback already fired) it tail-calls `context->ResumeParent(context)` without ever suspending; otherwise `_swift_task_clearCurrent()` and returns to the executor **[V]** (`Task.cpp`).
- `swift_continuation_resume` / `resumeThrowing` write `NormalResult`/`ErrorResult`, CAS `→ Resumed`; if the awaiter had already parked, `task->flagAsAndEnqueueOnExecutor(context->ResumeToExecutor)` — the task goes back to *its original executor*, not the resumer's thread **[V]**. "Throwing resumers must overwrite this with a non-null value" (`ErrorResult`) **[V]** `Task.h`.
- `CheckedContinuation` wraps the unsafe one in a `CheckedContinuationCanary` class whose `takeContinuation()` is atomic; a second resume hits `fatalError("SWIFT TASK CONTINUATION MISUSE: ... tried to resume its continuation more than once")` and the canary's deinit logs if never resumed **[V]** (`CheckedContinuation.swift`).

Cancellation does not touch continuations at all; the only link is user code combining `withTaskCancellationHandler` and a continuation with an atomic (4.5).

---

## 7. Memory model, design rationale, and comparison

### 7.1 The task allocator

`StackAllocator` **[V]** (https://github.com/swiftlang/swift/blob/main/stdlib/public/runtime/StackAllocator.h): "A bump-pointer allocator that obeys a stack discipline ... uses backing slabs of memory rather than relying on a boundless contiguous heap ... Allocations and deallocations must follow a strict stack discipline ... slabs which become unused are not freed, but reused ... It's possible to place the first slab into pre-allocated memory." `swift_task_alloc`/`swift_task_dealloc` (and `swift_job_alloc/dealloc` for executors) are thin wrappers **[V]**. The first slab sits in the task's own heap allocation (`headerSize + initialContextSize` + 512 bytes) **[V]**. Because async calls nest LIFO and every callee context is freed on return, the allocator behaves like a segmented stack per task; the *only* things that escape LIFO order are `Task {}` (its own allocation) and async-let children (placed in the parent's frame, freed by `endAsyncLet`).

### 7.2 Why "frames on a task allocator + tail calls" instead of stackful coroutines

- SE-0296: a synchronous caller "would treat it like a return and try to pick up where it was" if an async callee tried to give up part of the thread; blocking threads "would completely defeat the purpose of asynchronous functions, as well as having nasty systemic effects" **[V]**.
- WWDC21: the pool has one thread per core because threads never block; switching is "the cost of a function call" **[V]**. Stackful coroutines would need per-task contiguous stacks (memory pressure, stack-size guessing, cache pollution) and platform-specific context switching, and would break the "sync code calling async is impossible by construction" property.
- ABI/tooling: heap-linked contexts give a portable, unwinder-friendly representation (section 2.4), allow the *caller* to size and place the callee frame (even inline), and allow the runtime to write C++ adapters (`AsyncContextPrefix`) with the same convention **[V]**.
- Cost: every async call is an indirect load of a size + allocation + two stores; every return an indirect tail call. Mitigation: `coro.prepare.async` lets LLVM inline *after* splitting, and static context sizes fold to in-frame allocation **[V]**.
- The Swift Concurrency Manifesto (Lattner, 2017) anticipated the "no stack switching, compile to continuations" design (https://gist.github.com/lattner/31ed37682ef1576b16bca1432ea9f782) **[PK]**.

### 7.3 LLVM's three lowerings, precisely

From https://llvm.org/docs/Coroutines.html **[V]**:

| | Switched-resume (`coro.id`) | Returned-continuation (`coro.id.retcon[.once]`) | Async (`coro.id.async`) |
|---|---|---|---|
| Frame owner | "coroutine object" = handle; frame allocated by ramp (malloc, elidable) | fixed-size buffer supplied by caller; coroutine mallocs overflow | caller-allocated `async context`; frame "stored as a tail" of it |
| How you resume | `coro.resume(handle)` → jumps via index/switch into one resume fn | call the continuation *function pointer returned* from the previous suspend | call the resume fn; frontend threads control flow explicitly; transfers are tail calls |
| Return/yield values | via promise / user memory | yielded values returned with the continuation pointer; `.once` variant must suspend exactly once | marshalled as arguments through the context / continuation args |
| Destruction | separate `coro.destroy`; `coro.done` query | continuation takes an "abnormal" flag | none; frontend's runtime frees the context |
| Users | C++20 coroutines, Rust-like state machines in LLVM front ends | Swift `@yield_once` accessors (`_read`/`_modify`) | Swift `async` |

C++20 coroutines use switched-resume: one heap frame per coroutine (elidable by HALO when the frame's lifetime is provably nested), a `resume`/`destroy` function-pointer pair and a suspend-index in the frame, and the caller resumes by an indirect call that switches on that index **[PK]**. Rust compiles `async fn` into an anonymous generator/state-machine type in MIR (the frontend, not LLVM, does the splitting): all locals live across `.await` become enum-variant fields of a single value whose size is known statically, futures are inert until `poll`ed by an executor, and nested futures are *embedded* by value in their parent (so the whole task is one allocation when boxed) **[PK]** (https://rust-lang.github.io/async-book/). The key axes of difference:

- **Who owns and sizes the frame**: Rust = one statically-sized value nested by composition; Swift = per-call dynamically-sized contexts on a per-task stack allocator, sized via AFPs (dynamic dispatch, ABI-stable); C++ = per-coroutine heap frame with elision.
- **Control transfer**: Rust/C++ = the *caller* polls/resumes via an indirect call and the coroutine *returns* to it; Swift = *continuation-passing* — the callee tail-calls the caller's resume function; there is no "return to poller".
- **Cancellation**: Rust = drop the future (destructors run, no code after the await point executes); Swift = flag + handlers, the function keeps running to a normal exit; C++ = `destroy()` the handle (RAII), or library-level stop tokens.
- **Errors**: Rust = `Result` values through `poll`; Swift = error pointer argument in the resume call; C++ = exceptions through `unhandled_exception()` in the promise.

---

## 8. Embedded Swift and single-threaded runtimes

- Embedded Swift builds the concurrency runtime with `SWIFT_CONCURRENCY_EMBEDDED`; the stdlib sources carry many `#if $Embedded` cut-outs (e.g. deadline records are "non-embedded only"; the isolation-parameter overload of `withTaskCancellationHandler` is `#if !$Embedded`) **[V]**.
- The platform must supply a global executor by implementing the plain-C `ExecutorImpl.h` entry points (`swift_task_enqueueGlobalImpl`, `...WithDelayImpl`, `...MainExecutorImpl`, `swift_task_asyncMainDrainQueueImpl`, etc.) — "the global executor is expected to be statically linked with swift_Concurrency" **[V]**. The cooperative single-threaded executor is the default for Wasm ("cooperative single-threaded executor enabled by default"), and JavaScriptKit swaps it for the JS event loop **[V]** (https://forums.swift.org/t/swift-embedded-concurrency/74515; SwiftWasm book).
- Threading model: "Today, Embedded Swift defaults to NoThreads. That works well for single-core or cooperative environments, but it also means the Swift runtime assumes it is not being executed concurrently across multiple cores." A 2026 pitch adds an `EmbeddedPlatform.h` C hook surface (`_swift_mutex_*`, `_swift_tls_get/set`, thread identity, stack bounds) so RTOSes can provide multicore support **[V]** (https://forums.swift.org/t/exploring-multicore-concurrency-for-embedded-swift/87129; https://forums.swift.org/t/concurrency-aware-debugging-with-embedded-swift-platform-runtimes/89160).
- Swift 6.4: "The Embedded Swift concurrency library now supports throwing operations, such as throwing tasks and task groups" **[V]** (https://www.swift.org/blog/embedded-swift-improvements-coming-in-swift-6.4/).
- Custom main/global executors as a *Swift-level* API remain a pitch (3.2); for embedded, the C entry points/hooks are the supported mechanism today **[V]**.

---

## 9. Items I could not verify or that differ from the brief

- The LLVM 2021 slide deck's exact wording (PDF not text-extractable) **[?]**.
- Whether AArch64 sets bit 60 in the prologue via `orr x29, x29, #0x1000000000000000` — the x86-64 side is verified; the AArch64 file verified only the extra context slot before FP. The runtime flag value (bit 60 on 64-bit Apple) strongly implies the same bit **[PK]**.
- The brief said `AsyncContext` has a `Flags` word: current `main` has only `Parent` and `ResumeParent` **[V]**; flags exist only on `ContinuationAsyncContext`.
- The brief said task-locals are status records: they are a separate `TaskLocal::Storage` linked list in the task's private storage **[V]**.
- The brief's "SE-0472 / SE-0491 Custom Main and Global Executors": neither number matches; the feature is still a pitch (PR #2654) with SE-0505 split off **[V]**.
- Exact inline-invocation code of `swift_task_addCancellationHandler` for an already-cancelled task (behavior verified via SE-0304 and stdlib comments; C++ body not read) **[PK]**.
- `dispatch_async_swift_job` and the cooperative-queue width semantics inside libdispatch itself were not read (only the Swift side) **[PK]**.

---

## 10. Lessons for a new language

1. **Separate "what state survives a suspension" from "who owns the machine stack".** Swift's decision — the callee's frame is caller-allocated on a per-task LIFO allocator and *every* transfer is a guaranteed tail call — buys three things at once: no stack switching, a portable unwinder story (a linked list you can walk from any frame), and a runtime you can write in C. The price is an ABI split (`async` is not resilient) and an indirect load/alloc per call. If you want ABI-stable async across library boundaries, you need the `(function, context size)` pair or something equivalent.

2. **Make the frame-size problem a runtime datum, not a type.** Rust's static state-machine sizes are great for single-crate code and bad for dynamic dispatch and ABI stability; Swift's AFP `ExpectedContextSize` is the minimum viable escape hatch. Design the AFP from day one; retrofitting is painful.

3. **Guaranteed tail calls are the load-bearing primitive.** Swift needed a new LLVM calling convention (`swifttailcc`) and a new coroutine lowering just to get `musttail` everywhere, and Wasm still cannot guarantee it (IRGen falls back to `ret void`). A new language should either mandate tail-call support in its backend or accept a trampoline.

4. **Return results and errors as arguments to the continuation.** It keeps errors register-resident, keeps non-throwing and throwing functions substitutable (Swift reserves the slot either way), and needs no memory round-trip. Typed errors can be returned directly by merging with the result aggregate.

5. **Cancellation as a flag plus synchronous handlers is simple but leaks complexity into libraries.** Every primitive that parks (sleep, continuation, I/O) must implement the same three-way race (`notStarted/active/finished` vs `cancelled`) with atomics. If you adopt Swift's model, ship the state machine as a library primitive so authors don't reimplement `TaskSleep.swift`. Also note the handler runs on the cancelling thread under the task's status lock — document that it must be non-blocking and sendable, and consider running handlers *outside* the lock. Swift's newer shields/scopes/reasons show that a bare flag was not enough; plan for structured sub-scope cancellation early.

6. **Keep hop-to-executor a compiler-visible instruction.** `hop_to_executor` in SIL lets the optimizer delete redundant hops and lets the runtime run inline when the executor already matches (`swift_task_switch` fast path) or reuse the thread (`tryAssumeThreadForSwitch`). Making executor switches explicit IR is what makes actors cheap.

7. **Give the runtime a tiny, C-callable platform contract.** Swift's whole executor story reduces to ~10 entry points (`ExecutorImpl.h`) plus function-pointer hooks. That is why Wasm, WASI, and microcontrollers work with no compiler changes. Design that contract (enqueue, enqueue-with-delay, main executor, drain, is-isolated) up front and keep it free of your ABI headers.

8. **Structured concurrency needs records in the task, not only in the frame.** Child tasks, groups, executor preferences, deadlines, and cancellation handlers all hang off one intrusive list guarded by a bit-in-atomic lock; task-locals are a parallel list inherited by pointer. This makes cancellation propagation O(records) and inheritance O(1). Copying context into children (the naive design) is what SE-0311 explicitly avoided.

9. **Use the task allocator for everything task-scoped**, including status records and async-let children, and preallocate async-let children in the parent's frame. Swift's numbers — 512-byte initial slab, ~1 KB slabs, slabs never freed but reused — are worth copying as defaults.

10. **Plan the debugger before shipping the ABI.** The extended frame record (context slot beside FP, tag bit in FP, runtime-provided flag word for OS back-deployment, PAC discriminators on every context field) had to be co-designed with lldb and the OS unwinder. If your target lacks a spare FP bit, you will need symbol lookups like Swift's Linux backtracer.

### Primary sources used

- Swift ABI/runtime: `docs/ABI/CallingConventionSummary.rst`; `include/swift/ABI/{Task.h,Executor.h,MetadataValues.h,Metadata.h}`; `include/swift/Runtime/{Config.h,Concurrency.h,ConcurrencyHooks.def}`; `stdlib/public/Concurrency/{Task.cpp,TaskPrivate.h,TaskStatus.cpp,TaskLocal.cpp,Actor.cpp,GlobalExecutor.cpp,DispatchGlobalExecutor.cpp,CooperativeGlobalExecutor.cpp,ExecutorImpl.h,AsyncLet.cpp,TaskGroup.swift,TaskSleep.swift,TaskCancellation.swift,CheckedContinuation.swift}`; `stdlib/public/runtime/StackAllocator.h`; `lib/IRGen/GenCall.cpp`; `docs/SIL/Instructions.md` — all at https://github.com/swiftlang/swift/tree/main
- LLVM: https://llvm.org/docs/Coroutines.html, https://llvm.org/docs/LangRef.html, `llvm/lib/Target/X86/X86FrameLowering.cpp`, `llvm/lib/Target/AArch64/AArch64FrameLowering.cpp`, https://reviews.llvm.org/D95443, https://reviews.llvm.org/D95561
- Swift Evolution: SE-0296, 0300, 0304, 0311, 0317, 0338, 0392, 0413, 0417, 0419, 0424, 0461, 0472, 0505 at https://github.com/swiftlang/swift-evolution/tree/main/proposals
- Forums/blogs: https://forums.swift.org/t/pitch-4-custom-main-and-global-executors/89107, https://forums.swift.org/t/swift-embedded-concurrency/74515, https://forums.swift.org/t/exploring-multicore-concurrency-for-embedded-swift/87129, https://forums.swift.org/t/lldb-support-for-swift-async-frames-for-windows-x86-64/69799, https://www.swift.org/blog/swift-5.9-backtraces/, https://www.swift.org/blog/embedded-swift-improvements-coming-in-swift-6.4/, https://book.swiftwasm.org/getting-started/concurrency.html, https://developer.apple.com/videos/play/wwdc2021/10254/