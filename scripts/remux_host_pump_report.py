#!/usr/bin/env python3
"""Classify Remux host-pump throughput from app logs."""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


RECEIVE_RE = re.compile(
    r"host\.pump\.receive "
    r"bytes=(?P<bytes>\d+) "
    r"chunks=(?P<chunks>\d+) "
    r"total=(?P<total>\d+) "
    r"preview=(?P<preview>.*)$"
)

PROCESS_RE = re.compile(
    r"host\.pump\.processOutput end "
    r"accepted=(?P<accepted>\w+) "
    r"bytes=(?P<bytes>\d+) "
    r"chunks=(?P<chunks>\d+) "
    r"elapsed_ms=(?P<elapsed>[0-9.]+)"
)


@dataclass(frozen=True)
class ReceiveBatch:
    source: str
    line: int
    byte_count: int
    chunk_count: int
    total_byte_count: int
    preview: str


@dataclass(frozen=True)
class ProcessBatch:
    source: str
    line: int
    accepted: bool
    byte_count: int
    chunk_count: int
    elapsed_ms: float
    receive: ReceiveBatch | None

    @property
    def payload_class(self) -> str:
        if self.receive is None:
            return "missing_receive"
        return classify_preview(self.receive.preview)


@dataclass(frozen=True)
class ParseResult:
    process_batches: tuple[ProcessBatch, ...]
    unpaired_receives: int
    mismatched_pairs: int


def classify_preview(preview: str) -> str:
    has_extended_output = "%extended-output" in preview
    has_remux_flow = "REMUX_FLOW_" in preview
    has_control_begin = "%begin" in preview or "%end" in preview
    has_layout = "%layout-change" in preview
    has_tmux_signal = any(
        signal in preview
        for signal in (
            "%window-add",
            "%session-window-changed",
            "%window-pane-changed",
            "%layout-change",
        )
    )

    if has_extended_output and (has_control_begin or has_layout or has_tmux_signal):
        return "mixed_output_control"
    if has_extended_output or has_remux_flow:
        return "bulk_output"
    if has_layout:
        return "layout_signal"
    if has_control_begin:
        return "control_response"
    if has_tmux_signal:
        return "tmux_signal"
    if preview:
        return "other"
    return "empty"


def byte_bucket(byte_count: int) -> str:
    if byte_count <= 256:
        return "<=256"
    if byte_count <= 1024:
        return "257..1024"
    if byte_count <= 4096:
        return "1025..4096"
    return ">4096"


def chunk_bucket(chunk_count: int) -> str:
    if chunk_count <= 1:
        return "1"
    if chunk_count == 2:
        return "2"
    if chunk_count <= 4:
        return "3..4"
    return "5+"


def parse_lines(source: str, lines: Iterable[str]) -> ParseResult:
    pending_receives: list[ReceiveBatch] = []
    process_batches: list[ProcessBatch] = []
    mismatched_pairs = 0

    for line_number, line in enumerate(lines, 1):
        if match := RECEIVE_RE.search(line):
            pending_receives.append(
                ReceiveBatch(
                    source=source,
                    line=line_number,
                    byte_count=int(match.group("bytes")),
                    chunk_count=int(match.group("chunks")),
                    total_byte_count=int(match.group("total")),
                    preview=match.group("preview").strip(),
                )
            )
            continue

        if match := PROCESS_RE.search(line):
            byte_count = int(match.group("bytes"))
            chunk_count = int(match.group("chunks"))
            receive = pending_receives.pop(0) if pending_receives else None
            if receive is not None and (
                receive.byte_count != byte_count or receive.chunk_count != chunk_count
            ):
                mismatched_pairs += 1
            process_batches.append(
                ProcessBatch(
                    source=source,
                    line=line_number,
                    accepted=match.group("accepted") == "true",
                    byte_count=byte_count,
                    chunk_count=chunk_count,
                    elapsed_ms=float(match.group("elapsed")),
                    receive=receive,
                )
            )

    return ParseResult(
        process_batches=tuple(process_batches),
        unpaired_receives=len(pending_receives),
        mismatched_pairs=mismatched_pairs,
    )


def parse_paths(paths: Iterable[Path]) -> ParseResult:
    batches: list[ProcessBatch] = []
    unpaired_receives = 0
    mismatched_pairs = 0

    for path in paths:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            result = parse_lines(str(path), handle)
        batches.extend(result.process_batches)
        unpaired_receives += result.unpaired_receives
        mismatched_pairs += result.mismatched_pairs

    return ParseResult(
        process_batches=tuple(batches),
        unpaired_receives=unpaired_receives,
        mismatched_pairs=mismatched_pairs,
    )


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0
    index = round((len(values) - 1) * fraction)
    return values[min(index, len(values) - 1)]


