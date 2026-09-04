# Teodorescu's spawn/await model with thread inversion (Hylo, concore2full)

Research memo, 2026-09-04. Sources: the three Overload articles by Lucian Radu Teodorescu, the
`hylo-lang/concore2full` repository (read at commit `99d0030`, 2024-08-29), its dependency
`lucteo/context-core-api`, and the Hylo documentation page on concurrency. Tags: **[V]** verified
against the cited source; **[PK]** prior knowledge, not re-verified; **[?]** unverified or inference.

---

## 1. The three articles

### "Structured Concurrency in C++" (Overload 168, April 2022) [V]

Sets the vocabulary the later work relies on. Five traits of structured programming are mapped
onto concurrency: abstractions as building blocks (a *computation*), recursive decomposition, local
reasoning with nested scopes ("the definition of a sender completely describes the computation from
beginning to end"), single entry and exit ("one entry point (starting the work) and one exit point,
with three different alternatives: successful completion (possible with a value), completed with
error (i.e., exception), or cancelled"), and soundness/completeness (P2504 shows all concurrent
problems can be modelled with senders). The article advocates C++ senders/receivers (P2300) as the
efficient low-level foundation: no mandatory type erasure, no required blocking wait, no inherent
allocation. Its weakness, stated in the 2023 article, is ease of use: "All the computations need to
be expressed using primitives provided by the proposal."

### "In Search of a Better Concurrency Model" (Overload 174, April 2023) [V]

Defines the goals a concurrency model for Val (now Hylo) must meet, and proposes the model.

Goals, verbatim:
- S1 no undefined behaviour from races; S2 no deadlocks.
- F1 performance scales with hardware threads; F2 "shall not require blocking threads"; F3 limit
  oversubscription; F4 "shall not require any synchronisation code during the execution of the
  tasks"; F5 "shall not require dynamic memory allocation (unless type-erasure is requested)".
- E1 match structured concurrency; E2 "Concurrent code shall be expressed using the same syntax and
  semantics as non-concurrent code"; E3 "Function colouring shall not be required"; E4 no extra code
  in concurrent code beyond concurrency control; E5 a minimum set of rules.

The proposed model:
- Two primitives: `spawn f()` (work goes to a default thread pool, or to a user-provided scheduler)
  and `await` on the returned handle. "Calling `spawn f()` in Val would be equivalent to a C++
  sender `schedule(global_scheduler) | then(f)`."
- **"All functions are coroutines, even if the user doesn't explicitly mark them."** Implemented
  with *stackful* coroutines: "We can suspend such a coroutine at any point. This alone is a big win
  in terms of usability. Calling stackful coroutines doesn't require special syntax or special
  performance penalties." Stackless (C++20) coroutines are rejected because a coroutine "can only
  suspend at the same level as its creation point; it cannot suspend inside a called function", so
  avoiding synchronous waits would force "a large part of our functions" to become coroutines, with a
  potential heap allocation each.
- **Non-persistent threads.** "It is important to note that awaiting on such an asynchronous result
  may switch the current thread. This is considered an acceptable behaviour in our model." "Functions
  can be started on one thread, and they [end] on another thread. All the functions on the stack can
  possibly switch threads." This is turned into a feature: `io_thread.activate()` /
  `cpu_thread_pool.activate()` move the sequential flow between execution contexts.
- **No thread-local storage**: "With every function call, the current thread can change, so
  thread-local storage becomes an obsolete concept", and TLS "breaks the law of exclusivity" anyway.
- Costs: "we would only pay such costs when we spawn new work, when we complete concurrent work, and
  whenever we want to switch threads." Stackful coroutines need memory for full stacks ("if a function
  with a deep stack creates many coroutines, we need memory to fit multiple copies of the original
  stack"), so F5 is only partially met.
- Interoperability: "If other languages call Val functions, the functions need to be
  wrapped/adapted to ensure that the assumptions of the other languages are met. That is, the wrapped
  functions must guarantee that the threads won't change while executing these functions", which
  "most likely introduces performance penalties."
- The article does not discuss exceptions or cancellation, and says the model "is purely
  theoretical, there is no real implementation for it".

### "Concurrency: From Theory to Practice" (Overload 181, June 2024) [V]

Grounds the model in a theory (concurrency as a partial order of work items: for A and B either
A < B, B < A, or A ∥ B; a design-time fourth relation is mutual exclusion) and reports the
concore2full implementation.

