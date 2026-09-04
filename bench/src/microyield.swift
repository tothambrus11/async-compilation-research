// async-only: uses Task.yield(), which has no synchronous counterpart.
@inline(never) func spin(_ x: Int) async -> Int { (x &* 1664525) &+ 1013904223 }

func body() async {
  let n = 2_000_000
  var acc = 1
  var t0 = nowMs()
  for _ in 0..<n { acc = await spin(acc) }
  let callMs = nowMs() - t0
  t0 = nowMs()
  for _ in 0..<n { await Task.yield() }
  let yieldMs = nowMs() - t0
  emit("microyield.call", callMs, acc & 0xffff)
  emit("microyield.yield", yieldMs, n)
}

@main struct Bench {
  static func main() async {
    await detached { await body() }
  }
}
