#!/usr/bin/env python3
"""Is the loadgen's lag per-process or per-machine? Same gateway, same total
sessions, same loadgen CPUs; only the number of loadgen processes changes.

  A: 1 loadgen x N sessions on CPUSET
  B: K loadgens x N/K sessions, CPUSET split into K equal slices, run concurrently

Each process reports its own `harness_lag`; if B's lag is much lower than A's
on the same CPUs, the limit is inside one loadgen process, not CPU or kernel.
  scripts/bench/homelab/split_loadgen.py --out results/homelab/split --sessions 6000 \
      --cpus 4-11 --procs 2 --rounds 2 --gw-variant "..." rust
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ab_loadgen import PinSweep  # noqa: E402
from sweep import ALL, CTX, NODE, NS, REPO  # noqa: E402


def cpu_list(spec):
    out = []
    for part in spec.split("+"):
        lo, _, hi = part.partition("-")
        out += list(range(int(lo), int(hi or lo) + 1))
    return out


def run_points(sw, svc, port, label, jobs):
    """Start one run_point.sh per (sessions, cpus) concurrently; return their last lines."""
    procs = []
    for i, (n, cpus) in enumerate(jobs):
        env = dict(os.environ, SVC=svc, PORT=str(port), LABEL=f"{label}-p{i}", CTX=CTX, NS=NS,
                   LOADGEN_IMG=f"ghcr.io/cezarc1/websocket-stt-bench/loadgen:{sw.a.loadgen_tag}",
                   LOADGEN_NODE=NODE, RESULTS_DIR=str(sw.out), VERIFY_EVERY="1",
                   LOADGEN_CPU=str(len(cpus)), LOADGEN_MEM=f"{len(cpus)}Gi",
                   LOADGEN_THREADS=str(len(cpus)), LOADGEN_CPUSET=",".join(map(str, cpus)))
        procs.append(subprocess.Popen(["bash", str(REPO / "scripts/bench/run_point.sh"), str(n)],
                                      env=env, text=True, stdout=subprocess.PIPE,
                                      stderr=subprocess.DEVNULL))
    # run_point: sleep 5 + ramp 30 + warmup 10, then a 45 s measured window.
    time.sleep(5 + 30 + 10 + 10)
    sw.cadvisor()
    time.sleep(30)
    sw.cadvisor()
    return [(p.communicate()[0].strip().splitlines() or ["<no output>"])[-1] for p in procs]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--placement", default="values-colocated.yaml")
    p.add_argument("--image-tag", default="colocated-rerun")
    p.add_argument("--loadgen-tag", default="harness-lag")
    p.add_argument("--sessions", type=int, required=True)
    p.add_argument("--cpus", default="4-11", help="loadgen CPUs, ranges joined with '+'")
    p.add_argument("--procs", type=int, default=2)
    p.add_argument("--rounds", type=int, default=2)
    p.add_argument("--gw-variant", default="", help="';'-separated chart --set entries")
    p.add_argument("key")
    a = p.parse_args()
    a.verify_every, a.loadgen_cpu, a.loadgen_threads, a.loadgen_cpuset = 1, 0, None, None
    sw = PinSweep(a)
    svc, port = ALL[a.key][:2]
    chart_key = ALL[a.key][3] if len(ALL[a.key]) > 3 else a.key
    cpus = cpu_list(a.cpus)
    k = a.procs
    assert len(cpus) % k == 0 and a.sessions % k == 0
    w = len(cpus) // k
    shapes = {"one": [(a.sessions, cpus)],
              f"split{k}": [(a.sessions // k, cpus[i * w:(i + 1) * w]) for i in range(k)]}
    fh = open(sw.out / f"{a.key}.log", "a")
    try:
        sw.helm(chart_key, 0)
        sw.helm(chart_key, 1, [v for v in a.gw_variant.split(";") if v])
        sw.wait_ready(svc)
        time.sleep(10)
        for r in range(a.rounds):
            for name, jobs in shapes.items():
                sw.log(f"{a.key} {a.sessions} r{r} {name}: {[(n, f'{c[0]}-{c[-1]}') for n, c in jobs]}", fh)
                for line in run_points(sw, svc, port, f"{a.key}-{name}-r{r}", jobs):
                    sw.log(f"{a.key} {name}   {line}", fh)
                sw.log(f"{a.key} {name} busy host CPUs by group {sw.groups()}", fh)
    finally:
        sw.helm(chart_key, 0)


if __name__ == "__main__":
    main()
