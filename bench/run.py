#!/usr/bin/env python3
"""Run every benchmark variant, verify the variants agree, write results.json,
and regenerate the tables in RESULTS.md.

Usage: ./run.py [--reps N] [--cpu N] [name ...]
"""
import argparse, json, os, platform, re, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)

PROGRAMS = "fib nbody particles collision ecs astar parser sort matmul binarytrees".split()
VARIANTS = ["sync", "async", "syncni", "asyncni", "mainactor", "mainactorni"]
# Calls that cross an executor cost ~1000x a same-executor call, so the mainactor
# variant of the call microbenchmark runs a 200x smaller workload.
MAINACTOR_SCALE = {"microcall": 200}
# Analytic call counts, used to derive a per-call cost from whole programs.
CALLS = {"fib": 2 * 63245986 - 1, "particles": 200_000 * 240 * 6,
         "ecs": 100_000 * 240 * 4, "microcall": 20_000_000}

def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()

def environment():
    cpu = ""
    for line in open("/proc/cpuinfo"):
        if line.startswith("model name"):
            cpu = line.split(":", 1)[1].strip(); break
    def read(path, default="?"):
        try:
            return open(path).read().strip()
        except OSError:
            return default
    khz = read("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq", "0")
    power = {"governor": read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
             "max_mhz": (int(khz) // 1000) if khz.isdigit() else "?",
             "platform_profile": read("/sys/firmware/acpi/platform_profile"),
             "on_ac": next((read(d + "/online") for d in __import__("glob").glob("/sys/class/power_supply/*")
                            if read(d + "/type") == "Mains"), "?")}
    return {"date": time.strftime("%Y-%m-%d %H:%M:%S%z"), "power": power,
            "swift": sh(["swift", "--version"]).replace("\n", " | "),
            "cpu": cpu, "cores": os.cpu_count(),
            "kernel": platform.release(), "arch": platform.machine(),
            "flags": os.environ.get("FLAGS", "-O -parse-as-library -wmo")}

def measure(binary, reps, cpu, scale=None):
    cmd = ["taskset", "-c", str(cpu), "./bin/" + binary] + ([str(scale)] if scale else [])
    rows = []
    for _ in range(reps):
        out = subprocess.run(cmd, capture_output=True, text=True)
        if out.returncode != 0:
            raise SystemExit("%s failed: %s" % (binary, out.stderr[:400]))
        rows.append([l.split("\t") for l in out.stdout.strip().split("\n")])
    series = {}
    for rep in rows:
        for name, ms, cks in rep:
            series.setdefault(name, {"ms": [], "cksum": set()})
            series[name]["ms"].append(float(ms))
            series[name]["cksum"].add(cks)
    return {k: {"min": min(v["ms"]), "median": statistics.median(v["ms"]),
                "cksum": sorted(v["cksum"])} for k, v in series.items()}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reps", type=int, default=7)
    ap.add_argument("--cpu", type=int, default=2)
    ap.add_argument("names", nargs="*")
    a = ap.parse_args()
    names = a.names or PROGRAMS + ["microcall"]

    res = {}
    for n in names:
        res[n] = {}
        for v in VARIANTS:
            scale = MAINACTOR_SCALE.get(n) if v.startswith("mainactor") else None
            r = measure("%s_%s" % (n, v), a.reps, a.cpu, scale)
            assert len(r) == 1, n
            res[n][v] = dict(list(r.values())[0], scale=scale)
        # a variant that computes something different is a broken measurement
        cks = {tuple(res[n][v]["cksum"]) for v in VARIANTS if not res[n][v]["scale"]}
        assert len(cks) == 1, "checksum mismatch in %s: %s" % (n, cks)
    if not a.names:
        res["microyield"] = measure("microyield_async", a.reps, a.cpu)

    sizes = {n: {v: os.path.getsize("bin/%s_%s" % (n, v)) for v in VARIANTS} for n in names}
    out = {"env": environment(), "reps": a.reps, "programs": res, "sizes": sizes}
    json.dump(out, open("results.json", "w"), indent=1)
    write_tables(out)
    print(open("results_tables.md").read())

def write_tables(out):
    res, sizes = out["programs"], out["sizes"]
    L = []
    L.append("| program | sync ms | async ms | ratio | sync-NI ms | async-NI ms | ratio |")
    L.append("|---|---:|---:|---:|---:|---:|---:|")
    for n in PROGRAMS:
        if n not in res: continue
        d = res[n]
        L.append("| %s | %.0f | %.0f | **%.2fx** | %.0f | %.0f | **%.2fx** |" % (
            n, d["sync"]["min"], d["async"]["min"], d["async"]["min"] / d["sync"]["min"],
            d["syncni"]["min"], d["asyncni"]["min"], d["asyncni"]["min"] / d["syncni"]["min"]))
    L.append("")
    L.append("Per-call unit costs, from `microcall` (20M calls of a one-argument function):")
    L.append("")
    L.append("| call kind | ns per call |")
    L.append("|---|---:|")
    if "microcall" in res:
        m, N = res["microcall"], CALLS["microcall"]
        for label, v, scale in [("sync, inlined", "sync", 1), ("async, inlined", "async", 1),
                                ("sync, not inlinable", "syncni", 1),
                                ("async, not inlinable", "asyncni", 1),
                                ("async, not inlinable, called from an actor-isolated function",
                                 "mainactorni", MAINACTOR_SCALE["microcall"])]:
            L.append("| %s | %.2f |" % (label, m[v]["min"] * 1e6 / (N / scale)))
        L.append("| **added cost of async, not inlinable** | **%.2f** |" % (
            (m["asyncni"]["min"] - m["syncni"]["min"]) * 1e6 / N))
    if "microyield" in res:
        y = res["microyield"]
        L.append("| real suspension and resume (`Task.yield()`) | %.0f |" % (y["microyield.yield"]["min"] * 1e6 / 2e6))
    L.append("")
    L.append("Cost of running the workload in an actor-isolated entry point instead of a detached task,")
    L.append("with the async callees inlined into it (`mainactor`) and prevented from inlining (`mainactor-NI`):")
    L.append("")
    L.append("| program | async ms | mainactor ms | ratio | async-NI ms | mainactor-NI ms | ratio |")
    L.append("|---|---:|---:|---:|---:|---:|---:|")
    for n in PROGRAMS:
        if n not in res: continue
        d = res[n]
        L.append("| %s | %.0f | %.0f | **%.2fx** | %.0f | %.0f | **%.2fx** |" % (
            n, d["async"]["min"], d["mainactor"]["min"], d["mainactor"]["min"] / d["async"]["min"],
            d["asyncni"]["min"], d["mainactorni"]["min"], d["mainactorni"]["min"] / d["asyncni"]["min"]))
    L.append("")
    L.append("Per-call cost derived from whole programs, using analytic call counts:")
    L.append("")
    L.append("| program | extra ms (not inlinable) | calls | ns per call |")
    L.append("|---|---:|---:|---:|")
    for n, c in CALLS.items():
        if n not in res or n == "microcall": continue
        extra = res[n]["asyncni"]["min"] - res[n]["syncni"]["min"]
        L.append("| %s | %.0f | %d | %.1f |" % (n, extra, c, extra * 1e6 / c))
    L.append("")
    L.append("Binary size, bytes:")
    L.append("")
    L.append("| program | sync | async | growth |")
    L.append("|---|---:|---:|---:|")
    for n in PROGRAMS:
        if n not in sizes: continue
        s, b = sizes[n]["sync"], sizes[n]["async"]
        L.append("| %s | %d | %d | %+.0f%% |" % (n, s, b, 100.0 * (b - s) / s))
    L.append("")
    e = out["env"]
    p = e.get("power", {})
    L.append("Measured %s on %s (%s cores, %s, %s), governor `%s`, profile `%s`, max %s MHz, "
             "%s, `%s`, min of %d runs, pinned to one core." % (
        e["date"], e["cpu"], e["cores"], e["arch"], e["kernel"], p.get("governor"),
        p.get("platform_profile"), p.get("max_mhz"), e["swift"], e["flags"], out["reps"]))
    open("results_tables.md", "w").write("\n".join(L) + "\n")
    # splice into RESULTS.md between markers
    doc = open("RESULTS.md").read()
    doc = re.sub(r"<!-- BEGIN RESULTS -->.*?<!-- END RESULTS -->",
                 lambda m: "<!-- BEGIN RESULTS -->\n" + "\n".join(L) + "\n<!-- END RESULTS -->",
                 doc, flags=re.S)
    open("RESULTS.md", "w").write(doc)

main()
