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


TRACE_RE = re.compile(
    r"Remux (?:latency|perf|flow|tmuxViewport) "
    r"t=(?P<timestamp>\d+) "
    r"(?P<body>.*)$"
)
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
PREVIEW_RE = re.compile(r"preview=(?P<preview>.*)$")
FLOW_EVENT_RE = re.compile(r"(?:^| )event=(?P<event>[^ ]+)")

NANOS_PER_MILLISECOND = 1_000_000
SIDE_EFFECT_POST_TOLERANCE_NS = 2 * NANOS_PER_MILLISECOND
OUTBOUND_WRITE_KINDS = {
    "hostSurface.onWrite",
    "writeSequencer.enqueue",
    "writeSequencer.send.begin",
    "writeSequencer.send.end",
    "transport.send.begin",
    "transport.send.end",
    "ssh.writeAndFlush.begin",
    "ssh.writeAndFlush.end",
}


@dataclass(frozen=True)
class LogLine:
    source: str
    line: int
    timestamp: int | None
    body: str


@dataclass(frozen=True)
class SideEffect:
    source: str
    line: int
    timestamp: int
    kind: str
    body: str
    query_hint: str | None


@dataclass(frozen=True)
class ReceiveBatch:
    source: str
    line: int
    timestamp: int | None
    byte_count: int
    chunk_count: int
    total_byte_count: int
    preview: str


@dataclass(frozen=True)
class ProcessBatch:
    source: str
    line: int
    timestamp: int | None
    accepted: bool
    byte_count: int
    chunk_count: int
    elapsed_ms: float
    receive: ReceiveBatch | None
    side_effects: tuple[SideEffect, ...] = ()

    @property
    def payload_class(self) -> str:
        if self.receive is None:
            return "missing_receive"
        return classify_receive(self.receive)

    @property
    def start_timestamp(self) -> int | None:
        if self.timestamp is None:
            return None
        return self.timestamp - round(self.elapsed_ms * NANOS_PER_MILLISECOND)

    @property
    def has_correlated_outbound_write(self) -> bool:
        return any(
            effect.kind in OUTBOUND_WRITE_KINDS or effect.kind.startswith("host.write.")
            for effect in self.side_effects
        )

    @property
    def has_correlated_runtime_callback(self) -> bool:
        return any(effect.kind.startswith("runtime.") for effect in self.side_effects)

    @property
    def primary_query_hint(self) -> str:
        hints = [effect.query_hint for effect in self.side_effects if effect.query_hint is not None]
        if not hints:
            return "none"

        priority = [
            "capture_pane",
            "list_panes",
            "display_message",
            "refresh_client",
            "select_window_or_pane",
            "send_keys",
            "new_window",
            "split_window",
            "tmux_other",
        ]
        for hint in priority:
            if hint in hints:
                return hint
        return sorted(set(hints))[0]


@dataclass(frozen=True)
class ParseResult:
    process_batches: tuple[ProcessBatch, ...]
    unpaired_receives: int
    mismatched_pairs: int


def parse_log_line(source: str, line_number: int, line: str) -> LogLine:
    if trace := TRACE_RE.search(line):
        return LogLine(
            source=source,
            line=line_number,
            timestamp=int(trace.group("timestamp")),
            body=trace.group("body"),
        )
    return LogLine(source=source, line=line_number, timestamp=None, body=line)


def classify_receive(receive: ReceiveBatch) -> str:
    preview_class = classify_preview(receive.preview)
    if preview_class != "other":
        return preview_class
    if receive.byte_count >= 1024 and receive.chunk_count > 1:
        return "continuation_fragment"
    return preview_class


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
    has_pane_state_shape = ";VT10x" in preview or re.search(r"%\d+;\d+;\d+;", preview) is not None
    has_capture_response_shape = "\\134x0D" in preview and preview.count("\\134x0D") >= 8

    if has_extended_output and (has_control_begin or has_layout or has_tmux_signal):
        return "mixed_output_control"
    if has_extended_output or has_remux_flow:
        return "bulk_output"
    if has_layout:
        return "layout_signal"
    if has_control_begin and has_pane_state_shape:
        return "pane_state_response"
    if has_control_begin and has_capture_response_shape:
        return "pane_history_response"
    if has_pane_state_shape:
        return "pane_state_fragment"
    if has_control_begin:
        return "control_response"
    if has_tmux_signal:
        return "tmux_signal"
    if preview:
        return "other"
    return "empty"


