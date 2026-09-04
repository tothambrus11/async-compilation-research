| program | variant | sync ms | async ms | ratio |
|---|---|---:|---:|---:|
| astar | inlining allowed | 114.0 | 4922.2 | **43.18x** |
| binarytrees | inlining allowed | 362.3 | 25356.2 | **69.99x** |
| collision | inlining allowed | 331.4 | 314.6 | **0.95x** |
| ecs | inlining allowed | 177.4 | 175.6 | **0.99x** |
| fib | inlining allowed | 63.7 | trap | **Maximum call stack size exceeded** |
| matmul | inlining allowed | 182.8 | 209.2 | **1.14x** |
| microcall | inlining allowed | 2.4 | 2.3 | **0.96x** |
| microcall | no inlining | 20.3 | 11116.8 | **547.63x** |
| nbody | inlining allowed | 165.6 | 195.7 | **1.18x** |
| parser | inlining allowed | 145.7 | 16126.8 | **110.68x** |
| particles | inlining allowed | 143.1 | 192.4 | **1.34x** |
| particles | no inlining | 528.8 | 54889.7 | **103.80x** |
| sort | inlining allowed | 228.8 | 588.9 | **2.57x** |

Google Chrome 151.0.7922.169, 2026-09-04 21:11:40+0200, min of 2 runs, scale 1.
