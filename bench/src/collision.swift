struct Circle { var x: Float; var y: Float; var r: Float }

ATTR func cellOf(_ x: Float, _ y: Float, _ cs: Float, _ w: Int) async -> Int {
  let cx = max(0, min(w &- 1, Int(x / cs)))
  let cy = max(0, min(w &- 1, Int(y / cs)))
  return cy &* w &+ cx
}

ATTR func overlaps(_ a: Circle, _ b: Circle) async -> Bool {
  let dx = a.x - b.x, dy = a.y - b.y
  let rr = a.r + b.r
  return dx * dx + dy * dy < rr * rr
}

ATTR func resolve(_ a: Circle, _ b: Circle) async -> Float {
  let dx = a.x - b.x, dy = a.y - b.y
  let d = (dx * dx + dy * dy).squareRoot()
  return (a.r + b.r) - d
}

ATTR func broadphase(_ c: [Circle], _ heads: inout [Int32], _ next: inout [Int32],
                     _ cs: Float, _ w: Int) async {
  for i in 0..<heads.count { heads[i] = -1 }
  for i in 0..<c.count {
    let cell = await cellOf(c[i].x, c[i].y, cs, w)
    next[i] = heads[cell]
    heads[cell] = Int32(i)
  }
}

ATTR func narrowphase(_ c: [Circle], _ heads: [Int32], _ next: [Int32], _ w: Int) async -> Float {
  var pen: Float = 0
  for cell in 0..<(w &* w) {
    var i = heads[cell]
    while i >= 0 {
      var j = next[Int(i)]
      while j >= 0 {
        let a = c[Int(i)], b = c[Int(j)]
        let hit = await overlaps(a, b)
        if hit {
          let d = await resolve(a, b)
          pen += d
        }
        j = next[Int(j)]
      }
      i = next[Int(i)]
    }
  }
  return pen
}

ATTR func body() async {
  let s = scaleArg()
  let n = 40_000
  let w = 64
  let world: Float = 1024
  let cs = world / Float(w)
  let rounds = max(1, 200 / s)
  var circles = [Circle](repeating: Circle(x: 0, y: 0, r: 0), count: n)
  var seed: UInt64 = 88172645463325252
  for i in 0..<n {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    circles[i] = Circle(x: Float(seed % 1024), y: Float((seed >> 20) % 1024), r: 2 + Float((seed >> 40) % 4))
  }
  var heads = [Int32](repeating: -1, count: w * w)
  var next = [Int32](repeating: -1, count: n)
  let t0 = nowMs()
  var total: Float = 0
  for _ in 0..<rounds {
    await broadphase(circles, &heads, &next, cs, w)
    total += await narrowphase(circles, heads, next, w)
  }
  emit("collision", nowMs() - t0, Int(total))
}

@main struct Bench {
  ATTR static func main() async {
    await detached { await body() }
  }
}