def side_effect_kind(body: str) -> str | None:
    if body.startswith("hostSurface.onWrite "):
        return "hostSurface.onWrite"
    if body.startswith("writeSequencer.enqueue "):
        return "writeSequencer.enqueue"
    if body.startswith("writeSequencer.send begin "):
        return "writeSequencer.send.begin"
    if body.startswith("writeSequencer.send end "):
        return "writeSequencer.send.end"
    if body.startswith("transport.send begin "):
        return "transport.send.begin"
    if body.startswith("transport.send end "):
        return "transport.send.end"
    if body.startswith("ssh.writeAndFlush begin "):
        return "ssh.writeAndFlush.begin"
    if body.startswith("ssh.writeAndFlush end "):
        return "ssh.writeAndFlush.end"
    if " runtime.action " in body or body.endswith(" runtime.action route=main"):
        return "runtime.action"
    if " runtime.selectSurface " in body or body.endswith(" runtime.selectSurface route=main"):
        return "runtime.selectSurface"
    if " runtime.createSurface" in body:
        return "runtime.createSurface"

    flow_event = FLOW_EVENT_RE.search(body)
    if flow_event:
        event = flow_event.group("event")
        if event.startswith("runtime."):
            return event
        if event.startswith("host.write."):
            return event
        if event.startswith("tmux.query.") and ".response." in event:
            return event
        if event.startswith("tmux.signal.host.pump.processOutput.end."):
            return event

    return None


def preview_from_body(body: str) -> str:
    if preview := PREVIEW_RE.search(body):
        return preview.group("preview")
    return body


def query_hint(body: str) -> str | None:
    preview = preview_from_body(body)
    if "capture-pane" in preview:
        return "capture_pane"
    if "list-panes" in preview:
        return "list_panes"
    if "display-message" in preview:
        return "display_message"
    if "refresh-client" in preview:
        return "refresh_client"
    if "select-window" in preview or "select-pane" in preview:
        return "select_window_or_pane"
    if "send-keys" in preview:
        return "send_keys"
    if "new-window" in preview:
        return "new_window"
    if "split-window" in preview:
        return "split_window"
    if "tmux.query." in body:
        return "tmux_query"
    if "host.write." in body:
        return "tmux_other"
    return None


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


def attach_side_effects(
    batches: list[ProcessBatch],
    side_effects: list[SideEffect],
) -> list[ProcessBatch]:
    attributed: list[ProcessBatch] = []
    for batch in batches:
        start = batch.start_timestamp
        end = batch.timestamp
        if start is None or end is None:
            attributed.append(batch)
            continue

        matched = tuple(
            effect
            for effect in side_effects
            if start <= effect.timestamp <= end + SIDE_EFFECT_POST_TOLERANCE_NS
        )
        attributed.append(
            ProcessBatch(
                source=batch.source,
                line=batch.line,
                timestamp=batch.timestamp,
                accepted=batch.accepted,
                byte_count=batch.byte_count,
                chunk_count=batch.chunk_count,
                elapsed_ms=batch.elapsed_ms,
                receive=batch.receive,
                side_effects=matched,
            )
        )
    return attributed


