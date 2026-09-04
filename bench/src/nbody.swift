let SOLAR: Double = 4.0 * 3.141592653589793 * 3.141592653589793
let DAYS: Double = 365.24

ATTR func advanceOne(_ x: inout [Double], _ y: inout [Double], _ z: inout [Double],
                     _ vx: inout [Double], _ vy: inout [Double], _ vz: inout [Double],
                     _ mass: [Double], _ dt: Double, _ n: Int) async {
  for i in 0..<n {
    for j in (i &+ 1)..<n {
      let dx = x[i] - x[j], dy = y[i] - y[j], dz = z[i] - z[j]
      let d2 = dx*dx + dy*dy + dz*dz
      let mag = dt / (d2 * (d2).squareRoot())
      let mi = mass[i] * mag, mj = mass[j] * mag
      vx[i] -= dx * mj; vy[i] -= dy * mj; vz[i] -= dz * mj
      vx[j] += dx * mi; vy[j] += dy * mi; vz[j] += dz * mi
    }
  }
  for i in 0..<n { x[i] += dt * vx[i]; y[i] += dt * vy[i]; z[i] += dt * vz[i] }
}

ATTR func energy(_ x: [Double], _ y: [Double], _ z: [Double],
                 _ vx: [Double], _ vy: [Double], _ vz: [Double],
                 _ mass: [Double], _ n: Int) async -> Double {
  var e = 0.0
  for i in 0..<n {
    e += 0.5 * mass[i] * (vx[i]*vx[i] + vy[i]*vy[i] + vz[i]*vz[i])
    for j in (i &+ 1)..<n {
      let dx = x[i] - x[j], dy = y[i] - y[j], dz = z[i] - z[j]
      e -= (mass[i] * mass[j]) / (dx*dx + dy*dy + dz*dz).squareRoot()
    }
  }
  return e
}

ATTR func body() async {
  let s = scaleArg()
  let steps = max(1, 3_000_000 / s)
  var x: [Double] = [0, 4.84143144246472090e+00, 8.34336671824457987e+00, 1.28943695621391310e+01, 1.53796971148509165e+01]
  var y: [Double] = [0, -1.16032004402742839e+00, 4.12479856412430479e+00, -1.51111514016986312e+01, -2.59193146099879641e+01]
  var z: [Double] = [0, -1.03622044471123109e-01, -4.03523417114321381e-01, -2.23307578892655734e-01, 1.79258772950371181e-01]
  var vx: [Double] = [0, 1.66007664274403694e-03*DAYS, -2.76742510726862411e-03*DAYS, 2.96460137564761618e-03*DAYS, 2.68067772490389322e-03*DAYS]
  var vy: [Double] = [0, 7.69901118419740425e-03*DAYS, 4.99852801234917238e-03*DAYS, 2.37847173959480950e-03*DAYS, 1.62824170038242295e-03*DAYS]
  var vz: [Double] = [0, -6.90460016972063023e-05*DAYS, 2.30417297573763929e-05*DAYS, -2.96589568540237556e-05*DAYS, -9.51592254519715870e-05*DAYS]
  let mass: [Double] = [SOLAR, 9.54791938424326609e-04*SOLAR, 2.85885980666130812e-04*SOLAR, 4.36624404335156298e-05*SOLAR, 5.15138902046611451e-05*SOLAR]
  let n = 5
  var px = 0.0, py = 0.0, pz = 0.0
  for i in 0..<n { px += vx[i]*mass[i]; py += vy[i]*mass[i]; pz += vz[i]*mass[i] }
  vx[0] = -px/SOLAR; vy[0] = -py/SOLAR; vz[0] = -pz/SOLAR
  let t0 = nowMs()
  for _ in 0..<steps {
    await advanceOne(&x, &y, &z, &vx, &vy, &vz, mass, 0.01, n)
  }
  let e = await energy(x, y, z, vx, vy, vz, mass, n)
  emit("nbody", nowMs() - t0, Int(e * 1e9))
}

@main struct Bench {
  ATTR static func main() async {
    await detached { await body() }
  }
}
