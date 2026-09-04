#if canImport(Glibc)
import Glibc
private let mono = CLOCK_MONOTONIC
#elseif canImport(WASILibc)
import WASILibc
private let mono = clockid_t(bitPattern: 1)!
#endif
func nowMs() -> Double { var t = timespec(); clock_gettime(mono, &t); return Double(t.tv_sec)*1000 + Double(t.tv_nsec)/1e6 }

@inline(never) func plain(_ x: Int) async -> Int { (x &* 1664525) &+ 1013904223 }
@inline(never) nonisolated(nonsending) func nonsending(_ x: Int) async -> Int { (x &* 1664525) &+ 1013904223 }

func bench(_ n: Int) async {
  var acc = 1
  var t0 = nowMs()
  for _ in 0..<n { acc = await plain(acc) }
  let a = nowMs() - t0
  t0 = nowMs()
  for _ in 0..<n { acc = await nonsending(acc) }
  let b = nowMs() - t0
  print("plain \(a*1e6/Double(n)) ns/call   nonisolated(nonsending) \(b*1e6/Double(n)) ns/call  \(acc & 255)")
}

@main struct M {
  static func main() async {
    let n = 300_000
    print("-- inside a detached task:")
    await Task.detached { await bench(n) }.value
    print("-- on the entry point's executor:")
    await bench(n)
  }
}
