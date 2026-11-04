"""Generate the README comparison charts: LOC vs capacity, and capacity by vCPU.

Run from the ``analysis/`` dir (the package only resolves there, same as
the ``analyze-results`` just recipe), and pass an absolute/relative ``--out``
back to the repo ``docs/`` (the default out path is relative to the cwd):

    cd analysis && ../.tools/bin/uv run python -m \
        stt_analysis.comparison_chart_gen --out ../docs/loc-vs-capacity.png \
        --vcpu-out ../docs/capacity-by-vcpu.png

The runtime data is hardcoded below — update the ``RUNTIMES`` table when
benchmark numbers shift or new runtimes are added, then re-run.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.patheffects as pe
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

# (name, sessions at 1 vCPU, sessions at 2 vCPU or None, application LOC,
#  label dx_pts, dy_pts, horizontal alignment)
# Sessions are the confirmed ceilings from the run9 full pass (2026-11-04,
# co-located, pinned homelab, fixed loadgen; README TL;DR). 2 vCPU is None
# where it was not measured in run9 (single-loop runtimes and Bun). For most
# runtimes, application LOC equals raw production LOC. The OCaml raw-transport
# variants exclude the generic first-party WebSocket/HTTP/SHA-1/base64/masking
# shim so package code is treated consistently.
RUNTIMES: list[tuple[str, int, int | None, int, int, int, str]] = [
    ("C++23 / uWebSockets", 8300, 9000, 1551, -10, 10, "right"),
    ("Rust / mio", 7500, 8700, 1221, -10, 10, "right"),
    ("Async Rust / Tokio", 5100, 8300, 696, 10, 10, "left"),
    ("oxcaml-epoll", 4800, None, 1680, -10, 10, "right"),
    ("TypeScript / Bun", 3400, None, 734, 10, 10, "left"),
    ("Go / net/http", 3250, 4400, 893, 10, -4, "left"),
    ("Java / Helidon Nima", 3200, 5600, 917, -10, 8, "right"),
    ("OxCaml", 3200, None, 879, 10, -16, "left"),
    ("OCaml", 2600, None, 850, -10, 4, "right"),
    ("Python 3.15 (GIL)", 1450, 1950, 678, 10, -14, "left"),
    ("Python 3.15t (free-threaded)", 1450, 2500, 678, -10, 10, "right"),
    ("Elixir / Phoenix", 1350, 2400, 784, 10, 10, "left"),
    ("Scala / Pekko", 1300, 2050, 726, -10, 8, "right"),
]

# Strict Pareto-optimal points: no other runtime has BOTH higher sessions
# AND lower LOC. Highlighted in yellow in the rendered chart.
PARETO = {
    "C++23 / uWebSockets",
    "Rust / mio",
    "Async Rust / Tokio",
    "Python 3.15 (GIL)",
}

# At 1 vCPU both Python builds land on the same point, so the scatter shows one marker.
SCATTER_MERGED = {"Python 3.15t (free-threaded)"}
SCATTER_LABELS = {"Python 3.15 (GIL)": "Python 3.15 (GIL and free-threaded)"}

RUN_LABEL = "2026-11-04 run9, co-located, pinned homelab"
ONE_VCPU, TWO_VCPU = "#2a78d6", "#eb6834"  # validated categorical slots 1-2

DEFAULT_OUT = Path("docs/loc-vs-capacity.png")
DEFAULT_VCPU_OUT = Path("docs/capacity-by-vcpu.png")


def render(out_path: Path) -> None:
    fig, ax = plt.subplots(figsize=(11, 7), dpi=150)

    for name, x, _, y, dx, dy, ha in RUNTIMES:
        if name in SCATTER_MERGED:
            continue
        name = SCATTER_LABELS.get(name, name)
        is_pareto = name in PARETO or name in SCATTER_LABELS.values()
        ax.scatter(
            [x],
            [y],
            s=170 if is_pareto else 95,
            alpha=0.92,
            edgecolors="black",
            linewidths=0.8 if is_pareto else 0.6,
            color="#f5b400" if is_pareto else "#2e6cd6",
            zorder=4 if is_pareto else 3,
        )
        ax.annotate(
            name,
            xy=(x, y),
            xytext=(dx, dy),
            textcoords="offset points",
            fontsize=10.5,
            ha=ha,
            weight="bold" if is_pareto else "normal",
            path_effects=[pe.withStroke(linewidth=3, foreground="white")],
            zorder=5,
        )

    ax.set_xlabel("Concurrent sessions sustained at 1 vCPU", fontsize=11)
    ax.set_ylabel("LOC", fontsize=11)
    ax.set_title(
        f"Concurrent sessions vs. LOC — websocket-stt-bench ({RUN_LABEL})",
        fontsize=13,
        pad=14,
    )
    ax.grid(True, linestyle=":", alpha=0.25, zorder=0)
    ax.set_axisbelow(True)

    ax.set_xlim(800, 9200)
    ax.set_ylim(600, 1800)

    fig.text(
        0.99,
        0.01,
        "Yellow markers are Pareto-optimal: no other tested runtime beats them on both axes "
        "(lower LOC AND higher capacity).",
        ha="right",
        va="bottom",
        fontsize=8.5,
        style="italic",
        color="#444",
    )

    plt.tight_layout(rect=(0, 0.04, 1, 1))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"wrote {out_path}")


def render_vcpu(out_path: Path) -> None:
    """Grouped bars: one group per runtime, 1 vCPU and 2 vCPU side by side."""
    names = [r[0] for r in RUNTIMES]
    one = [r[1] for r in RUNTIMES]
    two = [r[2] for r in RUNTIMES]
    fig, ax = plt.subplots(figsize=(13, 6.5), dpi=150)
    w, gap = 0.38, 0.02
    xs = range(len(names))
    for i, (a, b) in enumerate(zip(one, two, strict=True)):
        ax.bar(
            i - w / 2 - gap / 2, a, w, color=ONE_VCPU, zorder=3, edgecolor="white", linewidth=0.5
        )
        ax.annotate(
            f"{a}",
            (i - w / 2 - gap / 2, a),
            xytext=(0, 3),
            textcoords="offset points",
            ha="center",
            fontsize=8,
            color="#333",
        )
        if b is None:
            ax.annotate(
                "n/m",
                (i + w / 2 + gap / 2, 0),
                xytext=(0, 3),
                textcoords="offset points",
                ha="center",
                fontsize=8,
                color="#777",
                style="italic",
            )
            continue
        ax.bar(
            i + w / 2 + gap / 2, b, w, color=TWO_VCPU, zorder=3, edgecolor="white", linewidth=0.5
        )
        ax.annotate(
            f"{b}",
            (i + w / 2 + gap / 2, b),
            xytext=(0, 3),
            textcoords="offset points",
            ha="center",
            fontsize=8,
            color="#333",
        )
    handles = [Patch(color=ONE_VCPU, label="1 vCPU"), Patch(color=TWO_VCPU, label="2 vCPU")]
    ax.set_xticks(list(xs), names, rotation=30, ha="right", fontsize=9.5)
    ax.set_ylabel("Concurrent sessions inside the SLO", fontsize=11)
    ax.set_title(
        f"Concurrent sessions by runtime and vCPU — websocket-stt-bench ({RUN_LABEL})",
        fontsize=13,
        pad=14,
    )
    ax.grid(True, axis="y", linestyle=":", alpha=0.3, zorder=0)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    ax.legend(handles=handles, frameon=False, loc="upper right")
    fig.text(
        0.99,
        0.01,
        "n/m = not measured in run9 (single-loop runtimes, which can't use a second core, and Bun). "
        "C++ at 2 vCPU fails on inference-request timeouts, not its own CPU.",
        ha="right",
        va="bottom",
        fontsize=8.5,
        style="italic",
        color="#444",
    )
    plt.tight_layout(rect=(0, 0.04, 1, 1))
    out_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"wrote {out_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Render the LOC-vs-capacity comparison chart.")
    parser.add_argument(
        "--out",
        type=Path,
        default=DEFAULT_OUT,
        help=f"Output PNG path (default: {DEFAULT_OUT})",
    )
    parser.add_argument(
        "--vcpu-out",
        type=Path,
        default=DEFAULT_VCPU_OUT,
        help=f"Output PNG path for the 1-vs-2-vCPU chart (default: {DEFAULT_VCPU_OUT})",
    )
    args = parser.parse_args()
    render(args.out)
    render_vcpu(args.vcpu_out)


if __name__ == "__main__":
    main()