- `spawn`/`await` in one scope express the constraints: in `A(); f = spawn(C); B(); f.await(); D();`
  we get A < B, A < C, B ∥ C, B < D, C < D. The future "is not movable and not copyable", so spawn
  and await are in the same scope: one entry, one exit, local reasoning.
- Three cases at `await`: (a) the spawned work already finished: continue; (b) the work has not been
  picked up by a worker: "we execute it inline, on the original thread", no coroutine created; (c) a
  worker is still executing it: rather than block, **thread hopping**: "we essentially switch the
  threads. The original thread will continue to execute whatever the worker thread has, while the
  worker thread will continue to execute everything on the main flow after the await point." "A
  stackful coroutine is created to execute the spawned work; the worker thread doesn't do much work
  on its stack, as it immediately jumps to the coroutine stack." Figure 4: "After executing B()
  thread 1 jumps and continues execution on the stack created for thread 2. After executing C(),
  thread 2 continues to execute the continuation on the stack created for thread 1. At the end of
  the work, the two threads are essentially swapped." Consequence: "a function may enter on one
  thread and exit on a different thread."
- Variants: `escaping_spawn` (movable future, spawn and await in different functions, "we need to
  have a heap allocation" because the spawning stack may disappear) and `bulk_spawn(n, f)` (frame on
  the heap, size depends on `n`).
- Benchmarks: Skynet (10 million leaf tasks) completes without deadlock or large stacks; "The spawn
  execution is 20% slower than the senders/receivers execution" and faster than the Go version;
  Mandelbrot on a 4K image (one task per row) shows near-ideal speedup up to the 8 performance cores
  of an M2 Pro. "In real-world applications, the time spent in spawn/await is tiny compared to the
  useful work."
- Guarantees: no races if "no two concurrent tasks access the same memory location" with a writer;
  no deadlocks because constraints are expressed directly; forward progress ("Once a work item starts
  executing, it will complete and, eventually, all work items are started").
- What is left: copyable futures; "we have to add cancellation to the entire model"; conditional
  concurrency; "The code cannot use thread-local storage in the way people are accustomed to"; "If
  external code calls into our code that uses thread hopping, it may need to restore the original
  thread each time it calls a function into our code. This potentially involves a blocking wait";
  I/O, timers, GPUs and custom execution contexts.

## 2. What concore2full actually does (repository read) [V]

- **Context switching.** `context-core-api` is "Exposing Boost.Context core API": a C shim over
  Boost.Context's `make_fcontext` / `jump_fcontext` / `ontop_fcontext` (the fcontext primitives are
  hand-written assembly per architecture and OS ABI in Boost [PK]). concore2full's `callcc(f)` creates
  a stackful coroutine: `simple_stack_allocator` mallocs a **1 MiB** stack by default, places a
  control structure at its top, `make_fcontext` + `jump_fcontext` starts it; `resume(c)` is
  `jump_fcontext`. The coroutine entry is `noexcept`; when the main function returns, the stack is
  destroyed via `ontop_fcontext`.
- **The spawn frame** (`spawn_frame_base`, 10 pointer-sized words in the C API's
  `concore2full_spawn_frame`): a `concore2full_task` (intrusive list node), an atomic
  `sync_state_` with transitions `initial → async_started → {async_finished | main_finishing →
  main_finished}`, two continuations `originator_` and `secondary_thread_`, and the user function.
- **spawn**: fills the task and enqueues it on the global thread pool (`thread_pool::enqueue`, one
  work line per thread, try-lock push, wake one sleeper).
- **await** (`spawn_frame_base::await`):
  1. If the task is still `initial` and `extract_task` succeeds, run it inline ("execute inplace")
     and return; if a worker already took it, spin/wait until `async_started` (the worker has stored
     its continuation).
  2. CAS `async_started → main_finishing`. If it succeeds, the main flow arrived first: `callcc`
     captures the awaiting flow as `originator_`, publishes `main_finished`, and **returns
     `secondary_thread_`**, i.e. the awaiting thread jumps onto the worker's original stack and
     becomes a pool worker. If the CAS fails, the worker had already finished, so the main flow just
     continues on its own thread.
