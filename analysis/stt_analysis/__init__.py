from __future__ import annotations

import csv
import json
import re
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, cast

import numpy as np

SAMPLE_SUFFIXES = (".samples.csv", "-samples.csv")
SUMMARY_SUFFIXES = (".summary.json", "-summary.json", ".json")
RESOURCE_SUFFIXES = (".resources.csv", "-resources.csv")
PERCENTILES = {"p50": 50.0, "p95": 95.0, "p99": 99.0, "p999": 99.9}
COMPARISON_STATS = ("p50", "p95", "p99", "p999", "max")
COMPARISON_METRICS = (
    ("newest_latency", "Newest latency"),
    ("oldest_latency", "Oldest latency"),
    ("flush_lateness", "Flush lateness"),
)
METRIC_EXPLANATIONS = {
    "newest_latency": (
        "`newest_latency_*_ms`",
        "how fresh each partial update feels to a user. It measures the delay from the "
        "newest audio frame in a flushed batch to the client receiving the partial.",
    ),
    "oldest_latency": (
        "`oldest_latency_*_ms`",
        "closer to perceived caption lag. It measures how long the oldest audio frame "
        "in a flushed batch waited before that partial reached the client.",
    ),
    "flush_lateness": (
        "`flush_lateness_*_ms`",
        "a scheduler/backpressure signal. It measures how late the server ran the "
        "intended flush cadence; high values explain latency tails.",
    ),
}
REQUIRED_SAMPLE_FIELDS = (
    "sample_index",
    "session_id",
    "oldest_frame_seq",
    "newest_frame_seq",
    "frames",
    "newest_latency_ms",
    "oldest_latency_ms",
    "flush_lateness_ms",
    "received_ms",
)
REQUIRED_RESOURCE_FIELDS = ("timestamp_ms", "cpu_pct", "memory_bytes")
SERVICE_PROFILE_SUFFIXES = (
    ("-single",),
    ("-multi",),
)
SLO_PROFILE_OFF = "off"
SLO_PROFILE_BALANCED_REALTIME = "balanced-realtime"
SLO_PROFILES = (SLO_PROFILE_OFF, SLO_PROFILE_BALANCED_REALTIME)
SLO_REASON_ORDER = (
    "oldest_p50",
    "newest_p50",
    "oldest_p95",
    "newest_p95",
    "protocol_errors",
    "timeouts",
    "inference_errors",
    "error_rate",
)


@dataclass(frozen=True)
class AnalysisOptions:
    input_dir: Path
    out_dir: Path
    bootstrap: int = 0
    seed: int = 0
    confidence: float = 0.95
    slo_profile: str = SLO_PROFILE_OFF
    multi_cpu_count: float = 4.0
    # Error-budget mode: when > 0, the SLO error gate accepts up to this
    # fraction of (errors / (partials + errors)). Default 0.0 preserves
    # strict-zero semantics (any error fails the gate). Latency gates are
    # unaffected.
    max_error_rate: float = 0.0


@dataclass(frozen=True)
class MetricStats:
    p50_ms: float = 0.0
    p95_ms: float = 0.0
    p99_ms: float = 0.0
    p999_ms: float = 0.0
    max_ms: float = 0.0
    ci_ms: dict[str, tuple[float, float]] = field(default_factory=dict)

    def to_columns(self, prefix: str) -> dict[str, str]:
        row = {
            f"{prefix}_p50_ms": format_float(self.p50_ms),
            f"{prefix}_p95_ms": format_float(self.p95_ms),
            f"{prefix}_p99_ms": format_float(self.p99_ms),
            f"{prefix}_p999_ms": format_float(self.p999_ms),
            f"{prefix}_max_ms": format_float(self.max_ms),
        }
        for key in PERCENTILES:
            low, high = self.ci_ms.get(key, (None, None))
            row[f"{prefix}_{key}_ci_low_ms"] = "" if low is None else format_float(low)
            row[f"{prefix}_{key}_ci_high_ms"] = "" if high is None else format_float(high)
        return row


@dataclass(frozen=True)
class ResourceStats:
    source: str = "not_captured"
    resource_file: Path | None = None
    samples: int = 0
    cpu_avg_pct: float | None = None
    cpu_p95_pct: float | None = None
    cpu_max_pct: float | None = None
    memory_avg_mb: float | None = None
    memory_p95_mb: float | None = None
    memory_max_mb: float | None = None

    def to_columns(self) -> dict[str, str]:
        return {
            "resource_status": self.source,
            "resource_file": "" if self.resource_file is None else str(self.resource_file),
            "resource_samples": str(self.samples),
            "cpu_avg_pct": format_optional_float(self.cpu_avg_pct),
            "cpu_p95_pct": format_optional_float(self.cpu_p95_pct),
            "cpu_max_pct": format_optional_float(self.cpu_max_pct),
            "memory_avg_mb": format_optional_float(self.memory_avg_mb),
            "memory_p95_mb": format_optional_float(self.memory_p95_mb),
            "memory_max_mb": format_optional_float(self.memory_max_mb),
        }


@dataclass(frozen=True)
class SloThresholds:
    profile: str
    title: str
    oldest_p50_ms: float
    newest_p50_ms: float
    oldest_p95_ms: float
    newest_p95_ms: float
    flush_lateness_p95_warning_ms: float
    max_error_rate: float = 0.0


@dataclass(frozen=True)
class SloEvaluation:
    passes: bool
    reasons: tuple[str, ...]
    flush_lateness_warning: bool


@dataclass(frozen=True)
class SloPoint:
    service_name: str
    service_label: str
    sessions: int
    results: tuple[AnalysisResult, ...]
    representative: AnalysisResult
    passes: bool
    reasons: tuple[str, ...]
    flush_lateness_warning: bool


