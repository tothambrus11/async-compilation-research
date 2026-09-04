#if canImport(Glibc)
import Glibc
private let mono = CLOCK_MONOTONIC
#elseif canImport(WASILibc)
import WASILibc
private let mono = clockid_t(bitPattern: 1)!
#endif
func nowMs() -> Double { var t = timespec(); clock_gettime(mono, &t); return Double(t.tv_sec)*1000 + Double(t.tv_nsec)/1e6 }

final class InlineExecutor: SerialExecutor, @unchecked Sendable {
  func enqueue(_ job: consuming ExecutorJob) {
    // run the job right here instead of queueing it
    unsafe job.runSynchronously(on: asUnownedSerialExecutor())
  }
  func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
}
let inlineExec = InlineExecutor()

typealias Original = @convention(thin) (UnownedJob) -> Void
typealias Hook = @convention(thin) (UnownedJob, Original) -> Void
@_silgen_name("swift_task_enqueueGlobal_hook")
var enqueueGlobalHook: Hook?

@inline(never) func work(_ x: Int) async -> Int { (x &* 1664525) &+ 1013904223 }

func bench(_ label: String, _ n: Int) async {
  var acc = 1
  let t0 = nowMs()
  for _ in 0..<n { acc = await work(acc) }
  print("\(label) \((nowMs() - t0) * 1e6 / Double(n)) ns/call  \(acc & 255)")
}

@main struct M {
  static func main() async {
    let n = 50_000
    await Task.detached { await bench("default executor   ", n) }.value
    enqueueGlobalHook = { job, _ in
      unsafe inlineExec.enqueue(ExecutorJob(job))
    }
    await Task.detached { await bench("inline executor    ", n) }.value
  }
}