def summarize_bucket(batches: list[ProcessBatch]) -> str:
    if not batches:
        return "count=0"

    elapsed = sorted(batch.elapsed_ms for batch in batches)
    return (
        f"count={len(batches)} "
        f"bytes={sum(batch.byte_count for batch in batches)} "
        f"chunks={sum(batch.chunk_count for batch in batches)} "
        f"avg_ms={statistics.fmean(elapsed):.3f} "
        f"p50_ms={percentile(elapsed, 0.50):.3f} "
        f"p95_ms={percentile(elapsed, 0.95):.3f} "
        f"p99_ms={percentile(elapsed, 0.99):.3f} "
        f"max_ms={elapsed[-1]:.3f}"
    )


def shorten(value: str, limit: int) -> str:
    if len(value) <= limit:
        return value
    return value[: max(0, limit - 3)] + "..."


def print_report(result: ParseResult, top_count: int, preview_limit: int) -> None:
    batches = list(result.process_batches)
    rejected = [batch for batch in batches if not batch.accepted]

    print("host_pump.processOutput summary")
    print(summarize_bucket(batches))
    print(
        "pairing "
        f"unpaired_receives={result.unpaired_receives} "
        f"missing_receives={sum(1 for batch in batches if batch.receive is None)} "
        f"mismatched_pairs={result.mismatched_pairs} "
        f"rejected={len(rejected)}"
    )

    print()
    print("by payload class")
    for payload_class in sorted({batch.payload_class for batch in batches}):
        bucket_batches = [batch for batch in batches if batch.payload_class == payload_class]
        print(f"{payload_class}: {summarize_bucket(bucket_batches)}")

    print()
    print("by byte bucket")
    for bucket in ("<=256", "257..1024", "1025..4096", ">4096"):
        bucket_batches = [batch for batch in batches if byte_bucket(batch.byte_count) == bucket]
        print(f"{bucket}: {summarize_bucket(bucket_batches)}")

    print()
    print("by chunk bucket")
    for bucket in ("1", "2", "3..4", "5+"):
        bucket_batches = [batch for batch in batches if chunk_bucket(batch.chunk_count) == bucket]
        print(f"{bucket}: {summarize_bucket(bucket_batches)}")

    print()
    print(f"top {top_count} slowest")
    for batch in sorted(batches, key=lambda item: item.elapsed_ms, reverse=True)[:top_count]:
        receive = batch.receive
        total = "?" if receive is None else str(receive.total_byte_count)
        receive_line = "?" if receive is None else str(receive.line)
        preview = "" if receive is None else shorten(receive.preview, preview_limit)
        print(
            f"{batch.elapsed_ms:.3f}ms "
            f"bytes={batch.byte_count} "
            f"chunks={batch.chunk_count} "
            f"total={total} "
            f"class={batch.payload_class} "
            f"source={batch.source}:{batch.line} "
            f"receive_line={receive_line} "
            f"preview={preview}"
        )


def run_self_test() -> None:
    synthetic = [
        "Remux latency t=1 host.pump.receive bytes=4096 chunks=4 total=4096 preview=%extended-output %1 0 : REMUX_FLOW_00001 abc",
        "Remux latency t=2 host.pump.processOutput end accepted=true bytes=4096 chunks=4 elapsed_ms=80.000",
        "Remux latency t=3 host.pump.receive bytes=119 chunks=1 total=4215 preview=%begin 1 2 1\\x0D\\x0A%layout-change @1",
        "noise",
        "Remux latency t=4 host.pump.processOutput end accepted=true bytes=119 chunks=1 elapsed_ms=1032.149",
        "Remux latency t=5 host.pump.processOutput end accepted=false bytes=55 chunks=1 elapsed_ms=0.100",
    ]
    result = parse_lines("synthetic.log", synthetic)
    batches = list(result.process_batches)

    assert len(batches) == 3
    assert sum(batch.byte_count for batch in batches) == 4270
    assert result.unpaired_receives == 0
    assert result.mismatched_pairs == 0
    assert sum(1 for batch in batches if batch.receive is None) == 1
    assert batches[0].payload_class == "bulk_output"
    assert batches[1].payload_class == "layout_signal"
    assert batches[2].payload_class == "missing_receive"
    assert percentile(sorted(batch.elapsed_ms for batch in batches), 0.95) == 1032.149
    print("self-test passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize Remux host.pump.processOutput throughput logs."
    )
    parser.add_argument("paths", nargs="*", type=Path, help="App log files to parse.")
    parser.add_argument("--top", type=int, default=12, help="Number of slow batches to print.")
    parser.add_argument(
        "--preview-limit",
        type=int,
        default=140,
        help="Maximum preview characters printed for slow batches.",
    )
    parser.add_argument("--self-test", action="store_true", help="Run parser self-test.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        run_self_test()
        return 0

    if not args.paths:
        print("error: provide at least one log path or --self-test", file=sys.stderr)
        return 2

    missing = [path for path in args.paths if not path.is_file()]
    if missing:
        for path in missing:
            print(f"error: missing log file: {path}", file=sys.stderr)
        return 2

    result = parse_paths(args.paths)
    print_report(result, top_count=args.top, preview_limit=args.preview_limit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
