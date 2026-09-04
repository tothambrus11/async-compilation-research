#!/usr/bin/env python3
"""Run the wasm32 benchmarks in headless Google Chrome and collect the results.

Serves this directory over HTTP, opens run.html once per module in a fresh
headless Chrome, and waits for the page to POST its result back.

Usage: ./run_chrome.py [--reps N] [--timeout S] [--chrome PATH] [module ...]
"""
import argparse, http.server, json, os, queue, shutil, socketserver, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)
RESULTS = queue.Queue()


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        RESULTS.put(json.loads(self.rfile.read(n)))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


def serve():
    httpd = socketserver.TCPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, httpd.server_address[1]


def run_one(chrome, port, mod, scale, reps, timeout):
    profile = tempfile.mkdtemp(prefix="chrome-bench-")
    url = "http://127.0.0.1:%d/run.html?mod=%s&scale=%s&reps=%d" % (port, mod, scale, reps)
    proc = subprocess.Popen(
        [chrome, "--headless", "--disable-gpu", "--no-sandbox", "--no-first-run",
         "--user-data-dir=" + profile, "--disable-dev-shm-usage", url],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        return RESULTS.get(timeout=timeout)
    except queue.Empty:
        return {"mod": mod, "trap": "no result within %ds" % timeout, "wallMs": None, "stdout": ""}
    finally:
        proc.kill()
        proc.wait()
        shutil.rmtree(profile, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--scale", default="1")
    ap.add_argument("--chrome", default=shutil.which("google-chrome") or shutil.which("chromium"))
    ap.add_argument("modules", nargs="*")
    a = ap.parse_args()
    if not a.chrome:
        sys.exit("no chrome found; pass --chrome PATH")

    mods = a.modules or sorted(f[:-5] for f in os.listdir(".") if f.endswith(".wasm"))
    httpd, port = serve()
    version = subprocess.run([a.chrome, "--version"], capture_output=True, text=True).stdout.strip()
    out = {"chrome": version, "date": time.strftime("%Y-%m-%d %H:%M:%S%z"),
           "reps": a.reps, "scale": a.scale, "runs": {}}
    for m in mods:
        r = run_one(a.chrome, port, m, a.scale, a.reps, a.timeout)
        out["runs"][m] = r
        ms = r.get("stdout", "").split("\t")
        inner = ms[1][:8] if len(ms) > 2 else "-"
        print("%-24s wall %-10s inner %-10s %s" % (
            m, ("%.1f" % r["wallMs"]) if r.get("wallMs") else "-", inner, r.get("trap") or ""))
    json.dump(out, open("results_chrome.json", "w"), indent=1)
    write_table(out)
    httpd.shutdown()


def inner_ms(run):
    """The benchmark's own timing of the workload, excluding instantiation."""
    parts = run.get("stdout", "").split("\t")
    return float(parts[1]) if len(parts) > 2 else None


def write_table(out):
    runs = out["runs"]
    bases = sorted({m.rsplit("_", 1)[0] for m in runs})
    L = ["| program | variant | sync ms | async ms | ratio |", "|---|---|---:|---:|---:|"]
    for b in bases:
        for suffix, label in (("", "inlining allowed"), ("ni", "no inlining")):
            s, a = runs.get(b + "_sync" + suffix), runs.get(b + "_async" + suffix)
            if not s or not a:
                continue
            sm, am = inner_ms(s), inner_ms(a)
            if sm is None:
                continue
            if am is None:
                L.append("| %s | %s | %.1f | trap | **%s** |" % (b, label, sm, a.get("trap", "failed")))
            else:
                L.append("| %s | %s | %.1f | %.1f | **%.2fx** |" % (b, label, sm, am, am / sm))
    L.append("")
    L.append("%s, %s, min of %d runs, scale %s." % (out["chrome"], out["date"], out["reps"], out["scale"]))
    open("results_chrome.md", "w").write("\n".join(L) + "\n")
    doc_path = os.path.join(HERE, "..", "RESULTS.md")
    doc = open(doc_path).read()
    import re
    doc = re.sub(r"<!-- BEGIN WASM -->.*?<!-- END WASM -->",
                 lambda m: "<!-- BEGIN WASM -->\n" + "\n".join(L) + "\n<!-- END WASM -->",
                 doc, flags=re.S)
    open(doc_path, "w").write(doc)


main()
