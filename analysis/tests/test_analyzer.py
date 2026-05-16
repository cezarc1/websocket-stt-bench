from __future__ import annotations

import csv
import json
from pathlib import Path

from stt_analysis import AnalysisOptions, analyze_directory


def write_summary(
    path: Path,
    service_name: str,
    partials: int = 4,
    *,
    sessions: int = 2,
    repeat: int = 1,
    warmup_secs: int = 1,
    measure_secs: int = 3,
    ramp_up_secs: int = 0,
    session_start_spread_ms: int = 0,
    protocol_errors: int = 0,
    timeouts: dict[str, int] | None = None,
) -> None:
    timeouts = timeouts or {"connect": 0, "send": 0, "close": 0, "session": 0}
    payload = {
        "service_name": service_name,
        "url": "ws://example/ws/stt",
        "sessions": sessions,
        "repeat": repeat,
        "warmup_secs": warmup_secs,
        "measure_secs": measure_secs,
        "ramp_up_secs": ramp_up_secs,
        "session_start_spread_ms": session_start_spread_ms,
        "partials": partials,
        "protocol_errors": protocol_errors,
        "timeouts": timeouts,
    }
    path.write_text(json.dumps(payload), encoding="utf-8")


def write_samples(
    path: Path,
    *,
    newest_latency_ms: list[float] | None = None,
    oldest_latency_ms: list[float] | None = None,
    flush_lateness_ms: list[float] | None = None,
) -> None:
    newest_latency_ms = newest_latency_ms or [10.0, 20.0, 30.0, 40.0]
    oldest_latency_ms = oldest_latency_ms or [20.0, 30.0, 40.0, 50.0]
    flush_lateness_ms = flush_lateness_ms or [1.0, 2.0, 3.0, 4.0]
    rows = []
    for sample_index, newest_latency in enumerate(newest_latency_ms):
        rows.append(
            {
                "sample_index": sample_index,
                "session_id": (sample_index % 2) + 1,
                "oldest_frame_seq": sample_index + 1,
                "newest_frame_seq": sample_index + 1,
                "frames": 1,
                "newest_latency_ms": newest_latency,
                "oldest_latency_ms": oldest_latency_ms[sample_index],
                "flush_lateness_ms": flush_lateness_ms[sample_index],
                "received_ms": (sample_index + 1) * 100.0,
            }
        )
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def write_resources(path: Path) -> None:
    rows = [
        {"timestamp_ms": 0.0, "cpu_pct": 50.0, "memory_bytes": 100 * 1024 * 1024},
        {"timestamp_ms": 1000.0, "cpu_pct": 70.0, "memory_bytes": 200 * 1024 * 1024},
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def test_analyze_directory_pairs_samples_with_summary_and_computes_nearest_rank_percentiles(
    tmp_path: Path,
) -> None:
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()
    write_summary(result_dir / "rust-axum-single-5s-1w-3m-r1.summary.json", "rust-axum-single")
    write_samples(result_dir / "rust-axum-single-5s-1w-3m-r1.samples.csv")

    results = analyze_directory(AnalysisOptions(input_dir=result_dir, out_dir=out_dir))

    assert len(results) == 1
    result = results[0]
    assert result.service_name == "rust-axum-single"
    assert result.source == "samples_csv"
    assert result.samples_file is not None
    assert result.newest_latency.p50_ms == 20.0
    assert result.newest_latency.p95_ms == 40.0
    assert result.newest_latency.p999_ms == 40.0
    assert result.oldest_latency.max_ms == 50.0
    assert result.flush_lateness.p99_ms == 4.0

    summary_csv = out_dir / "summary.csv"
    summary_md = out_dir / "summary.md"
    assert summary_csv.exists()
    assert summary_md.exists()
    with summary_csv.open(newline="", encoding="utf-8") as handle:
        row = next(csv.DictReader(handle))
    assert row["service_name"] == "rust-axum-single"
    assert row["service_label"] == "rust-axum (1 CPU, 1 GiB RAM)"
    assert "rust-axum (1 CPU, 1 GiB RAM)" in summary_md.read_text(encoding="utf-8")
    assert "rust-axum-single" not in summary_md.read_text(encoding="utf-8")
    assert (out_dir / "latency_p99_by_service_2s-1w-3m-r1.png").stat().st_size > 0
    assert (out_dir / "latency_cdf_by_service_2s-1w-3m-r1.png").stat().st_size > 0
    assert (out_dir / "latency_p99_by_service.png").stat().st_size > 0
    assert (out_dir / "latency_cdf_by_service.png").stat().st_size > 0


def test_analyze_directory_keeps_legacy_json_only_results_in_limited_mode(tmp_path: Path) -> None:
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()
    write_summary(result_dir / "elixir-phoenix-single-5s-1w-3m-r1.json", "elixir-phoenix-single")

    results = analyze_directory(AnalysisOptions(input_dir=result_dir, out_dir=out_dir))

    assert len(results) == 1
    result = results[0]
    assert result.service_name == "elixir-phoenix-single"
    assert result.source == "summary_json"
    assert result.samples_file is None


def test_analyze_directory_writes_plots_per_workload(tmp_path: Path) -> None:
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()
    workloads = [
        ("5s-2w-10m-r1", 5, 2, 10, 1),
        ("50s-5w-30m-r1", 50, 5, 30, 1),
    ]
    services = ["rust-axum-single", "elixir-phoenix-single"]
    for slug, sessions, warmup_secs, measure_secs, repeat in workloads:
        for service_name in services:
            stem = f"{service_name}-{slug}"
            write_summary(
                result_dir / f"{stem}.summary.json",
                service_name,
                sessions=sessions,
                repeat=repeat,
                warmup_secs=warmup_secs,
                measure_secs=measure_secs,
            )
            write_samples(result_dir / f"{stem}.samples.csv")

    analyze_directory(AnalysisOptions(input_dir=result_dir, out_dir=out_dir))

    with (out_dir / "summary.csv").open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    assert rows[0]["workload_label"] == "5 sessions, 2s warmup, 10s measure, r1"
    assert rows[2]["workload_label"] == "50 sessions, 5s warmup, 30s measure, r1"

    summary_md = (out_dir / "summary.md").read_text(encoding="utf-8")
    assert "5 sessions, 2s warmup, 10s measure, r1" in summary_md
    assert "50 sessions, 5s warmup, 30s measure, r1" in summary_md

    for slug, *_ in workloads:
        assert (out_dir / f"latency_p99_by_service_{slug}.png").stat().st_size > 0
        assert (out_dir / f"latency_cdf_by_service_{slug}.png").stat().st_size > 0

    assert not (out_dir / "latency_p99_by_service.png").exists()
    assert not (out_dir / "latency_cdf_by_service.png").exists()


def test_analyze_directory_keeps_ramp_and_spread_as_distinct_workloads(tmp_path: Path) -> None:
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()
    for stem_suffix, ramp_up_secs, session_start_spread_ms in [
        ("instant", 0, 0),
        ("linear-ramp", 30, 250),
    ]:
        stem = f"rust-axum-single-50s-5w-30m-r1-{stem_suffix}"
        write_summary(
            result_dir / f"{stem}.summary.json",
            "rust-axum-single",
            sessions=50,
            warmup_secs=5,
            measure_secs=30,
            ramp_up_secs=ramp_up_secs,
            session_start_spread_ms=session_start_spread_ms,
        )
        write_samples(result_dir / f"{stem}.samples.csv")

    analyze_directory(AnalysisOptions(input_dir=result_dir, out_dir=out_dir))

    with (out_dir / "summary.csv").open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    assert [row["ramp_up_secs"] for row in rows] == ["0", "30"]
    assert [row["session_start_spread_ms"] for row in rows] == ["0", "250"]
    assert rows[0]["workload_label"] == "50 sessions, 5s warmup, 30s measure, r1"
    assert (
        rows[1]["workload_label"]
        == "50 sessions, 30s ramp, 250ms start spread, 5s warmup, 30s measure, r1"
    )
    assert (out_dir / "latency_p99_by_service_50s-5w-30m-r1.png").exists()
    assert (out_dir / "latency_p99_by_service_50s-5w-30m-30ramp-250spread-r1.png").exists()


def test_analyze_directory_writes_percent_differences_from_best_service(tmp_path: Path) -> None:
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()
    write_summary(
        result_dir / "rust-axum-single-5s-2w-10m-r1.summary.json",
        "rust-axum-single",
        sessions=5,
        warmup_secs=2,
        measure_secs=10,
    )
    write_samples(result_dir / "rust-axum-single-5s-2w-10m-r1.samples.csv")
    write_summary(
        result_dir / "elixir-phoenix-single-5s-2w-10m-r1.summary.json",
        "elixir-phoenix-single",
        sessions=5,
        warmup_secs=2,
        measure_secs=10,
    )
    write_samples(
        result_dir / "elixir-phoenix-single-5s-2w-10m-r1.samples.csv",
        newest_latency_ms=[20.0, 40.0, 60.0, 80.0],
        oldest_latency_ms=[40.0, 60.0, 80.0, 100.0],
        flush_lateness_ms=[2.0, 4.0, 6.0, 8.0],
    )

    analyze_directory(AnalysisOptions(input_dir=result_dir, out_dir=out_dir))

    with (out_dir / "comparisons.csv").open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    p99_newest_rows = [
        row for row in rows if row["metric"] == "newest_latency" and row["stat"] == "p99"
    ]
    assert len(p99_newest_rows) == 2
    rust_row = next(row for row in p99_newest_rows if row["service_name"] == "rust-axum-single")
    elixir_row = next(
        row for row in p99_newest_rows if row["service_name"] == "elixir-phoenix-single"
    )
    assert rust_row["is_best"] == "true"
    assert rust_row["diff_from_best_pct"] == "0.000"
    assert elixir_row["service_label"] == "elixir-phoenix (1 CPU, 1 GiB RAM)"
    assert elixir_row["best_service_label"] == "rust-axum (1 CPU, 1 GiB RAM)"
    assert elixir_row["value_ms"] == "80.000"
    assert elixir_row["best_value_ms"] == "40.000"
    assert elixir_row["diff_from_best_ms"] == "40.000"
    assert elixir_row["diff_from_best_pct"] == "100.000"

    comparisons_md = (out_dir / "comparisons.md").read_text(encoding="utf-8")
    assert "P99 comparison vs best" in comparisons_md
    assert "elixir-phoenix (1 CPU, 1 GiB RAM)" in comparisons_md
    assert "+100.000%" in comparisons_md


def test_analyze_directory_writes_interpretation_with_metric_explanations(
    tmp_path: Path,
) -> None:
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()
    write_summary(
        result_dir / "rust-axum-single-5s-2w-10m-r1.summary.json",
        "rust-axum-single",
        sessions=5,
        warmup_secs=2,
        measure_secs=10,
    )
    write_samples(result_dir / "rust-axum-single-5s-2w-10m-r1.samples.csv")
    write_summary(
        result_dir / "elixir-phoenix-single-5s-2w-10m-r1.summary.json",
        "elixir-phoenix-single",
        sessions=5,
        warmup_secs=2,
        measure_secs=10,
    )
    write_samples(
        result_dir / "elixir-phoenix-single-5s-2w-10m-r1.samples.csv",
        newest_latency_ms=[20.0, 40.0, 60.0, 80.0],
        oldest_latency_ms=[40.0, 60.0, 80.0, 100.0],
        flush_lateness_ms=[2.0, 4.0, 6.0, 8.0],
    )

    analyze_directory(AnalysisOptions(input_dir=result_dir, out_dir=out_dir))

    interpretation_md = (out_dir / "interpretation.md").read_text(encoding="utf-8")
    assert "## Metric guide" in interpretation_md
    assert "`newest_latency_*_ms`" in interpretation_md
    assert "how fresh each partial update feels" in interpretation_md
    assert "`oldest_latency_*_ms`" in interpretation_md
    assert "closer to perceived caption lag" in interpretation_md
    assert "`flush_lateness_*_ms`" in interpretation_md
    assert "scheduler/backpressure signal" in interpretation_md
    assert "## Runtime/config comparisons" in interpretation_md
    assert "5 sessions, 2s warmup, 10s measure, r1" in interpretation_md
    assert "Newest latency (`newest_latency_p99_ms`)" in interpretation_md
    assert "rust-axum (1 CPU, 1 GiB RAM) is best at 40.000 ms" in interpretation_md
    assert "elixir-phoenix (1 CPU, 1 GiB RAM) is +100.000% (+40.000 ms)" in interpretation_md


def test_analyze_directory_writes_capacity_and_resource_summary(tmp_path: Path) -> None:
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()
    write_summary(
        result_dir / "rust-axum-single-50s-5w-30m-r1.summary.json",
        "rust-axum-single",
        sessions=50,
        warmup_secs=5,
        measure_secs=30,
    )
    write_samples(result_dir / "rust-axum-single-50s-5w-30m-r1.samples.csv")
    write_resources(result_dir / "rust-axum-single-50s-5w-30m-r1.resources.csv")
    write_summary(
        result_dir / "elixir-phoenix-single-50s-5w-30m-r1.summary.json",
        "elixir-phoenix-single",
        sessions=50,
        warmup_secs=5,
        measure_secs=30,
    )
    write_samples(result_dir / "elixir-phoenix-single-50s-5w-30m-r1.samples.csv")

    analyze_directory(AnalysisOptions(input_dir=result_dir, out_dir=out_dir))

    with (out_dir / "capacity.csv").open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    rust_p95 = next(
        row
        for row in rows
        if row["service_name"] == "rust-axum-single" and row["quality_stat"] == "p95"
    )
    assert rust_p95["sessions"] == "50"
    assert rust_p95["newest_latency_ms"] == "40.000"
    assert rust_p95["resource_status"] == "resources_csv"
    assert rust_p95["cpu_avg_pct"] == "60.000"
    assert rust_p95["cpu_p95_pct"] == "70.000"
    assert rust_p95["memory_max_mb"] == "200.000"

    elixir_p95 = next(
        row
        for row in rows
        if row["service_name"] == "elixir-phoenix-single" and row["quality_stat"] == "p95"
    )
    assert elixir_p95["resource_status"] == "not_captured"
    assert elixir_p95["cpu_avg_pct"] == ""

    capacity_md = (out_dir / "capacity.md").read_text(encoding="utf-8")
    assert "Observed capacity by runtime/config" in capacity_md
    assert "rust-axum (1 CPU, 1 GiB RAM)" in capacity_md
    assert "max tested 50 sessions" in capacity_md
    assert "resources: avg CPU 60.000%, p95 CPU 70.000%, max RAM 200.000 MiB" in capacity_md
    assert "elixir-phoenix (1 CPU, 1 GiB RAM)" in capacity_md
    assert "resources: not captured" in capacity_md


def test_analyze_directory_writes_balanced_realtime_slo_capacity(tmp_path: Path) -> None:
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()

    write_summary(
        result_dir / "rust-axum-single-50s-10w-45m-r1.summary.json",
        "rust-axum-single",
        sessions=50,
        warmup_secs=10,
        measure_secs=45,
    )
    write_samples(
        result_dir / "rust-axum-single-50s-10w-45m-r1.samples.csv",
        newest_latency_ms=[100.0, 120.0, 140.0, 160.0],
        oldest_latency_ms=[300.0, 350.0, 450.0, 500.0],
        flush_lateness_ms=[1.0, 2.0, 3.0, 4.0],
    )
    write_resources(result_dir / "rust-axum-single-50s-10w-45m-r1.resources.csv")
    write_summary(
        result_dir / "rust-axum-single-100s-10w-45m-r1.summary.json",
        "rust-axum-single",
        sessions=100,
        warmup_secs=10,
        measure_secs=45,
    )
    write_samples(
        result_dir / "rust-axum-single-100s-10w-45m-r1.samples.csv",
        newest_latency_ms=[180.0, 210.0, 330.0, 340.0],
        oldest_latency_ms=[430.0, 460.0, 850.0, 880.0],
        flush_lateness_ms=[1.0, 2.0, 3.0, 4.0],
    )

    write_summary(
        result_dir / "elixir-phoenix-single-50s-10w-45m-r1.summary.json",
        "elixir-phoenix-single",
        sessions=50,
        warmup_secs=10,
        measure_secs=45,
    )
    write_samples(
        result_dir / "elixir-phoenix-single-50s-10w-45m-r1.samples.csv",
        newest_latency_ms=[90.0, 110.0, 130.0, 150.0],
        oldest_latency_ms=[280.0, 330.0, 430.0, 480.0],
        flush_lateness_ms=[1.0, 2.0, 3.0, 4.0],
    )

    results = analyze_directory(
        AnalysisOptions(
            input_dir=result_dir,
            out_dir=out_dir,
            slo_profile="balanced-realtime",
        )
    )

    assert len(results) == 3
    with (out_dir / "slo_capacity.csv").open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    rust_row = next(row for row in rows if row["service_name"] == "rust-axum-single")
    elixir_row = next(row for row in rows if row["service_name"] == "elixir-phoenix-single")

    assert rust_row["slo_profile"] == "balanced-realtime"
    assert rust_row["status"] == "bounded"
    assert rust_row["highest_passing_sessions"] == "50"
    assert rust_row["first_failing_sessions"] == "100"
    assert rust_row["limiting_reasons"] == "newest_p50"
    assert rust_row["oldest_p50_slo_ms"] == "1200.000"
    assert rust_row["newest_p50_slo_ms"] == "200.000"
    assert rust_row["oldest_p95_slo_ms"] == "1650.000"
    assert rust_row["newest_p95_slo_ms"] == "350.000"
    assert rust_row["pass_oldest_p50_ms"] == "350.000"
    assert rust_row["pass_oldest_p95_ms"] == "500.000"
    assert rust_row["pass_newest_p50_ms"] == "120.000"
    assert rust_row["fail_oldest_p50_ms"] == "460.000"
    assert rust_row["fail_newest_p50_ms"] == "210.000"
    assert rust_row["fail_oldest_p95_ms"] == "880.000"
    assert rust_row["pass_resource_status"] == "resources_csv"
    assert rust_row["pass_cpu_avg_pct"] == "60.000"
    assert rust_row["pass_memory_max_mb"] == "200.000"

    assert elixir_row["status"] == "lower_bound"
    assert elixir_row["highest_passing_sessions"] == "50"
    assert elixir_row["first_failing_sessions"] == ""
    assert elixir_row["limiting_reasons"] == ""

    slo_md = (out_dir / "slo_capacity.md").read_text(encoding="utf-8")
    assert "Balanced realtime SLO" in slo_md
    assert "Primary gate: oldest p50 <= 1200.000 ms" in slo_md
    assert "newest p50 <= 200.000 ms" in slo_md
    assert "Tail guardrail: oldest p95 <= 1650.000 ms" in slo_md
    assert "newest p95 <= 350.000 ms" in slo_md
    assert "rust-axum (1 CPU, 1 GiB RAM)" in slo_md
    assert "bounded: highest passing 50 sessions; first failing 100 sessions" in slo_md
    assert "limiting reasons: newest_p50" in slo_md
    assert "elixir-phoenix (1 CPU, 1 GiB RAM)" in slo_md
    assert "lower_bound: highest passing 50 sessions; no failing point observed" in slo_md


def test_balanced_realtime_slo_error_budget_passes_below_threshold(tmp_path: Path) -> None:
    """1 error in 200 healthy partials (rate 5e-3) passes when budget is 1e-2."""
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()
    # 200 healthy samples, all latency under SLO.
    healthy_newest = [100.0 + (i % 50) for i in range(200)]
    healthy_oldest = [300.0 + (i % 80) for i in range(200)]
    healthy_flush = [1.0 + (i % 10) * 0.1 for i in range(200)]
    write_summary(
        result_dir / "python-fastapi-stock-single-50s-10w-45m-r1.summary.json",
        "python-fastapi-stock-single",
        sessions=50,
        warmup_secs=10,
        measure_secs=45,
        protocol_errors=1,
    )
    write_samples(
        result_dir / "python-fastapi-stock-single-50s-10w-45m-r1.samples.csv",
        newest_latency_ms=healthy_newest,
        oldest_latency_ms=healthy_oldest,
        flush_lateness_ms=healthy_flush,
    )

    analyze_directory(
        AnalysisOptions(
            input_dir=result_dir,
            out_dir=out_dir,
            slo_profile="balanced-realtime",
            max_error_rate=1e-2,  # 1 error / 201 = 5e-3 < 1e-2
        )
    )

    with (out_dir / "slo_capacity.csv").open(newline="", encoding="utf-8") as handle:
        row = next(csv.DictReader(handle))
    assert row["status"] == "lower_bound"
    assert row["highest_passing_sessions"] == "50"
    assert row["limiting_reasons"] == ""


def test_balanced_realtime_slo_error_budget_fails_above_threshold(tmp_path: Path) -> None:
    """50 errors in 100 partials (rate ~0.33) exceeds 1e-2 budget; fails with "error_rate"."""
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()
    healthy_newest = [100.0 + (i % 50) for i in range(100)]
    healthy_oldest = [300.0 + (i % 80) for i in range(100)]
    healthy_flush = [1.0 + (i % 10) * 0.1 for i in range(100)]
    write_summary(
        result_dir / "python-fastapi-stock-single-50s-10w-45m-r1.summary.json",
        "python-fastapi-stock-single",
        sessions=50,
        warmup_secs=10,
        measure_secs=45,
        protocol_errors=50,
    )
    write_samples(
        result_dir / "python-fastapi-stock-single-50s-10w-45m-r1.samples.csv",
        newest_latency_ms=healthy_newest,
        oldest_latency_ms=healthy_oldest,
        flush_lateness_ms=healthy_flush,
    )

    analyze_directory(
        AnalysisOptions(
            input_dir=result_dir,
            out_dir=out_dir,
            slo_profile="balanced-realtime",
            max_error_rate=1e-2,  # 50 / 150 ≈ 0.33 > 1e-2
        )
    )

    with (out_dir / "slo_capacity.csv").open(newline="", encoding="utf-8") as handle:
        row = next(csv.DictReader(handle))
    assert row["status"] == "no_pass"
    assert row["limiting_reasons"] == "error_rate"


def test_balanced_realtime_slo_capacity_marks_no_pass_and_reliability_failures(
    tmp_path: Path,
) -> None:
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()
    write_summary(
        result_dir / "python-fastapi-mt-single-50s-10w-45m-r1.summary.json",
        "python-fastapi-mt-single",
        sessions=50,
        warmup_secs=10,
        measure_secs=45,
        protocol_errors=1,
        timeouts={"connect": 0, "send": 0, "close": 1, "session": 0},
    )
    write_samples(
        result_dir / "python-fastapi-mt-single-50s-10w-45m-r1.samples.csv",
        newest_latency_ms=[100.0, 120.0, 140.0, 160.0],
        oldest_latency_ms=[300.0, 350.0, 450.0, 500.0],
        flush_lateness_ms=[1.0, 2.0, 3.0, 4.0],
    )

    analyze_directory(
        AnalysisOptions(
            input_dir=result_dir,
            out_dir=out_dir,
            slo_profile="balanced-realtime",
        )
    )

    with (out_dir / "slo_capacity.csv").open(newline="", encoding="utf-8") as handle:
        row = next(csv.DictReader(handle))

    assert row["status"] == "no_pass"
    assert row["highest_passing_sessions"] == ""
    assert row["first_failing_sessions"] == "50"
    assert row["limiting_reasons"] == "protocol_errors,timeouts"
    assert row["fail_protocol_errors"] == "1"
    assert row["fail_timeouts_total"] == "1"


def test_balanced_realtime_slo_analysis_writes_scaling_summary(tmp_path: Path) -> None:
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()

    for service_name, sessions, oldest_values, newest_values in [
        ("rust-axum-single", 100, [300.0, 350.0, 450.0, 500.0], [100.0, 120.0, 140.0, 160.0]),
        (
            "rust-axum-single",
            200,
            [1300.0, 1400.0, 1700.0, 1800.0],
            [100.0, 120.0, 140.0, 160.0],
        ),
        ("rust-axum-multi", 400, [300.0, 350.0, 450.0, 500.0], [100.0, 120.0, 140.0, 160.0]),
        (
            "rust-axum-multi",
            600,
            [1300.0, 1400.0, 1700.0, 1800.0],
            [100.0, 120.0, 140.0, 160.0],
        ),
        (
            "elixir-phoenix-single",
            100,
            [300.0, 350.0, 450.0, 500.0],
            [100.0, 120.0, 140.0, 160.0],
        ),
        (
            "elixir-phoenix-multi",
            300,
            [300.0, 350.0, 450.0, 500.0],
            [100.0, 120.0, 140.0, 160.0],
        ),
        (
            "python-fastapi-mt-single",
            50,
            [300.0, 350.0, 450.0, 500.0],
            [100.0, 120.0, 140.0, 160.0],
        ),
    ]:
        stem = f"{service_name}-{sessions}s-10w-45m-r1"
        write_summary(
            result_dir / f"{stem}.summary.json",
            service_name,
            sessions=sessions,
            warmup_secs=10,
            measure_secs=45,
        )
        write_samples(
            result_dir / f"{stem}.samples.csv",
            oldest_latency_ms=oldest_values,
            newest_latency_ms=newest_values,
        )

    analyze_directory(
        AnalysisOptions(
            input_dir=result_dir,
            out_dir=out_dir,
            slo_profile="balanced-realtime",
        )
    )

    with (out_dir / "scaling.csv").open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    rust_row = next(row for row in rows if row["implementation"] == "rust-axum")
    elixir_row = next(row for row in rows if row["implementation"] == "elixir-phoenix")
    python_row = next(row for row in rows if row["implementation"] == "python-fastapi-mt")

    assert rust_row["single_status"] == "bounded"
    assert rust_row["multi_status"] == "bounded"
    assert rust_row["single_cpu_count"] == "1"
    assert rust_row["multi_cpu_count"] == "4"
    assert rust_row["single_capacity_sessions"] == "100"
    assert rust_row["multi_capacity_sessions"] == "400"
    assert rust_row["capacity_lift"] == "4.000"
    assert rust_row["scaling_efficiency"] == "1.000"
    assert rust_row["additional_cpu_count"] == "3"
    assert rust_row["added_capacity_sessions"] == "300"
    assert rust_row["sessions_per_added_cpu"] == "100.000"
    assert rust_row["marginal_lift_per_added_cpu"] == "1.000"
    assert rust_row["single_first_failing_sessions"] == "200"
    assert rust_row["multi_first_failing_sessions"] == "600"

    assert elixir_row["multi_status"] == "lower_bound"
    assert elixir_row["multi_capacity_sessions"] == "300"
    assert elixir_row["capacity_lift"] == "3.000"
    assert elixir_row["scaling_efficiency"] == "0.750"
    assert elixir_row["sessions_per_added_cpu"] == "66.667"
    assert elixir_row["marginal_lift_per_added_cpu"] == "0.667"

    assert python_row["single_status"] == "lower_bound"
    assert python_row["multi_status"] == "missing"
    assert python_row["capacity_lift"] == ""
    assert python_row["scaling_efficiency"] == ""

    scaling_md = (out_dir / "scaling.md").read_text(encoding="utf-8")
    assert "4-CPU scaling vs 1-CPU capacity" in scaling_md
    assert "| rust-axum | bounded | 100 | bounded | 400 | 4.000x | 100.000% | 100.000 | 1.000x |"
    assert (
        "| elixir-phoenix | bounded | 100 | lower_bound | 300 | 3.000x | 75.000% | "
        "66.667 | 0.667x |"
    )
    assert "| python-fastapi-mt | lower_bound | 50 | missing |  |  |  |  |  |"


def test_balanced_realtime_slo_analysis_accepts_two_cpu_scaling(tmp_path: Path) -> None:
    result_dir = tmp_path / "results"
    out_dir = result_dir / "analysis"
    result_dir.mkdir()

    for service_name, sessions in [
        ("rust-axum-single", 100),
        ("rust-axum-multi", 200),
    ]:
        stem = f"{service_name}-{sessions}s-10w-45m-r1"
        write_summary(
            result_dir / f"{stem}.summary.json",
            service_name,
            sessions=sessions,
            warmup_secs=10,
            measure_secs=45,
        )
        write_samples(
            result_dir / f"{stem}.samples.csv",
            oldest_latency_ms=[300.0, 350.0, 450.0, 500.0],
            newest_latency_ms=[100.0, 120.0, 140.0, 160.0],
        )

    analyze_directory(
        AnalysisOptions(
            input_dir=result_dir,
            out_dir=out_dir,
            slo_profile="balanced-realtime",
            multi_cpu_count=2.0,
        )
    )

    with (out_dir / "scaling.csv").open(newline="", encoding="utf-8") as handle:
        row = next(csv.DictReader(handle))

    assert row["multi_cpu_count"] == "2"
    assert row["capacity_lift"] == "2.000"
    assert row["scaling_efficiency"] == "1.000"
    assert row["additional_cpu_count"] == "1"
    assert row["added_capacity_sessions"] == "100"
    assert row["sessions_per_added_cpu"] == "100.000"
    assert row["marginal_lift_per_added_cpu"] == "1.000"

    scaling_md = (out_dir / "scaling.md").read_text(encoding="utf-8")
    assert "2-CPU scaling vs 1-CPU capacity" in scaling_md
