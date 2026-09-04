#if canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Darwin)
import Darwin
#endif

#if canImport(WASILibc)
private let monotonicClock = clockid_t(bitPattern: 1)!  // CLOCK_MONOTONIC, not imported on WASI
#else
private let monotonicClock = CLOCK_MONOTONIC
#endif

func nowMs() -> Double {
  var ts = timespec()
  clock_gettime(monotonicClock, &ts)
  return Double(ts.tv_sec) * 1000.0 + Double(ts.tv_nsec) / 1_000_000.0
}

func scaleArg() -> Int {
  if CommandLine.arguments.count > 1, let v = Int(CommandLine.arguments[1]) { return max(1, v) }
  return 1
}

func emit(_ name: String, _ ms: Double, _ checksum: Int) {
  print("\(name)\t\(ms)\t\(checksum)")
}

// Runs the benchmark body. With BENCH_ONACTOR=1 it stays on the (MainActor-isolated)
// entry point, so every await pays an executor hop; otherwise it runs in a detached
// task on the global executor, where awaits stay on one executor.
func detached(_ f: @escaping @Sendable () async -> Void) async {
  if let e = getenv("BENCH_ONACTOR"), e.pointee == 49 {
    await f()
  } else {
    await Task.detached(operation: f).value
  }
}

func detached(_ f: () -> Void) { f() }
