/* Two lowerings of "suspend deep in a call chain, resume, repeat", measured on wasm.
 *
 *  (A) status-return + driver re-entry.  A suspending callee returns a status; every
 *      caller records a resume index and returns too, so the stack unwinds to a driver.
 *      Resuming means calling back in at the top and walking down to the innermost
 *      frame: O(depth) per resume.  While running, the chain occupies `depth` real
 *      wasm frames, so deep recursion can still exhaust the stack.
 *
 *  (B) continuation passing with guaranteed tail calls (`return_call`).  Frames live
 *      in linear memory and every transfer -- call, return, resume -- is a tail call,
 *      so the wasm stack depth is constant no matter how deep the logical chain gets.
 *      Resuming means calling the innermost frame's continuation directly: O(1).
 *
 * Build (wasm):   clang --target=wasm32-wasip1 -mtail-call -O2 lowering.c
 * Build (native): clang -O2 lowering.c
 *
 * Usage: lowering yield [maxdepth] | lowering depth <n>
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

#define OK 0
#define SUSPENDED 1

/* ---------------- (A) status-return + driver re-entry ---------------- */

typedef struct { int32_t *resume; long acc; int depth; long yields; } SState;

__attribute__((noinline))
static int32_t sframe(int level, SState *s) {
  if (s->resume[level] == 0)
    s->acc = s->acc * 1664525 + 1013904223;      /* work before the suspending call */
  if (level + 1 < s->depth) {
    int32_t r = sframe(level + 1, s);
    if (r == SUSPENDED) { s->resume[level] = 1; return SUSPENDED; }  /* spill, unwind */
    s->resume[level] = 0;
    return OK;
  }
  if (s->yields > 0) { s->yields--; s->resume[level] = 1; return SUSPENDED; }
  s->resume[level] = 0;
  return OK;
}

static long s_run(int depth, long yields, int32_t *resume) {
  SState s = { resume, 1, depth, yields };
  for (int i = 0; i < depth; i++) resume[i] = 0;
  while (sframe(0, &s) == SUSPENDED) { }         /* each iteration re-enters `depth` frames */
  return s.acc;
}

/* ---------------- (B) CPS with guaranteed tail calls ---------------- */

struct CFrame;
typedef void (*Cont)(struct CFrame *);
struct CFrame { Cont resume; struct CFrame *parent; int level; };

static struct CFrame *g_park;      /* the innermost suspended frame */
static long g_acc;
static int g_depth;
static long g_yields;
static struct CFrame *g_frames;    /* frame store in linear memory */
static int g_top;

static void c_enter(struct CFrame *);
static void c_after(struct CFrame *);
static void c_bottom(struct CFrame *);
static void c_finish(struct CFrame *);

/* Suspending is just "stop tail-calling": this returns, and because every transfer
   above it was a tail call, control lands back in the driver with a flat stack. */
__attribute__((noinline)) static void c_park_fn(struct CFrame *f) { g_park = f; }

__attribute__((noinline)) static void c_enter(struct CFrame *f) {
  g_acc = g_acc * 1664525 + 1013904223;
  if (f->level + 1 < g_depth) {
    struct CFrame *c = &g_frames[++g_top];
    c->parent = f; c->level = f->level + 1; c->resume = c_enter;
    f->resume = c_after;                          /* where this frame continues later */
    __attribute__((musttail)) return c_enter(c);
  }
  __attribute__((musttail)) return c_bottom(f);
}

__attribute__((noinline)) static void c_bottom(struct CFrame *f) {
  if (g_yields > 0) { g_yields--; f->resume = c_bottom; __attribute__((musttail)) return c_park_fn(f); }
  __attribute__((musttail)) return c_finish(f);
}

__attribute__((noinline)) static void c_after(struct CFrame *f) {
  __attribute__((musttail)) return c_finish(f);
}

__attribute__((noinline)) static void c_finish(struct CFrame *f) {
  struct CFrame *p = f->parent;
  g_top--;
  if (!p) { g_park = NULL; return; }              /* whole chain complete */
  __attribute__((musttail)) return p->resume(p);  /* pop: tail-call into the parent */
}

static long c_run(int depth, long yields) {
  g_depth = depth; g_yields = yields; g_top = 0; g_park = NULL; g_acc = 1;
  g_frames[0].parent = NULL; g_frames[0].level = 0; g_frames[0].resume = c_enter;
  c_enter(&g_frames[0]);                          /* descend, park at the bottom */
  while (g_park) {
    struct CFrame *f = g_park; g_park = NULL;
    f->resume(f);                                 /* O(1): straight into the innermost frame */
  }
  return g_acc;
}

/* ---------------- drivers ---------------- */

int main(int argc, char **argv) {
  const char *mode = argc > 1 ? argv[1] : "yield";
  int maxcap = 1 << 21;
  g_frames = malloc(sizeof(struct CFrame) * maxcap);
  int32_t *resume = malloc(sizeof(int32_t) * maxcap);
  if (!g_frames || !resume) { printf("alloc failed\n"); return 1; }

  if (mode[0] == 'y') {
    long yields = 200000;
    int maxdepth = argc > 2 ? atoi(argv[2]) : 256;
    printf("depth\tstatus_ns_per_resume\tcps_ns_per_resume\n");
    for (int d = 1; d <= maxdepth; d *= 4) {
      double t0 = now_ms();
      long a = s_run(d, yields, resume);
      double sms = now_ms() - t0;
      t0 = now_ms();
      long b = c_run(d, yields);
      double cms = now_ms() - t0;
      printf("%d\t%.1f\t%.1f\t[%ld %ld]\n", d, sms * 1e6 / yields, cms * 1e6 / yields,
             a & 255, b & 255);
      fflush(stdout);
    }
  } else {
    int d = argc > 2 ? atoi(argv[2]) : 100000;
    int reps = d > 100000 ? 1 : 20;
    printf("depth %d: ", d); fflush(stdout);
    double t0 = now_ms();
    long b = 0;
    for (int i = 0; i < reps; i++) b = c_run(d, 0);
    double cms = now_ms() - t0;
    printf("cps ok, %.1f ns/frame [%ld]; ", cms * 1e6 / ((double)d * reps), b & 255);
    fflush(stdout);
    t0 = now_ms();
    long a = 0;
    for (int i = 0; i < reps; i++) a = s_run(d, 0, resume);   /* can overflow the stack */
    double sms = now_ms() - t0;
    printf("status ok, %.1f ns/frame [%ld]\n", sms * 1e6 / ((double)d * reps), a & 255);
  }
  return 0;
}
