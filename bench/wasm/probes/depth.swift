// What does a *resume* cost in a return-to-driver lowering?
//
// Swift's CPS design resumes in O(1): the continuation points straight at the
// innermost frame.  A return-to-driver design instead unwinds normally to a driver
// loop and re-enters from the top, so a resume is O(depth).  That is the trade the
// design makes, and this measures it: per-call cost stays ~1-2 ns, and a suspension
// costs depth x re-entry.
#if canImport(Glibc)
import Glibc
private let mono = CLOCK_MONOTONIC
#elseif canImport(WASILibc)
import WASILibc
private let mono = clockid_t(bitPattern: 1)!
#endif
func nowMs() -> Double { var t = timespec(); clock_gettime(mono, &t); return Double(t.tv_sec)*1000 + Double(t.tv_nsec)/1e6 }

let OK: Int32 = 0, SUSPENDED: Int32 = 1

struct State {
  var resume: UnsafeMutablePointer<Int32>   // one resume index per frame
  var acc: Int
  var maxDepth: Int
  var willSuspend: Bool
}

// One frame of a coroutine chain: re-entered from the top, it skips forward to its
// saved resume point, and propagates a suspension by returning a status.
@inline(never)
func frame(_ level: Int, _ s: UnsafeMutablePointer<State>) -> Int32 {
  if s.pointee.resume[level] == 0 {
    s.pointee.acc = (s.pointee.acc &* 1664525) &+ 1013904223   // work before the call
  }
  if level &+ 1 < s.pointee.maxDepth {
    let r = frame(level &+ 1, s)
    if r == SUSPENDED { s.pointee.resume[level] = 1; return SUSPENDED }   // spill and unwind
    s.pointee.resume[level] = 0
    return OK
  }
  if s.pointee.willSuspend { s.pointee.resume[level] = 1; return SUSPENDED }
  s.pointee.resume[level] = 0
  return OK
}

@main struct M {
  static func main() {
    let resume = UnsafeMutablePointer<Int32>.allocate(capacity: 256)
    for d in [1, 4, 16, 64] {
      resume.update(repeating: 0, count: 256)
      var s = State(resume: resume, acc: 1, maxDepth: d, willSuspend: true)
      let n = 200_000
      let t0 = nowMs()
      withUnsafeMutablePointer(to: &s) { p in
        for _ in 0..<n {
          // one full suspension: descend, suspend at the bottom, unwind to the driver
          _ = frame(0, p)
          // ... then the driver resumes it, re-entering every frame
          p.pointee.willSuspend = false
          _ = frame(0, p)
          p.pointee.willSuspend = true
        }
      }
      let ms = nowMs() - t0
      print("depth \(d): \(ms * 1e6 / Double(n)) ns per suspend+resume, \(ms * 1e6 / Double(n) / Double(2 * d)) ns per frame  [\(s.acc & 255)]")
    }
  }
}
