// Minimal WASI preview1 shim: enough to run a Swift command module that prints
// to stdout, reads argv and asks for a monotonic clock. Browser-only, no Node APIs.
export class WASI {
  constructor(args) {
    this.args = args;
    this.stdout = "";
    this.exitCode = null;
    this.memory = null;
    this.enc = new TextEncoder();
    this.dec = new TextDecoder();
  }
  view() { return new DataView(this.memory.buffer); }
  bytes() { return new Uint8Array(this.memory.buffer); }

  get imports() {
    const ok = 0, badf = 8, nosys = 52;
    const self = this;
    return {
      args_sizes_get(cnt, size) {
        const v = self.view();
        v.setUint32(cnt, self.args.length, true);
        v.setUint32(size, self.args.reduce((n, a) => n + self.enc.encode(a).length + 1, 0), true);
        return ok;
      },
      args_get(ptrs, buf) {
        const v = self.view(), b = self.bytes();
        let p = buf;
        self.args.forEach((a, i) => {
          v.setUint32(ptrs + 4 * i, p, true);
          const e = self.enc.encode(a);
          b.set(e, p); p += e.length;
          b[p++] = 0;
        });
        return ok;
      },
      environ_sizes_get(cnt, size) { const v = self.view(); v.setUint32(cnt, 0, true); v.setUint32(size, 0, true); return ok; },
      environ_get() { return ok; },
      clock_time_get(id, prec, out) {
        // performance.now() is milliseconds with sub-microsecond resolution
        self.view().setBigUint64(out, BigInt(Math.round(performance.now() * 1e6)), true);
        return ok;
      },
      clock_res_get(id, out) { self.view().setBigUint64(out, 1000n, true); return ok; },
      fd_write(fd, iovs, n, out) {
        const v = self.view(), b = self.bytes();
        let written = 0;
        for (let i = 0; i < n; i++) {
          const p = v.getUint32(iovs + 8 * i, true), len = v.getUint32(iovs + 8 * i + 4, true);
          self.stdout += self.dec.decode(b.subarray(p, p + len));
          written += len;
        }
        v.setUint32(out, written, true);
        return ok;
      },
      fd_read() { return badf; },
      fd_close() { return ok; },
      fd_seek() { return badf; },
      fd_fdstat_get(fd, out) { const v = self.view(); v.setUint8(out, 2); v.setUint16(out + 2, 0, true); v.setBigUint64(out + 8, 0n, true); v.setBigUint64(out + 16, 0n, true); return ok; },
      fd_fdstat_set_flags() { return ok; },
      fd_prestat_get() { return badf; },
      fd_prestat_dir_name() { return badf; },
      path_open() { return nosys; },
      random_get(buf, len) { crypto.getRandomValues(self.bytes().subarray(buf, buf + len)); return ok; },
      poll_oneoff() { return nosys; },
      sched_yield() { return ok; },
      proc_exit(code) { self.exitCode = code; throw new ExitStatus(code); },
    };
  }
}
export class ExitStatus extends Error {
  constructor(code) { super("exit " + code); this.code = code; }
}

export async function runModule(url, args) {
  const wasi = new WASI(args);
  const bytes = await (await fetch(url)).arrayBuffer();
  const t0 = performance.now();
  const { instance } = await WebAssembly.instantiate(bytes, { wasi_snapshot_preview1: wasi.imports });
  const compileMs = performance.now() - t0;
  wasi.memory = instance.exports.memory;
  let trap = null;
  const t1 = performance.now();
  try {
    instance.exports._start();
  } catch (e) {
    if (!(e instanceof ExitStatus)) trap = String(e && e.message ? e.message : e);
  }
  return { stdout: wasi.stdout, trap, compileMs, wallMs: performance.now() - t1 };
}
