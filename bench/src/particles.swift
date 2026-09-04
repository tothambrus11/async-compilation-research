struct V2 { var x: Float; var y: Float }

ATTR func vadd(_ a: V2, _ b: V2) async -> V2 { V2(x: a.x + b.x, y: a.y + b.y) }
ATTR func vscale(_ a: V2, _ s: Float) async -> V2 { V2(x: a.x * s, y: a.y * s) }
ATTR func gravity() async -> V2 { V2(x: 0, y: -9.81) }

ATTR func integrate(_ p: V2, _ v: V2, _ dt: Float) async -> V2 {
  let d = await vscale(v, dt)
  return await vadd(p, d)
}

ATTR func applyForces(_ v: V2, _ dt: Float) async -> V2 {
  let g = await gravity()
  let gd = await vscale(g, dt)
  var nv = await vadd(v, gd)
  nv = await vscale(nv, 0.999)
  return nv
}

ATTR func bounce(_ p: inout V2, _ v: inout V2) async {
  if p.y < 0 { p.y = -p.y; v.y = -v.y * 0.8 }
  if p.x < 0 { p.x = -p.x; v.x = -v.x * 0.8 }
  if p.x > 1000 { p.x = 2000 - p.x; v.x = -v.x * 0.8 }
}

ATTR func step(_ px: inout [Float], _ py: inout [Float],
               _ vx: inout [Float], _ vy: inout [Float], _ n: Int, _ dt: Float) async {
  for i in 0..<n {
    var p = V2(x: px[i], y: py[i])
    var v = V2(x: vx[i], y: vy[i])
    v = await applyForces(v, dt)
    p = await integrate(p, v, dt)
    await bounce(&p, &v)
    px[i] = p.x; py[i] = p.y; vx[i] = v.x; vy[i] = v.y
  }
}

ATTR func body() async {
  let s = scaleArg()
  let n = 200_000
  let steps = max(1, 240 / s)
  var px = [Float](repeating: 0, count: n), py = [Float](repeating: 0, count: n)
  var vx = [Float](repeating: 0, count: n), vy = [Float](repeating: 0, count: n)
  var seed: UInt64 = 0x2545F4914F6CDD1D
  for i in 0..<n {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    px[i] = Float(seed % 1000); py[i] = Float((seed >> 20) % 500) + 1
    vx[i] = Float((seed >> 40) % 20) - 10; vy[i] = Float((seed >> 45) % 20) - 10
  }
  let t0 = nowMs()
  for _ in 0..<steps { await step(&px, &py, &vx, &vy, n, 0.016) }
  var acc: Float = 0
  for i in stride(from: 0, to: n, by: 997) { acc += px[i] + py[i] }
  emit("particles", nowMs() - t0, Int(acc))
}

@main struct Bench {
  ATTR static func main() async {
    await detached { await body() }
  }
}