@dataclass(frozen=True)
class AnalysisResult:
    service_name: str
    source: str
    multi_cpu_count: float
    summary_file: Path | None
    samples_file: Path | None
    sessions: int
    repeat: int
    warmup_secs: int
    measure_secs: int
    ramp_up_secs: int
    session_start_spread_ms: int
    partials: int
    protocol_errors: int
    inference_errors: int
    timeouts: dict[str, int]
    newest_latency: MetricStats
    oldest_latency: MetricStats
    flush_lateness: MetricStats
    resources: ResourceStats = field(default_factory=ResourceStats)
    newest_latency_samples: tuple[float, ...] = field(default_factory=tuple, repr=False)

    @property
    def workload_label(self) -> str:
        load_shape = []
        if self.ramp_up_secs > 0:
            load_shape.append(f"{self.ramp_up_secs}s ramp")
        if self.session_start_spread_ms > 0:
            load_shape.append(f"{self.session_start_spread_ms}ms start spread")
        load_shape_text = "" if not load_shape else f"{', '.join(load_shape)}, "
        return (
            f"{self.sessions} sessions, "
            f"{load_shape_text}"
            f"{self.warmup_secs}s warmup, "
            f"{self.measure_secs}s measure, "
            f"r{self.repeat}"
        )

    @property
    def workload_slug(self) -> str:
        if self.ramp_up_secs == 0 and self.session_start_spread_ms == 0:
            return f"{self.sessions}s-{self.warmup_secs}w-{self.measure_secs}m-r{self.repeat}"
        return (
            f"{self.sessions}s-{self.warmup_secs}w-{self.measure_secs}m-"
            f"{self.ramp_up_secs}ramp-{self.session_start_spread_ms}spread-r{self.repeat}"
        )

    @property
    def service_label(self) -> str:
        if self.service_name.endswith("-single"):
            return f"{self.service_name[: -len('-single')]} (1 CPU, 1 GiB RAM)"
        if self.service_name.endswith("-multi"):
            cpu_label = format_cpu_count(self.multi_cpu_count)
            return f"{self.service_name[: -len('-multi')]} ({cpu_label} CPUs, {cpu_label} GiB RAM)"
        return self.service_name

    def to_row(self) -> dict[str, str]:
        row = {
            "service_name": self.service_name,
            "service_label": self.service_label,
            "workload_label": self.workload_label,
            "source": self.source,
            "summary_file": "" if self.summary_file is None else str(self.summary_file),
            "samples_file": "" if self.samples_file is None else str(self.samples_file),
            "sessions": str(self.sessions),
            "repeat": str(self.repeat),
            "warmup_secs": str(self.warmup_secs),
            "measure_secs": str(self.measure_secs),
            "ramp_up_secs": str(self.ramp_up_secs),
            "session_start_spread_ms": str(self.session_start_spread_ms),
            "partials": str(self.partials),
            "protocol_errors": str(self.protocol_errors),
            "inference_errors": str(self.inference_errors),
            "timeouts_connect": str(self.timeouts.get("connect", 0)),
            "timeouts_send": str(self.timeouts.get("send", 0)),
            "timeouts_close": str(self.timeouts.get("close", 0)),
            "timeouts_session": str(self.timeouts.get("session", 0)),
        }
        row.update(self.newest_latency.to_columns("newest_latency"))
        row.update(self.oldest_latency.to_columns("oldest_latency"))
        row.update(self.flush_lateness.to_columns("flush_lateness"))
        row.update(self.resources.to_columns())
        return row


def analyze_directory(options: AnalysisOptions) -> list[AnalysisResult]:
    if options.multi_cpu_count <= 0:
        raise ValueError("multi_cpu_count must be positive")

    input_dir = options.input_dir
    out_dir = options.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    paired_summaries: set[Path] = set()
    results: list[AnalysisResult] = []
    for samples_file in sorted(_find_samples(input_dir)):
        summary_file = _find_summary_for_samples(samples_file)
        if summary_file is not None:
            paired_summaries.add(summary_file)
        results.append(_analyze_samples(samples_file, summary_file, options))

    for summary_file in sorted(input_dir.glob("*.json")):
        if summary_file in paired_summaries:
            continue
        if _has_paired_samples(summary_file):
            continue
        results.append(_analyze_summary_only(summary_file, options))

    results.sort(key=lambda result: (*_workload_key(result), result.service_name, result.source))
    _write_summary_csv(out_dir / "summary.csv", results)
    _write_summary_markdown(out_dir / "summary.md", results)
    _write_comparisons_csv(out_dir / "comparisons.csv", results)
    _write_comparisons_markdown(out_dir / "comparisons.md", results)
    _write_interpretation_markdown(out_dir / "interpretation.md", results)
    _write_capacity_csv(out_dir / "capacity.csv", results)
    _write_capacity_markdown(out_dir / "capacity.md", results)
    if (thresholds := _slo_thresholds(options.slo_profile, options.max_error_rate)) is not None:
        _write_slo_capacity_csv(out_dir / "slo_capacity.csv", results, thresholds)
        _write_slo_capacity_markdown(out_dir / "slo_capacity.md", results, thresholds)
        _write_scaling_csv(out_dir / "scaling.csv", results, thresholds, options.multi_cpu_count)
        _write_scaling_markdown(
            out_dir / "scaling.md", results, thresholds, options.multi_cpu_count
        )
    _write_workload_plots(out_dir, results)
    return results


def _find_samples(input_dir: Path) -> list[Path]:
    paths: list[Path] = []
    for suffix in SAMPLE_SUFFIXES:
        paths.extend(input_dir.glob(f"*{suffix}"))
    return paths


def _find_summary_for_samples(samples_file: Path) -> Path | None:
    base = _strip_suffix(samples_file.name, SAMPLE_SUFFIXES)
    for suffix in SUMMARY_SUFFIXES:
        candidate = samples_file.with_name(f"{base}{suffix}")
        if candidate.exists():
            return candidate
    return None


def _find_resources_for_result(path: Path) -> Path | None:
    base = _strip_suffix(path.name, SAMPLE_SUFFIXES + SUMMARY_SUFFIXES)
    for suffix in RESOURCE_SUFFIXES:
        candidate = path.with_name(f"{base}{suffix}")
        if candidate.exists():
            return candidate
    return None


def _has_paired_samples(summary_file: Path) -> bool:
    base = _strip_suffix(summary_file.name, SUMMARY_SUFFIXES)
    return any(summary_file.with_name(f"{base}{suffix}").exists() for suffix in SAMPLE_SUFFIXES)


def _strip_suffix(name: str, suffixes: tuple[str, ...]) -> str:
    for suffix in suffixes:
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return Path(name).stem


def _analyze_samples(
    samples_file: Path,
    summary_file: Path | None,
    options: AnalysisOptions,
) -> AnalysisResult:
    summary = _read_json(summary_file) if summary_file is not None else {}
    samples = _read_samples(samples_file)
    resources_file = _find_resources_for_result(samples_file)
    service_name = str(summary.get("service_name") or _infer_service_name(samples_file))
    return AnalysisResult(
        service_name=service_name,
        source="samples_csv",
        multi_cpu_count=options.multi_cpu_count,
        summary_file=summary_file,
        samples_file=samples_file,
        sessions=_int(summary.get("sessions")),
        repeat=_int(summary.get("repeat"), default=1),
        warmup_secs=_int(summary.get("warmup_secs")),
        measure_secs=_int(summary.get("measure_secs")),
        ramp_up_secs=_int(summary.get("ramp_up_secs")),
        session_start_spread_ms=_int(summary.get("session_start_spread_ms")),
        partials=len(samples["newest_latency_ms"]),
        protocol_errors=_int(summary.get("protocol_errors")),
        inference_errors=_int(summary.get("inference_errors")),
        timeouts=_timeouts(summary),
        newest_latency=_metric_stats(samples["newest_latency_ms"], options),
        oldest_latency=_metric_stats(samples["oldest_latency_ms"], options),
        flush_lateness=_metric_stats(samples["flush_lateness_ms"], options),
        resources=_read_resource_stats(resources_file),
        newest_latency_samples=tuple(samples["newest_latency_ms"]),
    )


