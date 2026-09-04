@inline(never) func f(_ x: Int) async -> Int { x &+ 1 }
@main struct M { static func main() async {
  var a = 0
  for _ in 0..<100_000 { a = await f(a) }
  print(a)
} }
