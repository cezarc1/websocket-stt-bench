#!/bin/sh
# Granian launcher.
#
# Free-threaded Python (3.14t) note: per Granian's docs (>= 2.0), on a
# free-threaded build `--workers N` spawns N worker *threads* (not processes)
# sharing one Python interpreter, each running its own asyncio event loop.
# This is the headline 3.14t configuration the benchmark measures.
#
# Granian refuses to start if the GIL gets re-enabled on the free-threaded
# build, so this also acts as a runtime guard.
#
# Two configurations:
#   stock:  --workers 1 --runtime-mode st --runtime-threads 1
#           1 Python loop, 1 single-threaded Rust I/O runtime. Baseline.
#   mt:     --workers N --runtime-mode mt --runtime-threads N
#           N Python loops sharing one interpreter without GIL contention,
#           multi-threaded Rust I/O runtime (mt is Granian's recommendation
#           for higher CPU counts). Headline 3.14t config.
#
# GRANIAN_LOOPS = N picks the mt config. Absent => stock baseline.
# WORKER_THREADS bounds each loop's default ThreadPoolExecutor (see
# app/main.py lifespan); orthogonal to GRANIAN_LOOPS.
#
# Granian's docs note that free-threaded tuning lacks production data —
# this is one reasonable point in the configuration space, not the optimum.
set -eu

PORT="${PORT:-8000}"
# Granian event-loop and task-impl can be tuned via env vars (default values
# preserve historical behavior). See Phase J in
# results/python-bottleneck-investigation/NOTES.md for the ceiling-search
# data behind the per-variant defaults baked into docker-compose.yml.
LOOP_KIND="${GRANIAN_LOOP_KIND:-asyncio}"
TASK_IMPL="${GRANIAN_TASK_IMPL:-asyncio}"
COMMON="--interface asgi --host 0.0.0.0 --port ${PORT} --loop ${LOOP_KIND} --task-impl ${TASK_IMPL} --no-access-log"

if [ -n "${GRANIAN_LOOPS:-}" ]; then
  # Granian docs recommend bumping --runtime-threads for highly-concurrent
  # WebSocket workloads. Default here matches Python loop count (the
  # vCPU-budget-aligned baseline); override via GRANIAN_RUNTIME_THREADS for
  # contended configs (e.g., mt-single sees 4× error reduction at 2N).
  RT_THREADS="${GRANIAN_RUNTIME_THREADS:-$GRANIAN_LOOPS}"
  # shellcheck disable=SC2086
  exec granian ${COMMON} \
    --workers "${GRANIAN_LOOPS}" \
    --runtime-mode mt \
    --runtime-threads "${RT_THREADS}" \
    app.main:app
else
  RT_THREADS="${GRANIAN_RUNTIME_THREADS:-1}"
  # shellcheck disable=SC2086
  exec granian ${COMMON} \
    --workers 1 \
    --runtime-mode st \
    --runtime-threads "${RT_THREADS}" \
    app.main:app
fi