def _analyze_summary_only(summary_file: Path, options: AnalysisOptions) -> AnalysisResult:
    summary = _read_json(summary_file)
    resources_file = _find_resources_for_result(summary_file)
    service_name = str(summary.get("service_name") or _infer_service_name(summary_file))
    return AnalysisResult(
        service_name=service_name,
        source="summary_json",
        multi_cpu_count=options.multi_cpu_count,
        summary_file=summary_file,
        samples_file=None,
        sessions=_int(summary.get("sessions")),
        repeat=_int(summary.get("repeat"), default=1),
        warmup_secs=_int(summary.get("warmup_secs")),
        measure_secs=_int(summary.get("measure_secs")),
        ramp_up_secs=_int(summary.get("ramp_up_secs")),
        session_start_spread_ms=_int(summary.get("session_start_spread_ms")),
        partials=_int(summary.get("partials")),
        protocol_errors=_int(summary.get("protocol_errors")),
        inference_errors=_int(summary.get("inference_errors")),
        timeouts=_timeouts(summary),
        newest_latency=_metric_from_summary(summary.get("newest_frame_to_partial_latency")),
        oldest_latency=_metric_from_summary(summary.get("oldest_frame_to_partial_latency")),
        flush_lateness=_metric_from_summary(summary.get("flush_lateness")),
        resources=_read_resource_stats(resources_file),
    )


