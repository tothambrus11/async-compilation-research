struct P { var i: Int }

ATTR func isDigit(_ c: UInt8) async -> Bool { c >= 48 && c <= 57 }
ATTR func isWS(_ c: UInt8) async -> Bool { c == 32 || c == 10 || c == 9 || c == 13 }

ATTR func skipWS(_ b: [UInt8], _ p: inout P) async {
  while p.i < b.count {
    let ws = await isWS(b[p.i])
    if !ws { break }
    p.i &+= 1
  }
}

ATTR func parseNumber(_ b: [UInt8], _ p: inout P) async -> Int {
  var v = 0
  var neg = false
  if b[p.i] == 45 { neg = true; p.i &+= 1 }
  while p.i < b.count {
    let d = await isDigit(b[p.i])
    if !d { break }
    v = v &* 10 &+ Int(b[p.i] &- 48)
    p.i &+= 1
  }
  return neg ? -v : v
}

ATTR func parseString(_ b: [UInt8], _ p: inout P) async -> Int {
  p.i &+= 1
  var n = 0
  while p.i < b.count && b[p.i] != 34 {
    if b[p.i] == 92 { p.i &+= 1 }
    n &+= 1
    p.i &+= 1
  }
  p.i &+= 1
  return n
}

ATTR func parseValue(_ b: [UInt8], _ p: inout P) async -> Int {
  await skipWS(b, &p)
  let c = b[p.i]
  if c == 123 { return await parseObject(b, &p) }
  if c == 91 { return await parseArray(b, &p) }
  if c == 34 { return await parseString(b, &p) }
  if c == 116 { p.i &+= 4; return 1 }
  if c == 102 { p.i &+= 5; return 0 }
  if c == 110 { p.i &+= 4; return 0 }
  return await parseNumber(b, &p)
}

ATTR func parseArray(_ b: [UInt8], _ p: inout P) async -> Int {
  p.i &+= 1
  var sum = 0
  await skipWS(b, &p)
  if b[p.i] == 93 { p.i &+= 1; return 0 }
  while true {
    sum &+= await parseValue(b, &p)
    await skipWS(b, &p)
    if b[p.i] == 44 { p.i &+= 1 } else { p.i &+= 1; break }
  }
  return sum
}

ATTR func parseObject(_ b: [UInt8], _ p: inout P) async -> Int {
  p.i &+= 1
  var sum = 0
  await skipWS(b, &p)
  if b[p.i] == 125 { p.i &+= 1; return 0 }
  while true {
    await skipWS(b, &p)
    sum &+= await parseString(b, &p)
    await skipWS(b, &p)
    p.i &+= 1
    sum &+= await parseValue(b, &p)
    await skipWS(b, &p)
    if b[p.i] == 44 { p.i &+= 1 } else { p.i &+= 1; break }
  }
  return sum
}

ATTR func buildDoc(_ records: Int) async -> [UInt8] {
  var out = [UInt8]()
  out.reserveCapacity(records * 90)
  out.append(91)
  var seed: UInt64 = 99
  for r in 0..<records {
    if r > 0 { out.append(44) }
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    let head = Array("{\"id\":".utf8)
    out.append(contentsOf: head)
    for ch in Array(String(seed % 100000).utf8) { out.append(ch) }
    out.append(contentsOf: Array(",\"name\":\"entity_".utf8))
    for ch in Array(String(r % 9999).utf8) { out.append(ch) }
    out.append(contentsOf: Array("\",\"pos\":[".utf8))
    for ch in Array(String((seed >> 8) % 1000).utf8) { out.append(ch) }
    out.append(44)
    for ch in Array(String((seed >> 20) % 1000).utf8) { out.append(ch) }
    out.append(contentsOf: Array("],\"active\":true,\"score\":".utf8))
    for ch in Array(String((seed >> 32) % 500).utf8) { out.append(ch) }
    out.append(125)
  }
  out.append(93)
  out.append(0)
  return out
}

ATTR func body() async {
  let s = scaleArg()
  let records = max(100, 60_000 / s)
  let passes = max(1, 30 / s)
  let doc = await buildDoc(records)
  let t0 = nowMs()
  var sum = 0
  for _ in 0..<passes {
    var p = P(i: 0)
    sum &+= await parseValue(doc, &p)
  }
  emit("parser", nowMs() - t0, sum)
}

@main struct Bench {
  ATTR static func main() async {
    await detached { await body() }
  }
}
