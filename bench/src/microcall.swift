ATTR func work(_ x: Int) async -> Int { (x &* 1664525) &+ 1013904223 }

ATTR func body() async {
  let s = scaleArg()
  let n = max(1000, 20_000_000 / s)
  let t0 = nowMs()
  var acc = 1
  for _ in 0..<n { acc = await work(acc) }
  emit("microcall", nowMs() - t0, acc & 0xffff)
}

@main struct Bench {
  ATTR static func main() async {
    await detached { await body() }
  }
}
