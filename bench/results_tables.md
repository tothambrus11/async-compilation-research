| program | sync ms | async ms | ratio | sync-NI ms | async-NI ms | ratio |
|---|---:|---:|---:|---:|---:|---:|
| fib | 70 | 1448 | **20.58x** | 75 | 1477 | **19.76x** |
| nbody | 135 | 133 | **0.99x** | 154 | 212 | **1.38x** |
| particles | 36 | 132 | **3.67x** | 455 | 5952 | **13.09x** |
| collision | 109 | 111 | **1.02x** | 371 | 1720 | **4.63x** |
| ecs | 107 | 124 | **1.16x** | 218 | 3050 | **14.00x** |
| astar | 106 | 152 | **1.43x** | 119 | 444 | **3.74x** |
| parser | 116 | 486 | **4.19x** | 279 | 3718 | **13.33x** |
| sort | 222 | 260 | **1.17x** | 304 | 1830 | **6.01x** |
| matmul | 112 | 115 | **1.02x** | 141 | 152 | **1.07x** |
| binarytrees | 550 | 1456 | **2.65x** | 521 | 1397 | **2.68x** |

Per-call unit costs, from `microcall` (20M calls of a one-argument function):

| call kind | ns per call |
|---|---:|
| sync, inlined | 0.10 |
| async, inlined | 0.11 |
| sync, not inlinable | 0.84 |
| async, not inlinable | 18.36 |
| async, not inlinable, called from an actor-isolated function | 16.11 |
| **added cost of async, not inlinable** | **17.52** |
| real suspension and resume (`Task.yield()`) | 342 |

Cost of running the workload in an actor-isolated entry point instead of a detached task,
with the async callees inlined into it (`mainactor`) and prevented from inlining (`mainactor-NI`):

| program | async ms | mainactor ms | ratio | async-NI ms | mainactor-NI ms | ratio |
|---|---:|---:|---:|---:|---:|---:|
| fib | 1448 | 1474 | **1.02x** | 1477 | 1474 | **1.00x** |
| nbody | 133 | 6596 | **49.49x** | 212 | 210 | **0.99x** |
| particles | 132 | 161 | **1.22x** | 5952 | 6069 | **1.02x** |
| collision | 111 | 121 | **1.09x** | 1720 | 1682 | **0.98x** |
| ecs | 124 | 191 | **1.54x** | 3050 | 3051 | **1.00x** |
| astar | 152 | 153 | **1.01x** | 444 | 432 | **0.97x** |
| parser | 486 | 498 | **1.02x** | 3718 | 3560 | **0.96x** |
| sort | 260 | 251 | **0.97x** | 1830 | 1803 | **0.99x** |
| matmul | 115 | 194 | **1.69x** | 152 | 153 | **1.01x** |
| binarytrees | 1456 | 1638 | **1.12x** | 1397 | 1619 | **1.16x** |

Per-call cost derived from whole programs, using analytic call counts:

| program | extra ms (not inlinable) | calls | ns per call |
|---|---:|---:|---:|
| fib | 1403 | 126491971 | 11.1 |
| particles | 5497 | 288000000 | 19.1 |
| ecs | 2833 | 96000000 | 29.5 |

Binary size, bytes:

| program | sync | async | growth |
|---|---:|---:|---:|
| fib | 27040 | 35224 | +30% |
| nbody | 27248 | 39304 | +44% |
| particles | 27208 | 35208 | +29% |
| collision | 27880 | 35888 | +29% |
| ecs | 27216 | 39232 | +44% |
| astar | 32176 | 40944 | +27% |
| parser | 40576 | 69264 | +71% |
| sort | 28104 | 40976 | +46% |
| matmul | 27200 | 35160 | +29% |
| binarytrees | 28136 | 41568 | +48% |

Measured 2026-09-04 21:11:40+0200 on 12th Gen Intel(R) Core(TM) i9-12900H (20 cores, x86_64, 7.0.0-30-generic), governor `powersave`, profile `balanced`, max 4900 MHz, Swift version 6.5-dev (LLVM 6f2057ffeafd4c6, Swift 83c32e02f71e4bb) | Target: x86_64-unknown-linux-gnu | Build config: +assertions, `-O -parse-as-library -wmo`, min of 7 runs, pinned to one core.