def parse_lines(source: str, lines: Iterable[str]) -> ParseResult:
    pending_receives: list[ReceiveBatch] = []
    process_batches: list[ProcessBatch] = []
    side_effects: list[SideEffect] = []
    mismatched_pairs = 0

    for line_number, line in enumerate(lines, 1):
        log_line = parse_log_line(source, line_number, line)
        if log_line.timestamp is not None:
            if kind := side_effect_kind(log_line.body):
                side_effects.append(
                    SideEffect(
                        source=source,
                        line=line_number,
                        timestamp=log_line.timestamp,
                        kind=kind,
                        body=log_line.body.strip(),
                        query_hint=query_hint(log_line.body),
                    )
                )

        if match := RECEIVE_RE.search(log_line.body):
            pending_receives.append(
                ReceiveBatch(
                    source=source,
                    line=line_number,
                    timestamp=log_line.timestamp,
                    byte_count=int(match.group("bytes")),
                    chunk_count=int(match.group("chunks")),
                    total_byte_count=int(match.group("total")),
                    preview=match.group("preview").strip(),
                )
            )
            continue

        if match := PROCESS_RE.search(log_line.body):
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
                    timestamp=log_line.timestamp,
                    accepted=match.group("accepted") == "true",
                    byte_count=byte_count,
                    chunk_count=chunk_count,
                    elapsed_ms=float(match.group("elapsed")),
                    receive=receive,
                )
            )

    return ParseResult(
        process_batches=tuple(attach_side_effects(process_batches, side_effects)),
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


def summarize_counted(label: str, batches: list[ProcessBatch]) -> str:
    return f"{label}: {summarize_bucket(batches)}"


def shorten(value: str, limit: int) -> str:
    if len(value) <= limit:
        return value
    return value[: max(0, limit - 3)] + "..."


def effect_counts(batch: ProcessBatch) -> str:
    if not batch.side_effects:
        return "none"

    counts: dict[str, int] = {}
    for effect in batch.side_effects:
        counts[effect.kind] = counts.get(effect.kind, 0) + 1
    return ",".join(f"{kind}:{counts[kind]}" for kind in sorted(counts))


def effect_preview(batch: ProcessBatch, limit: int) -> str:
    if batch.timestamp is None or not batch.side_effects:
        return "none"

    parts: list[str] = []
    for effect in batch.side_effects[:6]:
        delta_ms = (effect.timestamp - batch.timestamp) / NANOS_PER_MILLISECOND
        preview = shorten(preview_from_body(effect.body), limit)
        parts.append(f"{effect.kind}@{delta_ms:+.3f}ms:{preview}")
    if len(batch.side_effects) > 6:
        parts.append(f"...+{len(batch.side_effects) - 6}")
    return " | ".join(parts)


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
    print("by correlated outbound write")
    outbound = [batch for batch in batches if batch.has_correlated_outbound_write]
    no_outbound = [batch for batch in batches if not batch.has_correlated_outbound_write]
    print(summarize_counted("outbound_write", outbound))
    print(summarize_counted("no_outbound_write", no_outbound))

    print()
    print("by correlated runtime callback")
    runtime = [batch for batch in batches if batch.has_correlated_runtime_callback]
    no_runtime = [batch for batch in batches if not batch.has_correlated_runtime_callback]
    print(summarize_counted("runtime_callback", runtime))
    print(summarize_counted("no_runtime_callback", no_runtime))

    print()
    print("by side-effect query hint")
    for hint in sorted({batch.primary_query_hint for batch in batches}):
        bucket_batches = [batch for batch in batches if batch.primary_query_hint == hint]
        print(f"{hint}: {summarize_bucket(bucket_batches)}")

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
            f"correlatedOutboundWrite={batch.has_correlated_outbound_write} "
            f"correlatedRuntimeCallback={batch.has_correlated_runtime_callback} "
            f"queryHint={batch.primary_query_hint} "
            f"effects={effect_counts(batch)} "
            f"source={batch.source}:{batch.line} "
            f"receive_line={receive_line} "
            f"preview={preview} "
            f"effect_preview={effect_preview(batch, preview_limit)}"
        )


def run_self_test() -> None:
    synthetic = [
        "Remux latency t=1 host.pump.receive bytes=4096 chunks=4 total=4096 preview=%extended-output %1 0 : REMUX_FLOW_00001 abc",
        "Remux latency t=80000001 host.pump.processOutput end accepted=true bytes=4096 chunks=4 elapsed_ms=80.000",
        "Remux latency t=81000000 hostSurface.onWrite bytes=42 preview=capture-pane -p -e -q -C -N -t %1\\x0A",
        "Remux latency t=90000000 writeSequencer.enqueue bytes=42 accepted=true startDrain=true elapsed_ms=0.001 preview=capture-pane -p -e -q -C -N -t %1\\x0A",
        "Remux latency t=100000000 host.pump.receive bytes=119 chunks=1 total=4215 preview=%begin 1 2 1\\x0D\\x0A%layout-change @1",
        "noise",
        "Remux latency t=1132149000 host.pump.processOutput end accepted=true bytes=119 chunks=1 elapsed_ms=1032.149",
        "Remux perf t=1132150000 thread=main runtime.action route=main",
        "Remux latency t=1133000000 host.pump.processOutput end accepted=false bytes=55 chunks=1 elapsed_ms=0.100",
    ]
    result = parse_lines("synthetic.log", synthetic)
    batches = list(result.process_batches)

    assert len(batches) == 3
    assert sum(batch.byte_count for batch in batches) == 4270
    assert result.unpaired_receives == 0
    assert result.mismatched_pairs == 0
    assert sum(1 for batch in batches if batch.receive is None) == 1
    assert batches[0].payload_class == "bulk_output"
    assert batches[0].has_correlated_outbound_write
    assert batches[0].primary_query_hint == "capture_pane"
    assert batches[1].payload_class == "layout_signal"
    assert batches[1].has_correlated_runtime_callback
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
