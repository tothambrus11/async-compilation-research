ATTR func fib(_ n: Int) async -> Int {
  if n < 2 { return n }
  let a = await fib(n &- 1)
  let b = await fib(n &- 2)
  return a &+ b
}

ATTR func body() async {
  let s = scaleArg()
  let n = s > 1 ? 27 : 38
  let t0 = nowMs()
  let r = await fib(n)
  emit("fib", nowMs() - t0, r)
}

@main struct Bench {
  ATTR static func main() async {
    await detached { await body() }
  }
}
