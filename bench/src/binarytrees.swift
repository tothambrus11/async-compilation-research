final class Node {
  var l: Node?
  var r: Node?
  init(_ l: Node?, _ r: Node?) { self.l = l; self.r = r }
}

ATTR func makeTree(_ depth: Int) async -> Node {
  if depth <= 0 { return Node(nil, nil) }
  let l = await makeTree(depth &- 1)
  let r = await makeTree(depth &- 1)
  return Node(l, r)
}

ATTR func checkTree(_ n: Node) async -> Int {
  guard let l = n.l, let r = n.r else { return 1 }
  let a = await checkTree(l)
  let b = await checkTree(r)
  return 1 &+ a &+ b
}

ATTR func body() async {
  let s = scaleArg()
  let maxDepth = s > 1 ? 12 : 16
  let t0 = nowMs()
  var total = 0
  let stretch = await makeTree(maxDepth &+ 1)
  total &+= await checkTree(stretch)
  let longLived = await makeTree(maxDepth)
  var d = 4
  while d <= maxDepth {
    let iterations = 1 << (maxDepth &- d &+ 4)
    var c = 0
    for _ in 0..<iterations {
      let t = await makeTree(d)
      let cc = await checkTree(t)
      c &+= cc
    }
    total &+= c
    d &+= 2
  }
  total &+= await checkTree(longLived)
  emit("binarytrees", nowMs() - t0, total)
}

@main struct Bench {
  ATTR static func main() async {
    await detached { await body() }
  }
}