- **On the worker** (`execute_spawn_task`): `callcc` onto a fresh 1 MiB coroutine stack, store the
  worker's own stack continuation as `secondary_thread_`, publish `async_started`, run the user
  function, then `on_async_complete`: CAS `async_started → async_finished` (worker first: return to
  the worker's own stack, no switch) or else wait for `main_finished` and **return `originator_`**,
  i.e. the worker continues the awaiting flow after `await` on the originator's stack. This is the
  thread swap. `future::await()` documents it: "the exit thread may be different from the thread that
  called this method."
- **Getting back to a thread**: `thread_snapshot` / `sync_execute(f)` record the current
  `thread_info` and, after `f`, `switch_to(original)`; the pool's `execute_work` loop calls
  `this_thread::inversion_checkpoint()` between tasks so a worker that is currently "somebody else's
  thread" can hand it back. Worker threads use it to "exit on the same thread". This is the blocking
  interop wrapper the article warns about.
- **suspend / notify** (`suspend.h`): `suspend(token)` parks the current flow until `token.notify()`;
  while parked the thread runs pool work (`offer_help_until(stop_token)`); notify-before-suspend is
  handled. `suspend_quick_resume` enqueues a task to jump back to the suspended point as soon as
  possible, even if the thread is busy. The async I/O example builds a `poll`-based I/O loop on top: a
  receiver's `set_value` calls `token_.notify()`, and the reading flow does `oper.start();
  suspend(r.token_); if (r.e_) rethrow`. This is the model's answer to I/O and timers: **suspension
  is a library primitive, not a language feature**, because any function can suspend.
- **Cancellation** is not in the library; `sketch_cancellation.cpp` threads an explicit
  hierarchical `stop_token` through the spawned closures and checks it cooperatively in loops.
- **Exceptions**: the coroutine entry is `noexcept`; nothing in `spawn_frame_base` captures an
  exception thrown by the spawned function (the C API is `void`), so escaping exceptions terminate.
  The I/O example stores an `exception_ptr` and rethrows after `suspend`.
- **C API** (`concore2full/c/spawn.h`): `concore2full_spawn(frame, fn)`, `concore2full_await(frame)`,
  `concore2full_bulk_spawn`, `concore2full_bulk_await`, with an opaque fixed-size frame the caller
  allocates (on its own stack). This is the surface intended for the Hylo compiler to target.
- Platform reach: only what Boost.Context's `fcontext_t` assembly covers. Boost's architecture
  table lists arm (AAPCS, ELF/PE/Mach-O), aarch64, i386, x86_64 (SysV, X32, MS), loongarch64, mips,
  ppc32/64, riscv64, s390x and sparc64, with `BOOST_USE_UCONTEXT` as the fallback "if the
  architecture is not supported but the platform provides ucontext_t"; the build file knows only
  `fcontext`, `ucontext` and `winfib` implementations. **There is no WebAssembly or Emscripten
  support in Boost.Context**, and nothing in concore2full or context-core-api mentions WebAssembly
  [V]. Emscripten's own fiber API (`emscripten_fiber_init`/`emscripten_fiber_swap`) exists but "you
  must link your program with ASYNCIFY if you intend to use them", and "Rewind IDs are currently
  thread-specific. This makes it impossible to resume a fiber that has been started from a
  different thread" [V], i.e. no thread inversion on Wasm even with Asyncify.

## 3. Hylo status [V]

The Hylo documentation states: "The concurrency approach of Hylo is still under design. This
document only presents our current plans." It restates the goals (no function colouring; "Concurrent
code has the same syntax/semantics as non-concurrent code"; structured decomposition), the
`spawn()`/`await()` pair, thread inversion ("returned to the middleware when `await` is called and
can be reused to run other work items"), and custom schedulers with `activate()`. Hylo compiles
through LLVM (`--emit llvm`, `--emit intel-asm`); effort has moved to a new compiler
(`hylo-lang/hylo-new`). No WebAssembly target is mentioned.

The *old* compiler (`hylo-lang/hylo`, head 2026-07-13) does integrate concore2full: its
`StandardLibrary/Sources/Concurrency/Future.hylo` defines `Future<E>` ("A future that cannot escape
the local scope"; `await()` is documented "May return on a different OS thread than the one that
called this"), `EscapingFuture<E>` (heap-allocated `SpawnFrame`), and `SpawnFrame<E>` wrapping a
`SpawnFrameBase` of exactly "10 pointers, with the alignment of a pointer" that is passed to
`@external("concore2full_spawn2")` and `@external("concore2full_await")`; the spawned closure is
called with the frame pointer and stores its result into the frame. `Examples/concurrent_greeting.hylo`
uses `spawn_(fun() { do_greet() })` and `future.await() // switching threads`, linked with
`-l concore2full -l context_core_api -l boost_context`. Results are still `Int`-only (`// TODO`).
The new compiler's standard library (`hylo-new`, head 2026-09-04) contains only a `Core` module and
no concurrency code yet, and its only Wasm mentions are a `wasm32` hashing branch and a smoke test
note.

## 4. Analysis: what the model requires from a language and a target

**From the language.**
- A guarantee that concurrently running work does not alias mutable state. In Hylo this is the law
  of exclusivity; in Ferlium it is mutable value semantics plus capture-by-value closures, which is
  exactly the precondition the 2024 article states for race freedom.
- No observable thread identity (no TLS, no "current thread" API).
- `await` may run the child inline; scheduling order between siblings is unspecified.
- Every function may suspend, therefore every function may be *cancelled while suspended*; with
  Ferlium's status-based errors this means every suspension point must be able to raise (`suspend`
  implies `fallible`).

