#!/usr/bin/env python3
"""Ceiling sweeps on the homelab k3s cluster, one gateway at a time.

For each gateway shape: helm-scale it to 1 replica, verify placement, then
find the highest session count that passes the SLO using the tracked harness
(scripts/bench/run_point.sh; its comparability contract is not changed here):

  probe the prior ceiling -> walk up/down to a pass/fail bracket -> bisect to
  one step -> CONFIRM: the reported ceiling is the highest session count with
  >= 2 passes and 0 fails. A point that has both passes and fails is
  "borderline" and is never reported as the ceiling.

Every point also records:
  * gateway health before/after (a restart or liveness kill during a point
    makes it INVALID; it is re-run once). Cluster-API errors are retried and
    never count as a restart.
  * CPU from the kubelet's cAdvisor endpoint over the measured window: gateway
    cores and CFS-throttled fraction, loadgen cores/throttling, inference cores.
    A point where the loadgen itself is constrained is flagged `loadgen_bound`.

Usage:
  scripts/bench/homelab/sweep.py --out results/homelab/<run> --placement values-colocated.yaml \
      [--image-tag TAG] [--loadgen-cpu 8] [--loadgen-cpuset 4-11] rustSync cpp23UWebsockets ... rustSync-2vcpu ...
Outputs per shape: <key>.points.jsonl, <key>.result.json, <key>.log, plus the
summary/warn files run_point.sh writes (RESULTS_DIR = --out).
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
CTX = "cezar-4090-cluster"
NS = "stt-bench"
NODE = "cezar-4090"

# key: (service, port, prior ceiling) — prior is only the starting probe.
GATEWAYS = {
    "rustSync": ("stt-rust-sync-gateway", 10000, 3950),
    "cpp23UWebsockets": ("stt-cpp23-uwebsockets-gateway", 1500, 3800),
    "rust": ("stt-rust-axum-gateway", 3000, 3250),
    "ocamlOxcamlEpoll": ("stt-ocaml-oxcaml-epoll-gateway", 9200, 2800),
    "javaHelidonNima": ("stt-java-helidon-nima-gateway", 5000, 2400),
    "typescriptBun": ("stt-typescript-bun-gateway", 7000, 2200),
    "goNethttp": ("stt-go-nethttp-gateway", 6000, 2400),
    "ocamlOxcaml": ("stt-ocaml-oxcaml-gateway", 9000, 2050),
    "ocamlWebsocketAsync": ("stt-ocaml-websocket-async-gateway", 9100, 1850),
    "scalaPekko": ("stt-scala-pekko-gateway", 2500, 650),
    "elixir": ("stt-elixir-phoenix-gateway", 4000, 1250),
    "pythonGil315": ("stt-python-fastapi-gil315-gateway", 8000, 1000),
    "pythonFt315": ("stt-python-fastapi-ft315-gateway", 8000, 1000),
}
_CPU2 = ["resources.requests.cpu=2", "resources.limits.cpu=2"]
# 2-vCPU shapes: dedicated -2vcpu chart variants where they exist, else the
# 1-vCPU deployment re-shaped with --set.
GATEWAYS_2V = {
    "rustSync-2vcpu": ("stt-rust-sync-2vcpu-gateway", 10000, 4600, "rustSync2cpu", []),
    "cpp23UWebsockets-2vcpu": ("stt-cpp23-uwebsockets-2vcpu-gateway", 1500, 5200, "cpp23UWebsockets2cpu", []),
    "rust-2vcpu": ("stt-rust-axum-gateway", 3000, 4800, "rust", _CPU2 + ["env.WORKER_THREADS=2"]),
    "ocamlOxcamlEpoll-2vcpu": ("stt-ocaml-oxcaml-epoll-gateway", 9200, 2800, "ocamlOxcamlEpoll", _CPU2),
    "javaHelidonNima-2vcpu": ("stt-java-helidon-nima-2vcpu-gateway", 5000, 3400, "javaHelidonNima2cpu", []),
    "goNethttp-2vcpu": ("stt-go-nethttp-2vcpu-gateway", 6000, 3900, "goNethttp2cpu", []),
    "ocamlOxcaml-2vcpu": ("stt-ocaml-oxcaml-2vcpu-gateway", 9000, 2100, "ocamlOxcaml2cpu", []),
    "ocamlWebsocketAsync-2vcpu": ("stt-ocaml-websocket-async-2vcpu-gateway", 9100, 1850, "ocamlWebsocketAsync2cpu", []),
    "scalaPekko-2vcpu": ("stt-scala-pekko-2vcpu-gateway", 2500, 1150, "scalaPekko2cpu", []),
    "elixir-2vcpu": ("stt-elixir-phoenix-gateway", 4000, 2100, "elixir", _CPU2 + ["env.WORKER_THREADS=2"]),
    "pythonGil315-2vcpu": ("stt-python-fastapi-gil315-gateway", 8000, 1500, "pythonGil315",
                           _CPU2 + ["env.WORKER_THREADS=2", "env.GRANIAN_LOOPS=2"]),
    "pythonFt315-2vcpu": ("stt-python-fastapi-ft315-gateway", 8000, 1500, "pythonFt315",
                          _CPU2 + ["env.WORKER_THREADS=2", "env.GRANIAN_LOOPS=2", "env.GRANIAN_LOOP_KIND=uvloop"]),
}
ALL = {**GATEWAYS, **GATEWAYS_2V}


def sh(args, **kw):
    return subprocess.run(args, text=True, capture_output=True, **kw)


def kubectl(*args, retries=5):
    """kubectl with retries on API errors (never mistake an API hiccup for a pod event)."""
    for attempt in range(retries):
        r = sh(["kubectl", "--context", CTX, "-n", NS, "--request-timeout=20s", *args])
        if r.returncode == 0:
            return r
        time.sleep(3 * (attempt + 1))
    return r


class Sweep:
    def __init__(self, a):
        self.a = a
        self.out = Path(a.out).resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.values = [str(REPO / "charts/stt-bench" / a.placement),
                       str(REPO / "scripts/bench/homelab/values-1vcpu.yaml")]

    def log(self, msg, fh=None):
        line = f"[{time.strftime('%H:%M:%S')}] {msg}"
        print(line, flush=True)
        if fh:
            fh.write(line + "\n")
            fh.flush()

    def helm(self, chart_key, replicas, extra=()):
        args = ["helm", "--kube-context", CTX, "upgrade", "--install", "stt-bench",
                str(REPO / "charts/stt-bench"), "-n", NS]
        for v in self.values:
            args += ["-f", v]
        args += ["--set", f"images.tag={self.a.image_tag}",
                 "--set", f"gateways.{chart_key}.replicas={replicas}"]
        if replicas:
            for x in extra:
                args += ["--set", f"gateways.{chart_key}.{x}"]
        args += ["--wait", "--timeout", "8m"]
        for _ in range(3):
            r = sh(args)
            if r.returncode == 0:
                return
            time.sleep(10)
        raise RuntimeError(f"helm {chart_key}={replicas} failed: {r.stderr[-400:]}")

    # ---- health ----------------------------------------------------------
    def gw_health(self, svc):
        """(ready, restartCount, lastReason, node) or None if the API is unavailable."""
        r = kubectl("get", "pod", "-l", f"app={svc}", "-o", "json")
        if r.returncode != 0:
            return None
        items = json.loads(r.stdout).get("items", [])
        if not items:
            return (False, 0, None, None)
        it = items[0]
        # By name: a pinned pod also runs a cpu-pin sidecar.
        statuses = it["status"].get("containerStatuses") or [{}]
        cs = next((c for c in statuses if c.get("name") == "gateway"), statuses[0])
        last = (cs.get("lastState") or {}).get("terminated") or {}
        return (bool(cs.get("ready")), int(cs.get("restartCount", 0)), last.get("reason"),
                it["spec"].get("nodeName"))

    def wait_ready(self, svc, timeout=300):
        deadline = time.time() + timeout
        while time.time() < deadline:
            h = self.gw_health(svc)
            if h and h[0]:
                return h
            time.sleep(3)
        return None

    # ---- CPU -------------------------------------------------------------
    def cadvisor(self):
        r = sh(["kubectl", "--context", CTX, "--request-timeout=20s", "get", "--raw",
                f"/api/v1/nodes/{NODE}/proxy/metrics/cadvisor"])
        out = {}
        pat = re.compile(r'^(container_cpu_usage_seconds_total|container_cpu_cfs_throttled_periods_total|'
                         r'container_cpu_cfs_periods_total|container_memory_working_set_bytes|'
                         r'container_memory_max_usage_bytes|container_pressure_memory_stalled_seconds_total|'
                         r'container_memory_failcnt)\{([^}]*)\} ([0-9.e+-]+) ([0-9]+)')
        for line in r.stdout.splitlines():
            m = pat.match(line)
            if not m:
                continue
            lab = dict(re.findall(r'(\w+)="([^"]*)"', m.group(2)))
            if lab.get("namespace") != NS or not lab.get("container") or lab.get("cpu", "total") != "total":
                continue
            # Counters are summed per pod under one timestamp; the cpu-pin sidecar
            # is sampled at a different time and would skew the window.
            if lab["container"] == "cpu-pin":
                continue
            d = out.setdefault(lab["pod"], {})
            d[m.group(1)] = d.get(m.group(1), 0.0) + float(m.group(3))
            if m.group(1) == "container_cpu_usage_seconds_total":
                d["ts"] = max(d.get("ts", 0.0), int(m.group(4)) / 1000.0)
        return out

    @staticmethod
    def deltas(s0, s1):
        res = {}
        for pod, v1 in s1.items():
            v0 = s0.get(pod)
            if not v0 or "ts" not in v0 or "ts" not in v1 or v1["ts"] <= v0["ts"]:
                continue
            dt = v1["ts"] - v0["ts"]
            u = (v1.get("container_cpu_usage_seconds_total", 0) - v0.get("container_cpu_usage_seconds_total", 0)) / dt
            per = v1.get("container_cpu_cfs_periods_total", 0) - v0.get("container_cpu_cfs_periods_total", 0)
            thr = v1.get("container_cpu_cfs_throttled_periods_total", 0) - v0.get("container_cpu_cfs_throttled_periods_total", 0)
            res[pod] = {"cores": round(u, 3), "throttled": round(thr / per, 3) if per > 0 else None,
                        # Working set is a gauge: value at the start and end of the window.
                        "mem0_mib": round(v0.get("container_memory_working_set_bytes", 0) / 2**20),
                        "mem1_mib": round(v1.get("container_memory_working_set_bytes", 0) / 2**20),
                        # Peak usage since the container started (includes page cache):
                        # catches a spike between the two samples, e.g. during ramp-up.
                        "peak_mib": round(v1.get("container_memory_max_usage_bytes", 0) / 2**20),
                        # Memory pressure short of an OOM kill: PSI "some" stall time
                        # per second (reclaim stalls) and hits on the cgroup limit.
                        "mem_stall": round((v1.get("container_pressure_memory_stalled_seconds_total", 0)
                                            - v0.get("container_pressure_memory_stalled_seconds_total", 0)) / dt, 4),
                        "mem_limit_hits": int(v1.get("container_memory_failcnt", 0)
                                              - v0.get("container_memory_failcnt", 0))}
        return res

    @staticmethod
    def summarize(d, svc):
        gw = [v for p, v in d.items() if p.startswith(svc + "-")]
        lg = [v for p, v in d.items() if p.startswith("stt-loadgen-")]
        inf = [v for p, v in d.items() if p.startswith("stt-inference-server")]
        return {
            "gw_cores": gw[0]["cores"] if gw else None,
            "gw_throttled": gw[0]["throttled"] if gw else None,
            "gw_mem_mib": [gw[0]["mem0_mib"], gw[0]["mem1_mib"]] if gw else None,
            "gw_peak_mib": gw[0]["peak_mib"] if gw else None,
            "gw_mem_stall": gw[0]["mem_stall"] if gw else None,
            "gw_mem_limit_hits": gw[0]["mem_limit_hits"] if gw else None,
            "loadgen_mem_mib": lg[0]["mem1_mib"] if lg else None,
            "loadgen_cores": lg[0]["cores"] if lg else None,
            "loadgen_throttled": lg[0]["throttled"] if lg else None,
            "inference_cores": round(sum(v["cores"] for v in inf), 3) if inf else None,
            # HTTP/2 connections pin to one replica, so check the busiest one too.
            "inference_max_throttled": max((v["throttled"] or 0) for v in inf) if inf else None,
        }

    # ---- one point ---------------------------------------------------------
    def point_once(self, key, svc, port, n, fh):
        label = (key if key.endswith("-2vcpu") else f"{key}-1vcpu").lower()
        env = dict(os.environ, SVC=svc, PORT=str(port), LABEL=label, CTX=CTX, NS=NS,
                   LOADGEN_IMG=f"ghcr.io/cezarc1/websocket-stt-bench/loadgen:{self.a.loadgen_tag or self.a.image_tag}",
                   LOADGEN_NODE=NODE, RESULTS_DIR=str(self.out), VERIFY_EVERY=str(self.a.verify_every),
                   LOADGEN_CPU=str(self.a.loadgen_cpu), LOADGEN_MEM=f"{self.a.loadgen_cpu}Gi",
                   LOADGEN_THREADS=str(self.a.loadgen_threads or self.a.loadgen_cpu),
                   LOADGEN_CPUSET=self.a.loadgen_cpuset or "")
        proc = subprocess.Popen(["bash", str(REPO / "scripts/bench/run_point.sh"), str(n)],
                                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        cpu = {}
        try:
            job = f"stt-loadgen-{label}-{n}"
            deadline = time.time() + 240
            while time.time() < deadline and proc.poll() is None:
                r = kubectl("get", "pod", "-l", f"job-name={job}", "-o", "jsonpath={.items[0].status.phase}", retries=1)
                if r.stdout.strip() in ("Running", "Succeeded", "Failed"):
                    break
                time.sleep(2)
            # run_point: sleep 5 + ramp 30 + warmup 10, then a 45 s measured window.
            time.sleep(5 + 30 + 10 + 5)
            a = self.cadvisor()
            time.sleep(35)
            b = self.cadvisor()
            cpu = self.summarize(self.deltas(a, b), svc)
        except Exception as e:  # noqa: BLE001
            cpu = {"cpu_error": str(e)}
        out, _ = proc.communicate()
        last = (out.strip().splitlines() or ["<no output>"])[-1]
        ok = re.match(rf"^{n} PASS\b", last) is not None
        m = re.search(r"correctness_err=(\d+)", last)
        return ok, (int(m.group(1)) if m else None), last, cpu

    def point(self, key, svc, port, n, fh, pts, retry=True):
        h0 = self.wait_ready(svc)
        ok, cerr, line, cpu = self.point_once(key, svc, port, n, fh)
        h1 = self.gw_health(svc)
        for _ in range(5):
            if h1 is not None:
                break
            time.sleep(10)
            h1 = self.gw_health(svc)
        rec = {"key": key, "sessions": n, "pass": ok, "line": line, "correctness_errors": cerr,
               "ts": time.time(), **cpu,
               "restarts_before": h0[1] if h0 else None, "restarts_after": h1[1] if h1 else None,
               "last_reason": h1[2] if h1 else None}
        lgc, lgt = cpu.get("loadgen_cores"), cpu.get("loadgen_throttled")
        if (lgt is not None and lgt > 0.02) or (lgc is not None and lgc > 0.85 * self.a.loadgen_cpu):
            rec["loadgen_bound"] = True
        restarted = h0 is None or h1 is None or h1[1] != h0[1]
        # Running out of memory at this load is the gateway failing, not a fluke to retry.
        oom = restarted and h1 is not None and h1[2] == "OOMKilled"
        if oom:
            rec["oom"] = True
            rec["pass"] = False
            ok = False
            restarted = False
        if restarted:
            rec["invalid"] = True
        pts.write(json.dumps(rec) + "\n")
        pts.flush()
        flag = " INVALID(restart/unready)" if restarted else ""
        flag += " LOADGEN-BOUND" if rec.get("loadgen_bound") else ""
        flag += " OOM" if oom else ""
        self.log(f"{key} {line}{flag} | cpu {cpu} restarts {rec['restarts_before']}->{rec['restarts_after']}"
                 f" {rec['last_reason'] or ''}", fh)
        if restarted and retry:
            return self.point(key, svc, port, n, fh, pts, retry=False)
        return None if restarted else ok

    # ---- bracket search ------------------------------------------------------
    @staticmethod
    def step_for(n):
        return 25 if n < 400 else 50 if n < 2000 else 100

    def rnd(self, n, s):
        return max(s, int(round(n / s) * s))

    def sweep(self, key):
        spec = ALL[key]
        svc, port, prior = spec[:3]
        chart_key, extra = (spec[3], spec[4]) if len(spec) > 3 else (key, [])
        fh = open(self.out / f"{key}.log", "a")
        pts = open(self.out / f"{key}.points.jsonl", "a")
        self.log(f"=== {key}: scale up (prior {prior}) tag={self.a.image_tag} placement={self.a.placement} ===", fh)
        self.helm(chart_key, 1, extra)
        h = self.wait_ready(svc)
        if not h or h[3] != NODE:
            self.log(f"{key} ABORT: not ready on {NODE}: {h}", fh)
            self.helm(chart_key, 0)
            return
        time.sleep(10)
        runs = {}  # n -> list[bool]

        def probe(n):
            if n not in runs:
                r = self.point(key, svc, port, n, fh, pts)
                if r is None:  # invalid twice: treat as fail but remember
                    r = False
                runs[n] = [r]
            return runs[n][0]

        try:
            sanity = max(25, self.rnd(prior * 0.25, self.step_for(prior)))
            self.point(key, svc, port, sanity, fh, pts)
            s = self.step_for(prior)
            n = self.rnd(prior, s)
            lo = hi = None
            if probe(n):
                lo = n
                while hi is None and n <= prior * 3:
                    # Rounding to the step can return n itself; always move a full step.
                    n = max(self.rnd(n * 1.1, s), n + s)
                    if probe(n):
                        lo = n
                    else:
                        hi = n
            else:
                hi = n
                while lo is None and n > s:
                    n = min(self.rnd(n * 0.85, s), n - s)
                    if probe(n):
                        lo = n
                    else:
                        hi = n
            while lo is not None and hi is not None and hi - lo > self.step_for(lo):
                half = max(1, self.step_for(lo) // 2)
                mid = self.rnd((lo + hi) / 2, half)
                if mid in (lo, hi):
                    break
                if probe(mid):
                    lo = mid
                else:
                    hi = mid
            # Confirm: walk passing points from the top until one has >= 2 passes, 0 fails.
            confirmed = None
            cand = lo
            while cand is not None and cand > 0:
                while sum(runs.get(cand, [])) < 2 and False not in runs.get(cand, []):
                    r = self.point(key, svc, port, cand, fh, pts)
                    runs.setdefault(cand, []).append(bool(r))
                if False not in runs[cand]:
                    confirmed = cand
                    break
                self.log(f"{key} {cand} borderline {runs[cand]}", fh)
                lower = [k for k, v in runs.items() if k < cand and v and all(v)]
                cand = max(lower) if lower else cand - self.step_for(cand)
                if cand <= 0:
                    break
                if cand not in runs:
                    runs[cand] = [bool(self.point(key, svc, port, cand, fh, pts))]
                    if not runs[cand][0]:
                        continue
            above = sorted(k for k, v in runs.items() if confirmed is None or k > confirmed)
            first_fail = next((k for k in above if not any(runs[k])), None)
            borderline = {str(k): runs[k] for k in above if any(runs[k]) and not all(runs[k])}
            res = {"key": key, "prior": prior, "confirmed": confirmed, "first_solid_fail": first_fail,
                   "borderline": borderline, "runs": {str(k): v for k, v in sorted(runs.items())},
                   "image_tag": self.a.image_tag, "placement": self.a.placement}
            (self.out / f"{key}.result.json").write_text(json.dumps(res, indent=2))
            self.log(f"=== {key} RESULT confirmed={confirmed} first_solid_fail={first_fail} "
                     f"borderline={borderline} ===", fh)
        finally:
            self.helm(chart_key, 0)
            self.log(f"{key} scaled to 0", fh)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--placement", default="values-colocated.yaml")
    p.add_argument("--image-tag", default="colocated-rerun")
    p.add_argument("--loadgen-tag", default=None)
    # cezar-4090 layout (see charts/stt-bench/values-colocated.yaml): the loadgen
    # owns P-cores 4-11 with one Tokio worker per CPU. Pass --loadgen-cpuset ""
    # to run it unpinned.
    p.add_argument("--loadgen-cpu", type=int, default=8)
    p.add_argument("--loadgen-threads", type=int, default=None, help="default: --loadgen-cpu")
    p.add_argument("--loadgen-cpuset", default="4-11", help="taskset CPU list for the loadgen")
    p.add_argument("--verify-every", type=int, default=1)
    p.add_argument("keys", nargs="*")
    a = p.parse_args()
    sw = Sweep(a)
    for k in a.keys or list(ALL):
        if k not in ALL:
            sys.exit(f"unknown key {k}")
        try:
            sw.sweep(k)
        except Exception as e:  # noqa: BLE001
            sw.log(f"{k} ERROR {e}")


if __name__ == "__main__":
    main()
