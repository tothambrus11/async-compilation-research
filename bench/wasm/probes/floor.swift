#if canImport(Glibc)
import Glibc
private let mono = CLOCK_MONOTONIC
#elseif canImport(WASILibc)
import WASILibc
private let mono = clockid_t(bitPattern: 1)!
#endif
func nowMs() -> Double { var t = timespec(); clock_gettime(mono, &t); return Double(t.tv_sec)*1000 + Double(t.tv_nsec)/1e6 }

// (1) an ordinary non-inlinable call
@inline(never) func plainCall(_ x: Int) -> Int { (x &* 1664525) &+ 1013904223 }

// (2) the shape a "every function is a coroutine" lowering emits: the callee owns an
// explicit frame, returns a status, and the caller branches on it.  No runtime, no
// executor, no tail calls: a suspend would store a resume index and return `1`.
struct Frame { var acc: Int; var resume: Int32 }
enum Status: Int32 { case ok = 0, suspended = 1, failed = 2 }

@inline(never) func statusCall(_ f: UnsafeMutablePointer<Frame>) -> Int32 {
  f.pointee.acc = (f.pointee.acc &* 1664525) &+ 1013904223
  return Status.ok.rawValue
}

// (3) the same, but re-entered through a driver loop, as a resumed frame would be
@inline(never) func driverStep(_ f: UnsafeMutablePointer<Frame>) -> Int32 {
  switch f.pointee.resume {
  case 0:
    f.pointee.acc = (f.pointee.acc &* 1664525) &+ 1013904223
    f.pointee.resume = 0
    return Status.ok.rawValue
  default:
    return Status.failed.rawValue
  }
}

@main struct M {
  static func main() {
    let n = 20_000_000
    var acc = 1
    var t0 = nowMs()
    for _ in 0..<n { acc = plainCall(acc) }
    let a = nowMs() - t0
    var f = Frame(acc: 1, resume: 0)
    t0 = nowMs()
    withUnsafeMutablePointer(to: &f) { p in
      for _ in 0..<n { if statusCall(p) != 0 { break } }
    }
    let b = nowMs() - t0
    f = Frame(acc: 1, resume: 0)
    t0 = nowMs()
    withUnsafeMutablePointer(to: &f) { p in
      for _ in 0..<n { if driverStep(p) != 0 { break } }
    }
    let c = nowMs() - t0
    print("plain call            \(a*1e6/Double(n)) ns")
    print("status-return call    \(b*1e6/Double(n)) ns")
    print("driver re-entry call  \(c*1e6/Double(n)) ns")
    print("checksum \(acc & 255) \(f.acc & 255)")
  }
}
