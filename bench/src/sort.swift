ATTR func less(_ a: Int32, _ b: Int32) async -> Bool { a < b }

ATTR func insertionSort(_ a: inout [Int32], _ lo: Int, _ hi: Int) async {
  var i = lo &+ 1
  while i <= hi {
    let v = a[i]
    var j = i &- 1
    while j >= lo {
      let c = await less(v, a[j])
      if !c { break }
      a[j &+ 1] = a[j]
      j &-= 1
    }
    a[j &+ 1] = v
    i &+= 1
  }
}

ATTR func partition(_ a: inout [Int32], _ lo: Int, _ hi: Int) async -> Int {
  let mid = lo &+ (hi &- lo) / 2
  let c1 = await less(a[mid], a[lo])
  if c1 { a.swapAt(mid, lo) }
  let c2 = await less(a[hi], a[lo])
  if c2 { a.swapAt(hi, lo) }
  let c3 = await less(a[hi], a[mid])
  if c3 { a.swapAt(hi, mid) }
  let pivot = a[mid]
  var i = lo, j = hi
  while i <= j {
    while true { let c = await less(a[i], pivot); if !c { break }; i &+= 1 }
    while true { let c = await less(pivot, a[j]); if !c { break }; j &-= 1 }
    if i <= j {
      a.swapAt(i, j)
      i &+= 1; j &-= 1
    }
  }
  return i
}

ATTR func quickSort(_ a: inout [Int32], _ lo: Int, _ hi: Int) async {
  if hi &- lo < 16 {
    if hi > lo { await insertionSort(&a, lo, hi) }
    return
  }
  let p = await partition(&a, lo, hi)
  if lo < p &- 1 { await quickSort(&a, lo, p &- 1) }
  if p < hi { await quickSort(&a, p, hi) }
}

ATTR func body() async {
  let s = scaleArg()
  let n = max(1000, 3_000_000 / s)
  var a = [Int32](repeating: 0, count: n)
  var seed: UInt64 = 7777
  for i in 0..<n {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    a[i] = Int32(truncatingIfNeeded: seed)
  }
  let t0 = nowMs()
  await quickSort(&a, 0, n &- 1)
  var check = 0
  for i in stride(from: 0, to: n, by: 4096) { check = check &+ Int(a[i] % 1000) }
  var sorted = true
  for i in 1..<n where a[i] < a[i &- 1] { sorted = false; break }
  emit("sort", nowMs() - t0, sorted ? check : -1)
}

@main struct Bench {
  ATTR static func main() async {
    await detached { await body() }
  }
}
