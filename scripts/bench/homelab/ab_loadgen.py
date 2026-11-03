#!/usr/bin/env python3
"""A/B one gateway point across loadgen shapes, interleaved (A B A B ...).

Isolates the loadgen from everything else: same gateway pod, same session
count, same inference; only the loadgen shape changes between points. A shape
is CPUS[:THREADS[:CPUSET[:VERIFY_EVERY]]] (CPUSET = taskset list; empty =
unpinned; VERIFY_EVERY defaults to 1).
  scripts/bench/homelab/ab_loadgen.py --out results/homelab/ab-loadgen \
      --shapes 8,16:16:16-31 --rounds 2 rustSync:3800 cpp23UWebsockets:3650
"""
import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sweep import ALL, CTX, NS, Sweep, sh  # noqa: E402

# Host CPU groups on cezar-4090 (i9-13900F): P-core hyperthread pairs 0-15, E-cores 16-31.
GROUPS = {"gw0,2": (0, 2), "P0-3": range(0, 4), "P4-11": range(4, 12), "P12-15": range(12, 16), "E16-31": range(16, 32)}


def proc_stat():
    """Per-CPU (busy, total, irq+softirq) jiffies from /proc/stat, read in the cpu-sampler pod (host-wide)."""
    r = sh(["kubectl", "--context", CTX, "-n", NS, "--request-timeout=20s", "exec", "cpu-sampler",
            "--", "cat", "/proc/stat"])
    out = {}
    for line in r.stdout.splitlines():
        f = line.split()
        if f and f[0].startswith("cpu") and f[0] != "cpu":
            v = [int(x) for x in f[1:]]
            out[int(f[0][3:])] = (sum(v) - v[3] - v[4], sum(v), v[5] + v[6])
    return out


class PinSweep(Sweep):
    """Sweep whose CPU window also snapshots per-host-CPU busy time."""

    snaps = []

    def cadvisor(self):
        self.snaps.append(proc_stat())
        return super().cadvisor()

    def groups(self):
        if len(self.snaps) < 2:
            return {}
        a, b = self.snaps[-2], self.snaps[-1]
        res = {}
        for g, cpus in GROUPS.items():
            cpus = [c for c in cpus if c in a and c in b]
            busy = sum((b[c][0] - a[c][0]) / max(1, b[c][1] - a[c][1]) for c in cpus)
            irq = sum((b[c][2] - a[c][2]) / max(1, b[c][1] - a[c][1]) for c in cpus)
            res[g] = round(busy, 2)
            res[g + " irq"] = round(irq, 2)
        return res


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--placement", default="values-colocated.yaml")
    p.add_argument("--image-tag", default="colocated-rerun")
    p.add_argument("--shapes", default="8,12")
    p.add_argument("--rounds", type=int, default=2)
    p.add_argument("--loadgen-tag", default=None, help="loadgen image tag (default: --image-tag)")
    p.add_argument("--gw-variant", action="append", default=[],
                   help="extra chart --set entries for the gateway, ';'-separated; repeat to A/B "
                        "gateway configs (each round redeploys the gateway per variant)")
    p.add_argument("points", nargs="+", help="key:sessions")
    a = p.parse_args()
    a.verify_every, a.loadgen_cpu = 1, 0
    a.loadgen_threads, a.loadgen_cpuset = None, None
    sw = PinSweep(a)
    shapes = [(sh.split(":") + ["", "", ""])[:4] for sh in a.shapes.split(",")]
    for spec in a.points:
        key, n = spec.split(":")
        n = int(n)
        svc, port = ALL[key][:2]
        chart_key, extra = (ALL[key][3], ALL[key][4]) if len(ALL[key]) > 3 else (key, [])
        fh = open(sw.out / f"{key}.log", "a")
        pts = open(sw.out / f"{key}.points.jsonl", "a")
        variants = [v.split(";") for v in a.gw_variant] or [[]]
        try:
            for _ in range(a.rounds):
                for v in variants:
                    if len(variants) > 1 or _ == 0:
                        sw.helm(chart_key, 0)
                        sw.helm(chart_key, 1, extra + v)
                        sw.wait_ready(svc)
                        time.sleep(10)
                    for c, t, cs, ve in shapes:
                        sw.a.loadgen_cpu, sw.a.loadgen_threads, sw.a.loadgen_cpuset = int(c), int(t or c), cs
                        sw.a.verify_every = int(ve or 1)
                        sw.log(f"{key} {n} gw={v or '-'} loadgen cpu={c} threads={t or c} cpuset={cs or '-'} "
                               f"verify_every={sw.a.verify_every}", fh)
                        sw.point(key, svc, port, n, fh, pts)
                        sw.log(f"{key} {n} busy host CPUs by group {sw.groups()}", fh)
                    # Keep the gateway's own log (e.g. GC logs) before it is redeployed.
                    vi = variants.index(v)
                    logs = sh(["kubectl", "--context", CTX, "-n", NS, "logs", "-l", f"app={svc}",
                               "-c", "gateway", "--tail=-1"])
                    (sw.out / f"{key}-r{_}-v{vi}.gateway.log").write_text(logs.stdout)
        finally:
            sw.helm(chart_key, 0)


if __name__ == "__main__":
    main()
