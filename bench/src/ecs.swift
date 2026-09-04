ATTR func applyVelocity(_ x: inout Float, _ y: inout Float, _ vx: Float, _ vy: Float, _ dt: Float) async {
  x += vx * dt
  y += vy * dt
}

ATTR func applyDamage(_ hp: inout Int32, _ dmg: Int32) async -> Bool {
  hp -= dmg
  return hp <= 0
}

ATTR func regen(_ hp: inout Int32, _ maxHp: Int32) async {
  if hp > 0 && hp < maxHp { hp += 1 }
}

ATTR func aiTick(_ state: inout Int32, _ x: Float, _ y: Float) async {
  let target: Int32 = (x + y) > 512 ? 1 : 0
  if state != target { state = target } else { state = (state &+ 1) & 3 }
}

ATTR func systemMovement(_ x: inout [Float], _ y: inout [Float], _ vx: [Float], _ vy: [Float], _ n: Int, _ dt: Float) async {
  for i in 0..<n { await applyVelocity(&x[i], &y[i], vx[i], vy[i], dt) }
}

ATTR func systemCombat(_ hp: inout [Int32], _ dmg: [Int32], _ n: Int) async -> Int {
  var deaths = 0
  for i in 0..<n {
    let dead = await applyDamage(&hp[i], dmg[i])
    if dead { deaths &+= 1 }
  }
  return deaths
}

ATTR func systemRegen(_ hp: inout [Int32], _ n: Int) async {
  for i in 0..<n { await regen(&hp[i], 100) }
}

ATTR func systemAI(_ state: inout [Int32], _ x: [Float], _ y: [Float], _ n: Int) async {
  for i in 0..<n { await aiTick(&state[i], x[i], y[i]) }
}

ATTR func body() async {
  let s = scaleArg()
  let n = 100_000
  let ticks = max(1, 240 / s)
  var x = [Float](repeating: 0, count: n), y = [Float](repeating: 0, count: n)
  var vx = [Float](repeating: 0, count: n), vy = [Float](repeating: 0, count: n)
  var hp = [Int32](repeating: 100, count: n), dmg = [Int32](repeating: 0, count: n)
  var state = [Int32](repeating: 0, count: n)
  var seed: UInt64 = 1234567
  for i in 0..<n {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    x[i] = Float(seed % 1024); y[i] = Float((seed >> 16) % 1024)
    vx[i] = Float((seed >> 32) % 8) - 4; vy[i] = Float((seed >> 40) % 8) - 4
    dmg[i] = Int32((seed >> 48) % 2)
  }
  let t0 = nowMs()
  var deaths = 0
  for _ in 0..<ticks {
    await systemMovement(&x, &y, vx, vy, n, 0.016)
    deaths &+= await systemCombat(&hp, dmg, n)
    await systemRegen(&hp, n)
    await systemAI(&state, x, y, n)
  }
  emit("ecs", nowMs() - t0, deaths)
}

@main struct Bench {
  ATTR static func main() async {
    await detached { await body() }
  }
}
