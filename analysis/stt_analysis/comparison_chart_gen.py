"""Generate the LOC-vs-capacity comparison scatter chart for the README.

Run from the ``analysis/`` dir (the package only resolves there, same as
the ``analyze-results`` just recipe), and pass an absolute/relative ``--out``
back to the repo ``docs/`` (the default out path is relative to the cwd):

    cd analysis && ../.tools/bin/uv run python -m \
        stt_analysis.comparison_chart_gen --out ../docs/loc-vs-capacity.png

The runtime data is hardcoded below — update the ``RUNTIMES`` table when
benchmark numbers shift or new runtimes are added, then re-run.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.patheffects as pe  # noqa: E402  (use("Agg") must come first)
import matplotlib.pyplot as plt  # noqa: E402

# (name, sessions at 1 vCPU, LOC, label dx_pts, dy_pts, horizontal alignment)
RUNTIMES: list[tuple[str, int, int, int, int, str]] = [
    ("C++23 / uWebSockets",        4450, 1551, -10, -14, "right"),
    ("Rust / Axum",                3475,  696, -10,  10, "right"),
    ("Java / Helidon Nima",        2600,  917,  10,  10, "left"),
    ("TypeScript / Bun",           2550,  734,  10, -14, "left"),
    ("Go / net/http",              2500,  893,  10, -14, "left"),
    ("OCaml / OxCaml",             2075, 1235,  10,  10, "left"),
    ("Scala / Pekko",              1400,  726,  10, -14, "left"),
    ("Elixir / Phoenix",           1250,  784,  10,  10, "left"),
    ("Python (uvloop + FastAPI)",  1100,  678, -10,  10, "right"),
]

# Strict Pareto-optimal points: no other runtime has BOTH higher sessions
# AND lower LOC. Highlighted in yellow in the rendered chart.
PARETO = {
    "C++23 / uWebSockets",
    "Rust / Axum",
    "Python (uvloop + FastAPI)",
}

DEFAULT_OUT = Path("docs/loc-vs-capacity.png")


def render(out_path: Path) -> None:
    fig, ax = plt.subplots(figsize=(11, 7), dpi=150)

    for name, x, y, dx, dy, ha in RUNTIMES:
        is_pareto = name in PARETO
        ax.scatter(
            [x], [y],
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
    ax.set_ylabel("Lines Of Code", fontsize=11)
    ax.set_title(
        "Concurrent sessions vs. Lines Of Code — websocket-stt-bench",
        fontsize=13,
        pad=14,
    )
    ax.grid(True, linestyle=":", alpha=0.25, zorder=0)
    ax.set_axisbelow(True)

    ax.set_xlim(800, 4800)
    ax.set_ylim(600, 1700)

    fig.text(
        0.99, 0.01,
        "Yellow markers are Pareto-optimal: no other tested runtime beats them on both axes "
        "(lower LOC AND higher capacity).",
        ha="right", va="bottom",
        fontsize=8.5, style="italic", color="#444",
    )

    plt.tight_layout(rect=(0, 0.04, 1, 1))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"wrote {out_path}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Render the LOC-vs-capacity comparison chart."
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=DEFAULT_OUT,
        help=f"Output PNG path (default: {DEFAULT_OUT})",
    )
    args = parser.parse_args()
    render(args.out)


if __name__ == "__main__":
    main()
