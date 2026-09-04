ATTR func heuristic(_ a: Int, _ b: Int, _ w: Int) async -> Int32 {
  let ax = a % w, ay = a / w, bx = b % w, by = b / w
  return Int32(abs(ax - bx) + abs(ay - by))
}

ATTR func heapPush(_ f: inout [Int32], _ node: inout [Int32], _ count: inout Int, _ fv: Int32, _ nv: Int32) async {
  var i = count
  f[i] = fv; node[i] = nv
  count &+= 1
  while i > 0 {
    let p = (i &- 1) / 2
    if f[p] <= f[i] { break }
    f.swapAt(p, i); node.swapAt(p, i)
    i = p
  }
}

ATTR func heapPop(_ f: inout [Int32], _ node: inout [Int32], _ count: inout Int) async -> Int32 {
  let top = node[0]
  count &-= 1
  f[0] = f[count]; node[0] = node[count]
  var i = 0
  while true {
    let l = 2 &* i &+ 1, r = l &+ 1
    var m = i
    if l < count && f[l] < f[m] { m = l }
    if r < count && f[r] < f[m] { m = r }
    if m == i { break }
    f.swapAt(m, i); node.swapAt(m, i)
    i = m
  }
  return top
}

ATTR func passable(_ grid: [UInt8], _ idx: Int) async -> Bool { grid[idx] == 0 }

ATTR func astar(_ grid: [UInt8], _ w: Int, _ h: Int, _ start: Int, _ goal: Int,
                _ g: inout [Int32], _ hf: inout [Int32], _ hn: inout [Int32]) async -> Int32 {
  for i in 0..<g.count { g[i] = Int32.max }
  var count = 0
  g[start] = 0
  let h0 = await heuristic(start, goal, w)
  await heapPush(&hf, &hn, &count, h0, Int32(start))
  while count > 0 {
    let cur = Int(await heapPop(&hf, &hn, &count))
    if cur == goal { return g[goal] }
    let cx = cur % w, cy = cur / w
    let base = g[cur]
    if base == Int32.max { continue }
    for k in 0..<4 {
      var nx = cx, ny = cy
      if k == 0 { nx &-= 1 } else if k == 1 { nx &+= 1 } else if k == 2 { ny &-= 1 } else { ny &+= 1 }
      if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
      let nidx = ny &* w &+ nx
      let ok = await passable(grid, nidx)
      if !ok { continue }
      let ng = base &+ 1
      if ng < g[nidx] {
        g[nidx] = ng
        let hv = await heuristic(nidx, goal, w)
        await heapPush(&hf, &hn, &count, ng &+ hv, Int32(nidx))
      }
    }
  }
  return -1
}

ATTR func body() async {
  let s = scaleArg()
  let w = 400, h = 400
  let runs = max(1, 60 / s)
  var grid = [UInt8](repeating: 0, count: w * h)
  var seed: UInt64 = 42
  for i in 0..<(w * h) {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    grid[i] = (seed % 100) < 28 ? 1 : 0
  }
  for y in 0..<h { grid[y * w] = 0; grid[y * w + w - 1] = 0 }
  for x in 0..<w { grid[x] = 0; grid[(h - 1) * w + x] = 0 }
  var g = [Int32](repeating: Int32.max, count: w * h)
  var hf = [Int32](repeating: 0, count: w * h * 4)
  var hn = [Int32](repeating: 0, count: w * h * 4)
  let t0 = nowMs()
  var total: Int32 = 0
  for r in 0..<runs {
    let start = r * 7
    let goal = w * h - 1 - r * 3
    total &+= await astar(grid, w, h, start, goal, &g, &hf, &hn)
  }
  emit("astar", nowMs() - t0, Int(total))
}

@main struct Bench {
  ATTR static func main() async {
    await detached { await body() }
  }
}
