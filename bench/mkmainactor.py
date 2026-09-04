#!/usr/bin/env python3
"""Generate the 'mainactor' variant: the workload sits directly in @main's
MainActor-isolated entry point instead of running in a detached task."""
import re, sys
src, dst = sys.argv[1], sys.argv[2]
attr = sys.argv[3] + " " if len(sys.argv) > 3 else ""
s = open(src).read()
m = re.search(r'ATTR func body\(\) async \{\n(.*?)\n\}\n\n@main struct Bench \{\n  ATTR static func main\(\) async \{\n    await detached \{ await body\(\) \}\n  \}\n\}\n', s, re.S)
assert m, "unexpected layout in " + src
inner = "\n".join(("    " + l) if l.strip() else l for l in m.group(1).split("\n"))
s = s[:m.start()] + "@main struct Bench {\n  ATTR static func main() async {\n" + inner + "\n  }\n}\n"
open(dst, "w").write(s.replace("ATTR ", attr))