def _read_json(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def _read_samples(path: Path) -> dict[str, list[float]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        missing = [
            field for field in REQUIRED_SAMPLE_FIELDS if field not in (reader.fieldnames or [])
        ]
        if missing:
            raise ValueError(f"{path} is missing sample columns: {', '.join(missing)}")
        newest: list[float] = []
        oldest: list[float] = []
        flush: list[float] = []
        for row in reader:
            newest.append(float(row["newest_latency_ms"]))
            oldest.append(float(row["oldest_latency_ms"]))
            flush.append(float(row["flush_lateness_ms"]))
    return {
        "newest_latency_ms": newest,
        "oldest_latency_ms": oldest,
        "flush_lateness_ms": flush,
    }


def _read_resource_stats(path: Path | None) -> ResourceStats:
    if path is None:
        return ResourceStats()
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        missing = [
            field for field in REQUIRED_RESOURCE_FIELDS if field not in (reader.fieldnames or [])
        ]
        if missing:
            raise ValueError(f"{path} is missing resource columns: {', '.join(missing)}")
        cpu_pct: list[float] = []
        memory_mb: list[float] = []
        for row in reader:
            cpu_pct.append(float(row["cpu_pct"]))
            memory_mb.append(float(row["memory_bytes"]) / (1024 * 1024))
    if not cpu_pct:
        return ResourceStats(source="resources_csv", resource_file=path)
    cpu_array = np.asarray(cpu_pct, dtype=float)
    memory_array = np.asarray(memory_mb, dtype=float)
    return ResourceStats(
        source="resources_csv",
        resource_file=path,
        samples=len(cpu_pct),
        cpu_avg_pct=float(np.mean(cpu_array)),
        cpu_p95_pct=_percentile(cpu_array, 95.0),
        cpu_max_pct=float(np.max(cpu_array)),
        memory_avg_mb=float(np.mean(memory_array)),
        memory_p95_mb=_percentile(memory_array, 95.0),
        memory_max_mb=float(np.max(memory_array)),
    )


def _metric_stats(values: list[float], options: AnalysisOptions) -> MetricStats:
    if not values:
        return MetricStats()
    array = np.asarray(values, dtype=float)
    ci_ms: dict[str, tuple[float, float]] = {}
    if options.bootstrap > 0 and len(array) > 1:
        for key, percentile in PERCENTILES.items():
            ci_ms[key] = _bootstrap_ci(array, percentile, options)
    return MetricStats(
        p50_ms=_percentile(array, 50.0),
        p95_ms=_percentile(array, 95.0),
        p99_ms=_percentile(array, 99.0),
        p999_ms=_percentile(array, 99.9),
        max_ms=float(np.max(array)),
        ci_ms=ci_ms,
    )


def _percentile(values: np.ndarray, percentile: float) -> float:
    return float(np.percentile(values, percentile, method="inverted_cdf"))


def _bootstrap_ci(
    values: np.ndarray,
    percentile: float,
    options: AnalysisOptions,
) -> tuple[float, float]:
    from scipy.stats import bootstrap

    def statistic(data: np.ndarray) -> float:
        return _percentile(data, percentile)

    result = bootstrap(
        (values,),
        statistic,
        confidence_level=options.confidence,
        n_resamples=options.bootstrap,
        method="percentile",
        random_state=np.random.default_rng(options.seed),
        vectorized=False,
    )
    return float(result.confidence_interval.low), float(result.confidence_interval.high)


def _metric_from_summary(value: object) -> MetricStats:
    if not isinstance(value, dict):
        return MetricStats()
    summary = cast("dict[str, object]", value)
    return MetricStats(
        p50_ms=_float(summary.get("p50_ms")),
        p95_ms=_float(summary.get("p95_ms")),
        p99_ms=_float(summary.get("p99_ms")),
        p999_ms=_float(summary.get("p999_ms")),
        max_ms=_float(summary.get("max_ms")),
    )


def _timeouts(summary: dict[str, Any]) -> dict[str, int]:
    value = summary.get("timeouts")
    if not isinstance(value, dict):
        return {"connect": 0, "send": 0, "close": 0, "session": 0}
    return {key: _int(value.get(key)) for key in ("connect", "send", "close", "session")}


def _infer_service_name(path: Path) -> str:
    base = _strip_suffix(path.name, SAMPLE_SUFFIXES + SUMMARY_SUFFIXES)
    match = re.match(r"(?P<service>.+?)-\d+s-\d+w-\d+m-r\d+$", base)
    if match:
        return match.group("service")
    return base


def _int(value: object, default: int = 0) -> int:
    if value is None:
        return default
    if isinstance(value, int | float | str):
        return int(value)
    raise TypeError(f"expected int-compatible value, got {type(value).__name__}")


def _float(value: object, default: float = 0.0) -> float:
    if value is None:
        return default
    if isinstance(value, int | float | str):
        return float(value)
    raise TypeError(f"expected float-compatible value, got {type(value).__name__}")


def format_float(value: float) -> str:
    return f"{value:.3f}"


def format_optional_float(value: float | None) -> str:
    return "" if value is None else format_float(value)


def format_cpu_count(value: float) -> str:
    return str(int(value)) if value.is_integer() else format_float(value)


def format_percent(value: float | None) -> str:
    return "" if value is None else f"{value:.3f}"


def _workload_key(result: AnalysisResult) -> tuple[int, int, int, int, int, int]:
    return (
        result.sessions,
        result.warmup_secs,
        result.measure_secs,
        result.ramp_up_secs,
        result.session_start_spread_ms,
        result.repeat,
    )


def _group_by_workload(results: list[AnalysisResult]) -> list[list[AnalysisResult]]:
    groups: dict[tuple[int, int, int, int, int, int], list[AnalysisResult]] = {}
    for result in results:
        groups.setdefault(_workload_key(result), []).append(result)
    return [groups[key] for key in sorted(groups)]


def _write_summary_csv(path: Path, results: list[AnalysisResult]) -> None:
    if results:
        rows = [result.to_row() for result in results]
        fieldnames = list(rows[0])
    else:
        rows = []
        fieldnames = [
            "service_name",
            "service_label",
            "workload_label",
            "source",
            "summary_file",
            "samples_file",
            "sessions",
            "repeat",
            "warmup_secs",
            "measure_secs",
            "ramp_up_secs",
            "session_start_spread_ms",
            "partials",
            "protocol_errors",
            "inference_errors",
            "timeouts_connect",
            "timeouts_send",
            "timeouts_close",
            "timeouts_session",
        ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _write_summary_markdown(path: Path, results: list[AnalysisResult]) -> None:
    lines = [
        (
            "| Workload | Service | Source | Partials | Newest p99 ms | "
            "Oldest p99 ms | Flush p99 ms |"
        ),
        "| --- | --- | --- | ---: | ---: | ---: | ---: |",
    ]
    for result in results:
        lines.append(
            "| "
            f"{result.workload_label} | {result.service_label} | "
            f"{result.source} | {result.partials} | "
            f"{format_float(result.newest_latency.p99_ms)} | "
            f"{format_float(result.oldest_latency.p99_ms)} | "
            f"{format_float(result.flush_lateness.p99_ms)} |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _write_comparisons_csv(path: Path, results: list[AnalysisResult]) -> None:
    rows = _comparison_rows(results)
    fieldnames = [
        "workload_label",
        "metric",
        "metric_label",
        "stat",
        "service_name",
        "service_label",
        "value_ms",
        "best_service_name",
        "best_service_label",
        "best_value_ms",
        "diff_from_best_ms",
        "diff_from_best_pct",
        "is_best",
        "direction",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _write_comparisons_markdown(path: Path, results: list[AnalysisResult]) -> None:
    rows = _comparison_rows(results)
    p99_rows = [row for row in rows if row["stat"] == "p99"]
    lines = [
        "# Comparisons",
        "",
        (
            "Lower latency and lateness values are better. Percent differences compare "
            "each service with the best value in the same workload."
        ),
        "",
        "## P99 comparison vs best",
        "",
        "| Workload | Metric | Best service | Service | Value ms | Diff vs best |",
        "| --- | --- | --- | --- | ---: | ---: |",
    ]
    for row in p99_rows:
        diff_pct = row["diff_from_best_pct"]
        diff_ms = row["diff_from_best_ms"]
        if row["is_best"] == "true":
            diff_text = "best"
        elif diff_pct:
            diff_text = f"+{diff_pct}% (+{diff_ms} ms)"
        else:
            diff_text = f"+{diff_ms} ms"
        lines.append(
            "| "
            f"{row['workload_label']} | {row['metric_label']} | "
            f"{row['best_service_label']} | {row['service_label']} | "
            f"{row['value_ms']} | {diff_text} |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _write_interpretation_markdown(path: Path, results: list[AnalysisResult]) -> None:
    rows = _comparison_rows(results)
    p99_rows = [row for row in rows if row["stat"] == "p99"]
    lines = [
        "# Interpretation",
        "",
        (
            "This report translates the analyzer metrics into real-life streaming STT "
            "behavior. Lower values are better for every latency and lateness metric."
        ),
        "",
        "## Metric guide",
        "",
    ]
    for metric, metric_label in COMPARISON_METRICS:
        technical_name, explanation = METRIC_EXPLANATIONS[metric]
        lines.append(f"- {metric_label} ({technical_name}): {explanation}")
    lines.extend(
        [
            (
                "- Percentiles (`p50`, `p95`, `p99`, `p999`, `max`): tail views of the "
                "same measurement. `p99` means 99% of measured partials were at or "
                "below that value."
            ),
            (
                "- P99 bar plots: lower bars mean better tail latency for the newest "
                "audio represented in each partial."
            ),
            (
                "- CDF plots: curves that climb higher farther left mean more partials "
                "arrived quickly; long right tails mean occasional slow updates."
            ),
            "",
            "## Runtime/config comparisons",
            "",
        ]
    )
    if not p99_rows:
        lines.append("No p99 comparison rows were available.")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return

    rows_by_workload: dict[str, list[dict[str, str]]] = {}
    for row in p99_rows:
        rows_by_workload.setdefault(row["workload_label"], []).append(row)
    for workload_label, workload_rows in rows_by_workload.items():
        lines.append(f"### {workload_label}")
        lines.append("")
        for metric, metric_label in COMPARISON_METRICS:
            metric_rows = [row for row in workload_rows if row["metric"] == metric]
            if not metric_rows:
                continue
            best_row = next(row for row in metric_rows if row["is_best"] == "true")
            comparisons = [
                _comparison_sentence(row) for row in metric_rows if row["is_best"] != "true"
            ]
            if comparisons:
                comparison_text = "; ".join(comparisons)
            else:
                comparison_text = "no other runtime/configs in this workload"
            lines.append(
                f"- {metric_label} (`{metric}_p99_ms`): "
                f"{best_row['service_label']} is best at {best_row['value_ms']} ms; "
                f"{comparison_text}."
            )
        lines.append("")
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def _write_capacity_csv(path: Path, results: list[AnalysisResult]) -> None:
    rows = _capacity_rows(results)
    fieldnames = [
        "service_name",
        "service_label",
        "workload_label",
        "sessions",
        "quality_stat",
        "newest_latency_ms",
        "oldest_latency_ms",
        "flush_lateness_ms",
        "protocol_errors",
        "inference_errors",
        "timeouts_total",
        "resource_status",
        "resource_file",
        "resource_samples",
        "cpu_avg_pct",
        "cpu_p95_pct",
        "cpu_max_pct",
        "memory_avg_mb",
        "memory_p95_mb",
        "memory_max_mb",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _write_capacity_markdown(path: Path, results: list[AnalysisResult]) -> None:
    lines = [
        "# Capacity",
        "",
        (
            "Capacity here means the highest concurrency observed in the result set for "
            "each runtime/config. It is not a proven maximum unless the ladder includes "
            "a higher failing or SLO-violating workload."
        ),
        "",
        "## Observed capacity by runtime/config",
        "",
    ]
    if not results:
        lines.append("No results were available.")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return

    for result in _max_session_results(results):
        resource_text = _resource_sentence(result.resources)
        lines.extend(
            [
                f"### {result.service_label}",
                "",
                f"- max tested {result.sessions} sessions ({result.workload_label})",
                (
                    "- p50 quality: "
                    f"newest {format_float(result.newest_latency.p50_ms)} ms, "
                    f"oldest {format_float(result.oldest_latency.p50_ms)} ms, "
                    f"flush lateness {format_float(result.flush_lateness.p50_ms)} ms"
                ),
                (
                    "- p95 quality: "
                    f"newest {format_float(result.newest_latency.p95_ms)} ms, "
                    f"oldest {format_float(result.oldest_latency.p95_ms)} ms, "
                    f"flush lateness {format_float(result.flush_lateness.p95_ms)} ms"
                ),
                (
                    "- p99 quality: "
                    f"newest {format_float(result.newest_latency.p99_ms)} ms, "
                    f"oldest {format_float(result.oldest_latency.p99_ms)} ms, "
                    f"flush lateness {format_float(result.flush_lateness.p99_ms)} ms"
                ),
                f"- resources: {resource_text}",
                "",
            ]
        )
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def _capacity_rows(results: list[AnalysisResult]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for result in results:
        for stat in COMPARISON_STATS:
            row = {
                "service_name": result.service_name,
                "service_label": result.service_label,
                "workload_label": result.workload_label,
                "sessions": str(result.sessions),
                "quality_stat": stat,
                "newest_latency_ms": format_float(_metric_value(result.newest_latency, stat)),
                "oldest_latency_ms": format_float(_metric_value(result.oldest_latency, stat)),
                "flush_lateness_ms": format_float(_metric_value(result.flush_lateness, stat)),
                "protocol_errors": str(result.protocol_errors),
                "inference_errors": str(result.inference_errors),
                "timeouts_total": str(sum(result.timeouts.values())),
            }
            row.update(result.resources.to_columns())
            rows.append(row)
    return rows


def _max_session_results(results: list[AnalysisResult]) -> list[AnalysisResult]:
    by_service: dict[str, AnalysisResult] = {}
    for result in results:
        current = by_service.get(result.service_label)
        if current is None or _capacity_sort_key(result) > _capacity_sort_key(current):
            by_service[result.service_label] = result
    return [by_service[key] for key in sorted(by_service)]


def _capacity_sort_key(result: AnalysisResult) -> tuple[int, int, int, int]:
    return (result.sessions, result.measure_secs, result.warmup_secs, result.repeat)


def _slo_thresholds(profile: str, max_error_rate: float = 0.0) -> SloThresholds | None:
    if profile == SLO_PROFILE_OFF:
        return None
    if profile == SLO_PROFILE_BALANCED_REALTIME:
        return SloThresholds(
            profile=SLO_PROFILE_BALANCED_REALTIME,
            title="Balanced realtime SLO",
            oldest_p50_ms=1200.0,
            newest_p50_ms=200.0,
            oldest_p95_ms=1650.0,
            newest_p95_ms=350.0,
            flush_lateness_p95_warning_ms=100.0,
            max_error_rate=max_error_rate,
        )
    raise ValueError(f"unknown SLO profile {profile!r}; expected one of {', '.join(SLO_PROFILES)}")


def _write_slo_capacity_csv(
    path: Path,
    results: list[AnalysisResult],
    thresholds: SloThresholds,
) -> None:
    rows = _slo_capacity_rows(results, thresholds)
    fieldnames = [
        "service_name",
        "service_label",
        "slo_profile",
        "status",
        "highest_passing_sessions",
        "highest_passing_workload_label",
        "first_failing_sessions",
        "first_failing_workload_label",
        "limiting_reasons",
        "flush_lateness_warning",
        "oldest_p50_slo_ms",
        "newest_p50_slo_ms",
        "oldest_p95_slo_ms",
        "newest_p95_slo_ms",
        "flush_lateness_p95_warning_ms",
        "passing_points",
        "failing_points",
        *_slo_result_fieldnames("pass"),
        *_slo_result_fieldnames("fail"),
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _write_slo_capacity_markdown(
    path: Path,
    results: list[AnalysisResult],
    thresholds: SloThresholds,
) -> None:
    rows = _slo_capacity_rows(results, thresholds)
    if thresholds.max_error_rate <= 0.0:
        error_gate = "protocol errors == 0, inference errors == 0, and total timeouts == 0"
    else:
        error_gate = (
            "error rate <= "
            f"{thresholds.max_error_rate:g} where error rate is "
            "(protocol errors + inference errors + timeouts) / (partials + errors)"
        )
    lines = [
        "# SLO Capacity",
        "",
        f"## {thresholds.title}",
        "",
        (
            f"- Primary gate: oldest p50 <= {format_float(thresholds.oldest_p50_ms)} ms, "
            f"newest p50 <= {format_float(thresholds.newest_p50_ms)} ms, "
            f"{error_gate}."
        ),
        (
            f"- Tail guardrail: oldest p95 <= {format_float(thresholds.oldest_p95_ms)} ms "
            f"and newest p95 <= {format_float(thresholds.newest_p95_ms)} ms."
        ),
        (
            f"- Warning only: flush lateness p95 > "
            f"{format_float(thresholds.flush_lateness_p95_warning_ms)} ms."
        ),
        (
            "- Status meanings: `bounded` has a passing point and a higher failing "
            "point; `lower_bound` has no observed failing point; `no_pass` failed at "
            "the lowest observed point."
        ),
        "",
        "## Capacity by runtime/config",
        "",
    ]
    if not rows:
        lines.append("No results were available.")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return

    for row in rows:
        lines.extend([f"### {row['service_label']}", ""])
        if row["status"] == "bounded":
            lines.append(
                f"- bounded: highest passing {row['highest_passing_sessions']} sessions; "
                f"first failing {row['first_failing_sessions']} sessions"
            )
        elif row["status"] == "lower_bound":
            lines.append(
                f"- lower_bound: highest passing {row['highest_passing_sessions']} sessions; "
                "no failing point observed"
            )
        else:
            lines.append(
                f"- no_pass: lowest observed point failed at "
                f"{row['first_failing_sessions']} sessions"
            )
        if row["limiting_reasons"]:
            lines.append(f"- limiting reasons: {row['limiting_reasons'].replace(',', ', ')}")
        if row["highest_passing_sessions"]:
            lines.append(
                "- highest passing quality: "
                f"oldest p50 {row['pass_oldest_p50_ms']} ms, "
                f"newest p50 {row['pass_newest_p50_ms']} ms, "
                f"oldest p95 {row['pass_oldest_p95_ms']} ms, "
                f"newest p95 {row['pass_newest_p95_ms']} ms, "
                f"oldest p99 {row['pass_oldest_p99_ms']} ms"
            )
            lines.append(f"- highest passing resources: {_slo_resource_sentence(row, 'pass')}")
        if row["first_failing_sessions"]:
            lines.append(
                "- first failing quality: "
                f"oldest p50 {row['fail_oldest_p50_ms']} ms, "
                f"newest p50 {row['fail_newest_p50_ms']} ms, "
                f"oldest p95 {row['fail_oldest_p95_ms']} ms, "
                f"newest p95 {row['fail_newest_p95_ms']} ms, "
                f"oldest p99 {row['fail_oldest_p99_ms']} ms"
            )
        if row["flush_lateness_warning"] == "true":
            lines.append(
                f"- warning: at least one point had flush lateness p95 above "
                f"{format_float(thresholds.flush_lateness_p95_warning_ms)} ms"
            )
        lines.append("")
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def _slo_capacity_rows(
    results: list[AnalysisResult],
    thresholds: SloThresholds,
) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for service_label, points in _slo_points_by_service(results, thresholds).items():
        points = sorted(points, key=lambda point: point.sessions)
        passing_points = [point for point in points if point.passes]
        failing_points = [point for point in points if not point.passes]
        highest_pass = passing_points[-1] if passing_points else None
        if highest_pass is None:
            first_fail = failing_points[0] if failing_points else None
            status = "no_pass"
        else:
            first_fail = next(
                (point for point in failing_points if point.sessions > highest_pass.sessions),
                None,
            )
            status = "bounded" if first_fail is not None else "lower_bound"

        service_name = points[0].service_name
        reasons = _ordered_reasons(first_fail.reasons) if first_fail is not None else ()
        row = {
            "service_name": service_name,
            "service_label": service_label,
            "slo_profile": thresholds.profile,
            "status": status,
            "highest_passing_sessions": "" if highest_pass is None else str(highest_pass.sessions),
            "highest_passing_workload_label": ""
            if highest_pass is None
            else highest_pass.representative.workload_label,
            "first_failing_sessions": "" if first_fail is None else str(first_fail.sessions),
            "first_failing_workload_label": ""
            if first_fail is None
            else first_fail.representative.workload_label,
            "limiting_reasons": ",".join(reasons),
            "flush_lateness_warning": str(
                any(point.flush_lateness_warning for point in points)
            ).lower(),
            "oldest_p50_slo_ms": format_float(thresholds.oldest_p50_ms),
            "newest_p50_slo_ms": format_float(thresholds.newest_p50_ms),
            "oldest_p95_slo_ms": format_float(thresholds.oldest_p95_ms),
            "newest_p95_slo_ms": format_float(thresholds.newest_p95_ms),
            "flush_lateness_p95_warning_ms": format_float(thresholds.flush_lateness_p95_warning_ms),
            "passing_points": str(len(passing_points)),
            "failing_points": str(len(failing_points)),
        }
        row.update(
            _slo_result_columns("pass", highest_pass.representative if highest_pass else None)
        )
        row.update(_slo_result_columns("fail", first_fail.representative if first_fail else None))
        rows.append(row)
    return rows


def _slo_points_by_service(
    results: list[AnalysisResult],
    thresholds: SloThresholds,
) -> dict[str, list[SloPoint]]:
    grouped: dict[tuple[str, int], list[AnalysisResult]] = {}
    for result in results:
        grouped.setdefault((result.service_label, result.sessions), []).append(result)

    by_service: dict[str, list[SloPoint]] = {}
    for (service_label, sessions), point_results in sorted(grouped.items()):
        point_results = sorted(point_results, key=_capacity_sort_key)
        evaluations = [_evaluate_slo(result, thresholds) for result in point_results]
        passes = all(evaluation.passes for evaluation in evaluations)
        reasons = _ordered_reasons(
            reason for evaluation in evaluations for reason in evaluation.reasons
        )
        representative = _representative_slo_result(point_results, thresholds)
        point = SloPoint(
            service_name=point_results[0].service_name,
            service_label=service_label,
            sessions=sessions,
            results=tuple(point_results),
            representative=representative,
            passes=passes,
            reasons=reasons,
            flush_lateness_warning=any(
                evaluation.flush_lateness_warning for evaluation in evaluations
            ),
        )
        by_service.setdefault(service_label, []).append(point)
    return by_service


def _evaluate_slo(result: AnalysisResult, thresholds: SloThresholds) -> SloEvaluation:
    reasons: list[str] = []
    if result.oldest_latency.p50_ms > thresholds.oldest_p50_ms:
        reasons.append("oldest_p50")
    if result.newest_latency.p50_ms > thresholds.newest_p50_ms:
        reasons.append("newest_p50")
    if result.oldest_latency.p95_ms > thresholds.oldest_p95_ms:
        reasons.append("oldest_p95")
    if result.newest_latency.p95_ms > thresholds.newest_p95_ms:
        reasons.append("newest_p95")
    total_errors = result.protocol_errors + result.inference_errors + sum(result.timeouts.values())
    if thresholds.max_error_rate <= 0.0:
        # Strict-zero gate (any error fails).
        if result.protocol_errors > 0:
            reasons.append("protocol_errors")
        if sum(result.timeouts.values()) > 0:
            reasons.append("timeouts")
        if result.inference_errors > 0:
            reasons.append("inference_errors")
    else:
        # Budget mode: aggregate rate against partials + errors.
        denom = result.partials + total_errors
        rate = total_errors / denom if denom > 0 else 0.0
        if rate > thresholds.max_error_rate:
            reasons.append("error_rate")
    return SloEvaluation(
        passes=not reasons,
        reasons=tuple(reasons),
        flush_lateness_warning=(
            result.flush_lateness.p95_ms > thresholds.flush_lateness_p95_warning_ms
        ),
    )


def _representative_slo_result(
    results: list[AnalysisResult],
    thresholds: SloThresholds,
) -> AnalysisResult:
    return max(results, key=lambda result: _slo_result_sort_key(result, thresholds))


def _slo_result_sort_key(
    result: AnalysisResult,
    thresholds: SloThresholds,
) -> tuple[int, int, int, float, float, float, float, float, int]:
    evaluation = _evaluate_slo(result, thresholds)
    return (
        0 if evaluation.passes else 1,
        len(evaluation.reasons),
        result.protocol_errors + sum(result.timeouts.values()),
        result.oldest_latency.p50_ms,
        result.newest_latency.p50_ms,
        result.oldest_latency.p95_ms,
        result.newest_latency.p95_ms,
        result.flush_lateness.p95_ms,
        result.repeat,
    )


def _ordered_reasons(reasons: Iterable[str]) -> tuple[str, ...]:
    unique = set(reasons)
    return tuple(reason for reason in SLO_REASON_ORDER if reason in unique)


def _slo_result_fieldnames(prefix: str) -> list[str]:
    return [
        f"{prefix}_sessions",
        f"{prefix}_workload_label",
        f"{prefix}_newest_p50_ms",
        f"{prefix}_newest_p95_ms",
        f"{prefix}_newest_p99_ms",
        f"{prefix}_oldest_p50_ms",
        f"{prefix}_oldest_p95_ms",
        f"{prefix}_oldest_p99_ms",
        f"{prefix}_flush_lateness_p95_ms",
        f"{prefix}_protocol_errors",
        f"{prefix}_timeouts_total",
        f"{prefix}_resource_status",
        f"{prefix}_cpu_avg_pct",
        f"{prefix}_cpu_p95_pct",
        f"{prefix}_memory_max_mb",
    ]


def _slo_result_columns(prefix: str, result: AnalysisResult | None) -> dict[str, str]:
    if result is None:
        return dict.fromkeys(_slo_result_fieldnames(prefix), "")
    return {
        f"{prefix}_sessions": str(result.sessions),
        f"{prefix}_workload_label": result.workload_label,
        f"{prefix}_newest_p50_ms": format_float(result.newest_latency.p50_ms),
        f"{prefix}_newest_p95_ms": format_float(result.newest_latency.p95_ms),
        f"{prefix}_newest_p99_ms": format_float(result.newest_latency.p99_ms),
        f"{prefix}_oldest_p50_ms": format_float(result.oldest_latency.p50_ms),
        f"{prefix}_oldest_p95_ms": format_float(result.oldest_latency.p95_ms),
        f"{prefix}_oldest_p99_ms": format_float(result.oldest_latency.p99_ms),
        f"{prefix}_flush_lateness_p95_ms": format_float(result.flush_lateness.p95_ms),
        f"{prefix}_protocol_errors": str(result.protocol_errors),
        f"{prefix}_timeouts_total": str(sum(result.timeouts.values())),
        f"{prefix}_resource_status": result.resources.source,
        f"{prefix}_cpu_avg_pct": format_optional_float(result.resources.cpu_avg_pct),
        f"{prefix}_cpu_p95_pct": format_optional_float(result.resources.cpu_p95_pct),
        f"{prefix}_memory_max_mb": format_optional_float(result.resources.memory_max_mb),
    }


def _slo_resource_sentence(row: dict[str, str], prefix: str) -> str:
    if row[f"{prefix}_resource_status"] != "resources_csv":
        return "not captured"
    return (
        f"avg CPU {row[f'{prefix}_cpu_avg_pct']}%, "
        f"p95 CPU {row[f'{prefix}_cpu_p95_pct']}%, "
        f"max RAM {row[f'{prefix}_memory_max_mb']} MiB"
    )


def _write_scaling_csv(
    path: Path,
    results: list[AnalysisResult],
    thresholds: SloThresholds,
    multi_cpu_count: float,
) -> None:
    rows = _scaling_rows(results, thresholds, multi_cpu_count)
    fieldnames = [
        "implementation",
        "single_cpu_count",
        "multi_cpu_count",
        "single_service_name",
        "multi_service_name",
        "single_status",
        "multi_status",
        "single_capacity_sessions",
        "multi_capacity_sessions",
        "single_first_failing_sessions",
        "multi_first_failing_sessions",
        "capacity_lift",
        "scaling_efficiency",
        "additional_cpu_count",
        "added_capacity_sessions",
        "sessions_per_added_cpu",
        "marginal_lift_per_added_cpu",
        "single_limiting_reasons",
        "multi_limiting_reasons",
        "single_oldest_p50_ms",
        "multi_oldest_p50_ms",
        "single_newest_p50_ms",
        "multi_newest_p50_ms",
        "single_oldest_p95_ms",
        "multi_oldest_p95_ms",
        "single_newest_p95_ms",
        "multi_newest_p95_ms",
        "single_cpu_avg_pct",
        "multi_cpu_avg_pct",
        "single_memory_max_mb",
        "multi_memory_max_mb",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _write_scaling_markdown(
    path: Path,
    results: list[AnalysisResult],
    thresholds: SloThresholds,
    multi_cpu_count: float,
) -> None:
    rows = _scaling_rows(results, thresholds, multi_cpu_count)
    multi_cpu_label = format_cpu_count(multi_cpu_count)
    lines = [
        "# Scaling",
        "",
        f"## {multi_cpu_label}-CPU scaling vs 1-CPU capacity",
        "",
        (
            "Capacity uses the same SLO pass/fail logic as `slo_capacity.md`. "
            "A `lower_bound` capacity can make the lift conservative because the "
            "higher failing point was not observed."
        ),
        "",
        f"| Implementation | 1-CPU status | 1-CPU capacity | {multi_cpu_label}-CPU status | "
        f"{multi_cpu_label}-CPU capacity | Lift | Efficiency | Added sessions / extra CPU | "
        "Marginal lift / extra CPU |",
        "| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    if not rows:
        lines.append("| _none_ |  |  |  |  |  |  |  |  |")
    for row in rows:
        lift = f"{row['capacity_lift']}x" if row["capacity_lift"] else ""
        efficiency = (
            f"{float(row['scaling_efficiency']) * 100:.3f}%" if row["scaling_efficiency"] else ""
        )
        marginal_lift = (
            f"{row['marginal_lift_per_added_cpu']}x" if row["marginal_lift_per_added_cpu"] else ""
        )
        lines.append(
            "| "
            f"{row['implementation']} | "
            f"{row['single_status']} | "
            f"{row['single_capacity_sessions']} | "
            f"{row['multi_status']} | "
            f"{row['multi_capacity_sessions']} | "
            f"{lift} | "
            f"{efficiency} | "
            f"{row['sessions_per_added_cpu']} | "
            f"{marginal_lift} |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _scaling_rows(
    results: list[AnalysisResult],
    thresholds: SloThresholds,
    multi_cpu_count: float,
) -> list[dict[str, str]]:
    capacity_by_service = {
        row["service_name"]: row for row in _slo_capacity_rows(results, thresholds)
    }
    implementations = sorted(
        {
            implementation
            for service_name in capacity_by_service
            if (implementation := _implementation_name(service_name)) is not None
        }
    )
    rows: list[dict[str, str]] = []
    for implementation in implementations:
        single = capacity_by_service.get(f"{implementation}-single")
        multi = capacity_by_service.get(f"{implementation}-multi")
        single_capacity = _capacity_sessions(single)
        multi_capacity = _capacity_sessions(multi)
        lift = None
        efficiency = None
        additional_cpu_count = multi_cpu_count - 1.0
        added_capacity = None
        sessions_per_added_cpu = None
        marginal_lift_per_added_cpu = None
        if single_capacity is not None and multi_capacity is not None and single_capacity > 0:
            lift = multi_capacity / single_capacity
            efficiency = lift / multi_cpu_count
            added_capacity = multi_capacity - single_capacity
            if additional_cpu_count > 0.0:
                sessions_per_added_cpu = added_capacity / additional_cpu_count
                marginal_lift_per_added_cpu = (lift - 1.0) / additional_cpu_count
        rows.append(
            {
                "implementation": implementation,
                "single_cpu_count": "1",
                "multi_cpu_count": format_cpu_count(multi_cpu_count),
                "single_service_name": "" if single is None else single["service_name"],
                "multi_service_name": "" if multi is None else multi["service_name"],
                "single_status": _capacity_status(single),
                "multi_status": _capacity_status(multi),
                "single_capacity_sessions": _capacity_sessions_text(single),
                "multi_capacity_sessions": _capacity_sessions_text(multi),
                "single_first_failing_sessions": _first_failing_sessions_text(single),
                "multi_first_failing_sessions": _first_failing_sessions_text(multi),
                "capacity_lift": format_optional_float(lift),
                "scaling_efficiency": format_optional_float(efficiency),
                "additional_cpu_count": format_cpu_count(additional_cpu_count),
                "added_capacity_sessions": "" if added_capacity is None else str(added_capacity),
                "sessions_per_added_cpu": format_optional_float(sessions_per_added_cpu),
                "marginal_lift_per_added_cpu": format_optional_float(marginal_lift_per_added_cpu),
                "single_limiting_reasons": "" if single is None else single["limiting_reasons"],
                "multi_limiting_reasons": "" if multi is None else multi["limiting_reasons"],
                "single_oldest_p50_ms": "" if single is None else single["pass_oldest_p50_ms"],
                "multi_oldest_p50_ms": "" if multi is None else multi["pass_oldest_p50_ms"],
                "single_newest_p50_ms": "" if single is None else single["pass_newest_p50_ms"],
                "multi_newest_p50_ms": "" if multi is None else multi["pass_newest_p50_ms"],
                "single_oldest_p95_ms": "" if single is None else single["pass_oldest_p95_ms"],
                "multi_oldest_p95_ms": "" if multi is None else multi["pass_oldest_p95_ms"],
                "single_newest_p95_ms": "" if single is None else single["pass_newest_p95_ms"],
                "multi_newest_p95_ms": "" if multi is None else multi["pass_newest_p95_ms"],
                "single_cpu_avg_pct": "" if single is None else single["pass_cpu_avg_pct"],
                "multi_cpu_avg_pct": "" if multi is None else multi["pass_cpu_avg_pct"],
                "single_memory_max_mb": "" if single is None else single["pass_memory_max_mb"],
                "multi_memory_max_mb": "" if multi is None else multi["pass_memory_max_mb"],
            }
        )
    return rows


def _implementation_name(service_name: str) -> str | None:
    for (suffix,) in SERVICE_PROFILE_SUFFIXES:
        if service_name.endswith(suffix):
            return service_name[: -len(suffix)]
    return None


def _capacity_status(row: dict[str, str] | None) -> str:
    return "missing" if row is None else row["status"]


def _capacity_sessions(row: dict[str, str] | None) -> int | None:
    if row is None or not row["highest_passing_sessions"]:
        return None
    return int(row["highest_passing_sessions"])


def _capacity_sessions_text(row: dict[str, str] | None) -> str:
    return "" if row is None else row["highest_passing_sessions"]


def _first_failing_sessions_text(row: dict[str, str] | None) -> str:
    return "" if row is None else row["first_failing_sessions"]


def _resource_sentence(resources: ResourceStats) -> str:
    if resources.source != "resources_csv":
        return "not captured"
    return (
        f"avg CPU {format_optional_float(resources.cpu_avg_pct)}%, "
        f"p95 CPU {format_optional_float(resources.cpu_p95_pct)}%, "
        f"max RAM {format_optional_float(resources.memory_max_mb)} MiB"
    )


def _comparison_sentence(row: dict[str, str]) -> str:
    diff_pct = row["diff_from_best_pct"]
    diff_ms = row["diff_from_best_ms"]
    if diff_pct:
        return f"{row['service_label']} is +{diff_pct}% (+{diff_ms} ms)"
    return f"{row['service_label']} is +{diff_ms} ms"


def _comparison_rows(results: list[AnalysisResult]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for workload_results in _group_by_workload(results):
        for metric, metric_label in COMPARISON_METRICS:
            for stat in COMPARISON_STATS:
                values = [
                    (result, _metric_value(_result_metric_stats(result, metric), stat))
                    for result in workload_results
                ]
                best_result, best_value = min(
                    values, key=lambda item: (item[1], item[0].service_label)
                )
                for result, value in values:
                    diff_ms = value - best_value
                    diff_pct = _percent_difference(value, best_value)
                    rows.append(
                        {
                            "workload_label": result.workload_label,
                            "metric": metric,
                            "metric_label": metric_label,
                            "stat": stat,
                            "service_name": result.service_name,
                            "service_label": result.service_label,
                            "value_ms": format_float(value),
                            "best_service_name": best_result.service_name,
                            "best_service_label": best_result.service_label,
                            "best_value_ms": format_float(best_value),
                            "diff_from_best_ms": format_float(diff_ms),
                            "diff_from_best_pct": format_percent(diff_pct),
                            "is_best": str(result == best_result).lower(),
                            "direction": "lower_is_better",
                        }
                    )
    return rows


def _result_metric_stats(result: AnalysisResult, metric: str) -> MetricStats:
    match metric:
        case "newest_latency":
            return result.newest_latency
        case "oldest_latency":
            return result.oldest_latency
        case "flush_lateness":
            return result.flush_lateness
    raise ValueError(f"unknown metric: {metric}")


def _metric_value(stats: MetricStats, stat: str) -> float:
    match stat:
        case "p50":
            return stats.p50_ms
        case "p95":
            return stats.p95_ms
        case "p99":
            return stats.p99_ms
        case "p999":
            return stats.p999_ms
        case "max":
            return stats.max_ms
    raise ValueError(f"unknown stat: {stat}")


def _percent_difference(value: float, best_value: float) -> float | None:
    if best_value == 0.0:
        return 0.0 if value == best_value else None
    return ((value - best_value) / best_value) * 100.0


def _write_workload_plots(out_dir: Path, results: list[AnalysisResult]) -> None:
    _remove_stale_plot_outputs(out_dir)
    workloads = _group_by_workload(results)
    for workload_results in workloads:
        slug = workload_results[0].workload_slug
        _write_p99_plot(out_dir / f"latency_p99_by_service_{slug}.png", workload_results)
        _write_cdf_plot(out_dir / f"latency_cdf_by_service_{slug}.png", workload_results)
    if len(workloads) == 1:
        workload_results = workloads[0]
        _write_p99_plot(out_dir / "latency_p99_by_service.png", workload_results)
        _write_cdf_plot(out_dir / "latency_cdf_by_service.png", workload_results)


def _remove_stale_plot_outputs(out_dir: Path) -> None:
    for pattern in ("latency_p99_by_service*.png", "latency_cdf_by_service*.png"):
        for path in out_dir.glob(pattern):
            path.unlink()


def _write_p99_plot(path: Path, results: list[AnalysisResult]) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    labels = [result.service_label for result in results]
    values = [result.newest_latency.p99_ms for result in results]
    fig, ax = plt.subplots(figsize=(max(6, len(labels) * 1.4), 4))
    ax.bar(labels, values, color="#3578b8")
    ax.set_ylabel("Newest-frame p99 latency (ms, lower is better)")
    ax.set_xlabel("Service and CPU limit")
    if results:
        ax.set_title(results[0].workload_label)
    ax.tick_params(axis="x", labelrotation=35)
    ax.grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(path, dpi=160)
    plt.close(fig)


def _write_cdf_plot(path: Path, results: list[AnalysisResult]) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(7, 4.5))
    plotted = False
    for result in results:
        if not result.newest_latency_samples:
            continue
        values = np.sort(np.asarray(result.newest_latency_samples, dtype=float))
        y = np.arange(1, len(values) + 1) / len(values)
        ax.plot(values, y, label=result.service_label)
        plotted = True
    ax.set_xlabel("Newest-frame latency (ms, lower is better)")
    ax.set_ylabel("Cumulative probability (higher at lower latency is better)")
    if results:
        ax.set_title(results[0].workload_label)
    ax.grid(alpha=0.25)
    if plotted:
        ax.legend()
    else:
        ax.text(0.5, 0.5, "No raw sample CSV files found", ha="center", va="center")
    fig.tight_layout()
    fig.savefig(path, dpi=160)
    plt.close(fig)
