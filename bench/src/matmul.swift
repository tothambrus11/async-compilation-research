ATTR func mulRow(_ a: [Float], _ b: [Float], _ c: inout [Float], _ i: Int, _ n: Int) async {
  for k in 0..<n {
    let aik = a[i &* n &+ k]
    if aik == 0 { continue }
    let brow = k &* n
    let crow = i &* n
    for j in 0..<n {
      c[crow &+ j] += aik * b[brow &+ j]
    }
  }
}

ATTR func matmul(_ a: [Float], _ b: [Float], _ c: inout [Float], _ n: Int) async {
  for i in 0..<n { await mulRow(a, b, &c, i, n) }
}

ATTR func body() async {
  let s = scaleArg()
  let n = s > 1 ? 96 : 640
  var a = [Float](repeating: 0, count: n * n)
  var b = [Float](repeating: 0, count: n * n)
  var c = [Float](repeating: 0, count: n * n)
  var seed: UInt64 = 31337
  for i in 0..<(n * n) {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    a[i] = Float(seed % 100) / 100.0
    b[i] = Float((seed >> 16) % 100) / 100.0
  }
  let t0 = nowMs()
  await matmul(a, b, &c, n)
  var acc: Float = 0
  for i in stride(from: 0, to: n * n, by: 1013) { acc += c[i] }
  emit("matmul", nowMs() - t0, Int(acc))
}

@main struct Bench {
  ATTR static func main() async {
    await detached { await body() }
  }
}
