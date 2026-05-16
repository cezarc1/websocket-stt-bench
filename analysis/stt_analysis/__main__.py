from __future__ import annotations

import argparse
from pathlib import Path

from stt_analysis import SLO_PROFILES, AnalysisOptions, analyze_directory


def main() -> None:
    parser = argparse.ArgumentParser(description="Analyze websocket-stt-bench raw samples")
    parser.add_argument(
        "--input", required=True, type=Path, help="Directory containing result files"
    )
    parser.add_argument("--out", required=True, type=Path, help="Directory for analysis outputs")
    parser.add_argument(
        "--bootstrap",
        type=int,
        default=0,
        help="Optional bootstrap resample count for percentile confidence intervals",
    )
    parser.add_argument("--seed", type=int, default=0, help="Bootstrap random seed")
    parser.add_argument(
        "--confidence",
        type=float,
        default=0.95,
        help="Bootstrap confidence level",
    )
    parser.add_argument(
        "--slo-profile",
        choices=SLO_PROFILES,
        default="off",
        help="Optional SLO profile for capacity artifacts",
    )
    parser.add_argument(
        "--max-error-rate",
        type=float,
        default=1e-5,
        help=(
            "SLO error budget for protocol/inference/timeout failures, expressed "
            "as a fraction of (partials + total_errors). Default 1e-5 (≈ 1 in "
            "100,000 partial round-trips) tolerates the kernel/TCP noise floor "
            "while staying ≥2 orders of magnitude tighter than realistic "
            "production SLOs. Set to 0 for strict-zero gating."
        ),
    )
    parser.add_argument(
        "--multi-cpus",
        type=float,
        default=4.0,
        help="CPU count represented by the '-multi' service profile for scaling efficiency",
    )
    args = parser.parse_args()

    results = analyze_directory(
        AnalysisOptions(
            input_dir=args.input,
            out_dir=args.out,
            bootstrap=args.bootstrap,
            seed=args.seed,
            confidence=args.confidence,
            slo_profile=args.slo_profile,
            multi_cpu_count=args.multi_cpus,
            max_error_rate=args.max_error_rate,
        )
    )
    print(f"Wrote analysis for {len(results)} result(s) to {args.out}")


if __name__ == "__main__":
    main()