**From the runtime (native).**
- A context-switch primitive with per-coroutine stacks (Boost.Context; in Rust, a crate such as
  `corosensei` or hand-written assembly [PK]) and a thread pool. Stacks are the dominant cost: 1 MiB
  malloc per spawned task in concore2full's default allocator; a pooled or segmented allocator is the
  obvious mitigation. Unwinding (panics) must never cross a context switch: catch at the coroutine
  entry and convert to a status.
- The thread-inversion machinery is only needed when there are real worker threads. On a
  single thread the same API degenerates to plain fibers: `spawn` queues, `await` runs inline or
  switches to the child's stack and back.

**From the target (WebAssembly).** Stackful coroutines need one of:
- the core stack-switching proposal (`cont.new`, `suspend`, `resume`): the exact primitive, but
  Phase 3, no shipping engine, and continuations not shareable across threads, so no thread inversion;
- JSPI: a JS-side scheduler can give each `promising` export call its own engine stack and implement
  `await` as a `Suspending` import that returns a promise resolved when the child completes. Works
  in Chrome 137+/Firefox 153+/Node 25+ (Safari 27 beta), about 1 µs per switch and ~1 MiB per
  in-flight stack; single-threaded; JS hosts only;
- Asyncify or a compiler-integrated equivalent (Go's wasm backend): every function becomes
  re-enterable and locals live in a linear-memory frame. This is the "make everything an async
  function" option; it is the only one that runs on every engine today.

The consequence is that on Wasm the Hylo model and the "everything is a coroutine" model coincide:
the former's semantics can be kept, but the implementation must be the latter until stack switching
ships.

## 5. Unverified items

- Exact per-switch cost of `jump_fcontext` in this configuration (Boost documents it as a few
  nanoseconds on x86-64 [PK]).
- Whether Hylo's new compiler will keep the concore2full C-API binding of the old one [?].

## Sources

- https://accu.org/journals/overload/30/168/teodorescu/ (Structured Concurrency in C++, 2022)
- https://accu.org/journals/overload/31/174/teodorescu/ (In Search of a Better Concurrency Model, 2023)
- https://accu.org/journals/overload/32/181/teodorescu/ (Concurrency: From Theory to Practice, 2024)
- https://github.com/hylo-lang/concore2full (`include/concore2full/{spawn,future,suspend,sync_execute,this_thread,thread_snapshot}.h`, `src/{spawn_frame_base,suspend,thread_pool}.cpp`, `test/{example_async_io,sketch_cancellation,test_suspend}.cpp`, `include/concore2full/c/spawn.h`)
- https://github.com/lucteo/context-core-api
- https://docs.hylo-lang.org/language-tour/concurrency
- https://github.com/hylo-lang/hylo (`StandardLibrary/Sources/Concurrency/Future.hylo`, `Examples/concurrent_greeting.hylo`) · https://github.com/hylo-lang/hylo-new
- https://www.boost.org/doc/libs/release/libs/context/doc/html/context/architectures.html · https://raw.githubusercontent.com/boostorg/context/develop/build/Jamfile.v2 · https://emscripten.org/docs/api_reference/fiber.h.html
