#!/usr/bin/env python3
"""Summarize Remux topology action flow segments from unified log exports."""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable


FLOW_RE = re.compile(
    r"Remux flow t=(?P<timestamp>\d+) "
    r"flow=(?P<flow>tmux\.(?:newWindow|splitPane)) "
    r"event=(?P<event>[^ ]+) "
    r"since_ms=(?P<since>[0-9.]+)"
)


@dataclass(frozen=True)
class FlowEvent:
    timestamp: int
    flow: str
    event: str
    since_ms: float
    source: str


@dataclass
class FlowInstance:
    flow: str
    started_at: int
    events: list[FlowEvent]


@dataclass(frozen=True)
class Segment:
    name: str
    start: Callable[[FlowInstance], FlowEvent | None]
    end: Callable[[FlowInstance], FlowEvent | None]


def first_event(
    instance: FlowInstance,
    predicate: Callable[[str], bool],
) -> FlowEvent | None:
    for event in instance.events:
        if predicate(event.event):
            return event
    return None


def exact(name: str) -> Callable[[str], bool]:
    return lambda event: event == name


def prefix(value: str) -> Callable[[str], bool]:
    return lambda event: event.startswith(value)


def any_of(*names: str) -> Callable[[str], bool]:
    expected = set(names)
    return lambda event: event in expected


def latest_event(
    instance: FlowInstance,
    predicate: Callable[[str], bool],
) -> FlowEvent | None:
    matched = [event for event in instance.events if predicate(event.event)]
    if not matched:
        return None
    return max(matched, key=lambda event: event.timestamp)


SEGMENTS = [
    Segment(
        "send_end->ssh_channel_read",
        lambda flow: first_event(flow, exact("host.write.send.end")),
        lambda flow: first_event(flow, prefix("tmux.signal.ssh.channelRead.")),
    ),
    Segment(
        "ssh_channel_read->host_pump_receive",
        lambda flow: first_event(flow, prefix("tmux.signal.ssh.channelRead.")),
        lambda flow: first_event(flow, prefix("tmux.signal.host.pump.receive.")),
    ),
    Segment(
        "host_pump_receive->sequencer_enqueue",
        lambda flow: first_event(flow, prefix("tmux.signal.host.pump.receive.")),
        lambda flow: first_event(flow, prefix("tmux.signal.sequencer.enqueue.")),
    ),
    Segment(
        "sequencer_enqueue->sequencer_drain",
        lambda flow: first_event(flow, prefix("tmux.signal.sequencer.enqueue.")),
        lambda flow: first_event(flow, prefix("tmux.signal.sequencer.drain.")),
    ),
    Segment(
        "sequencer_drain->tmux_response",
        lambda flow: first_event(flow, prefix("tmux.signal.sequencer.drain.")),
        lambda flow: first_event(flow, prefix("tmux.response.")),
    ),
    Segment(
        "tmux_response->processOutput_end",
        lambda flow: first_event(flow, prefix("tmux.response.")),
        lambda flow: first_event(flow, prefix("tmux.signal.host.pump.processOutput.end.")),
    ),
    Segment(
        "processOutput_end->registry_callback_begin",
        lambda flow: first_event(flow, prefix("tmux.signal.host.pump.processOutput.end.")),
        lambda flow: first_event(
            flow,
            any_of("registry.createSurfaceTree.begin", "registry.createSurface.begin"),
        ),
    ),
    Segment(
        "registry_callback_begin->topology_installed",
        lambda flow: first_event(
            flow,
            any_of("registry.createSurfaceTree.begin", "registry.createSurface.begin"),
        ),
        lambda flow: first_event(flow, exact("registry.topology.installed")),
    ),
    Segment(
        "topology_installed->display_rendered",
        lambda flow: first_event(flow, exact("registry.topology.installed")),
        lambda flow: first_event(flow, exact("ui.displayUpdate.rendered")),
    ),
    Segment(
        "display_rendered->view_presented",
        lambda flow: first_event(flow, exact("ui.displayUpdate.rendered")),
        lambda flow: first_event(flow, exact("ui.viewPresentation.ready")),
    ),
    Segment(
        "view_presented->runtime_presentation_ready",
        lambda flow: first_event(flow, exact("ui.viewPresentation.ready")),
        lambda flow: first_event(flow, exact("registry.runtimePresentation.ready")),
    ),
    Segment(
        "topology_installed->view_presented",
        lambda flow: first_event(flow, exact("registry.topology.installed")),
        lambda flow: first_event(flow, exact("ui.viewPresentation.ready")),
    ),
    Segment(
        "topology_installed->runtime_presentation_ready",
        lambda flow: first_event(flow, exact("registry.topology.installed")),
        lambda flow: first_event(flow, exact("registry.runtimePresentation.ready")),
    ),
    Segment(
        "last_presentation_fact->interactive_ready",
        lambda flow: latest_event(
            flow,
            any_of("ui.viewPresentation.ready", "registry.runtimePresentation.ready"),
        ),
        lambda flow: first_event(flow, exact("interactive.ready")),
    ),
    Segment(
        "runtime_presentation_ready->interactive_ready",
        lambda flow: first_event(flow, exact("registry.runtimePresentation.ready")),
        lambda flow: first_event(flow, exact("interactive.ready")),
    ),
    Segment(
        "topology_installed->interactive_ready",
        lambda flow: first_event(flow, exact("registry.topology.installed")),
        lambda flow: first_event(flow, exact("interactive.ready")),
    ),
    Segment(
        "send_end->interactive_ready",
        lambda flow: first_event(flow, exact("host.write.send.end")),
        lambda flow: first_event(flow, exact("interactive.ready")),
    ),
]


def parse_events(paths: Iterable[Path]) -> list[FlowEvent]:
    events: dict[tuple[int, str, str], FlowEvent] = {}
    for path in paths:
        for line in path.read_text(errors="replace").splitlines():
            match = FLOW_RE.search(line)
            if match is None:
                continue

            event = FlowEvent(
                timestamp=int(match.group("timestamp")),
                flow=match.group("flow"),
                event=match.group("event"),
                since_ms=float(match.group("since")),
                source=str(path),
            )
            events[(event.timestamp, event.flow, event.event)] = event

    return sorted(events.values(), key=lambda event: event.timestamp)


def group_flow_instances(events: Iterable[FlowEvent]) -> list[FlowInstance]:
    start_events = {
        "tmux.newWindow": "ui.tap.newWindow",
        "tmux.splitPane": "ui.tap.splitPane",
    }
    active: dict[str, FlowInstance] = {}
    completed: list[FlowInstance] = []

    for event in events:
        if event.event == start_events[event.flow]:
            active[event.flow] = FlowInstance(
                flow=event.flow,
                started_at=event.timestamp,
                events=[],
            )

        instance = active.get(event.flow)
        if instance is None:
            continue

        instance.events.append(event)
        if event.event == "interactive.ready":
            completed.append(instance)
            del active[event.flow]

    return completed


def percentile(values: list[float], percentile_value: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("percentile requires at least one value")

    position = (len(ordered) - 1) * percentile_value
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def segment_duration_ms(start: FlowEvent, end: FlowEvent) -> float:
    return (end.timestamp - start.timestamp) / 1_000_000


def report(instances: list[FlowInstance]) -> str:
    lines = [f"distinct_action_flows={len(instances)}"]
    for flow in ("tmux.newWindow", "tmux.splitPane"):
        flow_instances = [instance for instance in instances if instance.flow == flow]
        lines.append(f"[{flow}] n={len(flow_instances)}")
        for segment in SEGMENTS:
            values: list[float] = []
            missing = 0
            out_of_order = 0
            for instance in flow_instances:
                start = segment.start(instance)
                end = segment.end(instance)
                if start is None or end is None:
                    missing += 1
                    continue
                if end.timestamp < start.timestamp:
                    out_of_order += 1
                    continue
                values.append(segment_duration_ms(start, end))

            if values:
                line = (
                    f"{segment.name}: "
                    f"n={len(values)} "
                    f"p50_ms={statistics.median(values):.3f} "
                    f"p95_ms={percentile(values, 0.95):.3f} "
                    f"max_ms={max(values):.3f}"
                )
                if missing:
                    line += f" missing={missing}"
                if out_of_order:
                    line += f" out_of_order={out_of_order}"
                lines.append(line)
            else:
                lines.append(
                    f"{segment.name}: n=0 missing={missing} out_of_order={out_of_order}"
                )

    return "\n".join(lines)


def run_self_test() -> None:
    sample = """
Remux flow t=1000000 flow=tmux.newWindow event=ui.tap.newWindow since_ms=0.000
Remux flow t=2000000 flow=tmux.newWindow event=host.write.send.end since_ms=1.000
Remux flow t=3000000 flow=tmux.newWindow event=tmux.signal.ssh.channelRead.window-add since_ms=2.000
Remux flow t=4000000 flow=tmux.newWindow event=tmux.signal.host.pump.receive.window-add since_ms=3.000
Remux flow t=5000000 flow=tmux.newWindow event=tmux.signal.sequencer.enqueue.window-add since_ms=4.000
Remux flow t=7000000 flow=tmux.newWindow event=tmux.signal.sequencer.drain.window-add since_ms=6.000
Remux flow t=8000000 flow=tmux.newWindow event=tmux.response.window-add since_ms=7.000
Remux flow t=8500000 flow=tmux.newWindow event=tmux.signal.host.pump.processOutput.end.window-add since_ms=7.500
Remux flow t=9000000 flow=tmux.newWindow event=registry.createSurfaceTree.begin since_ms=8.000
Remux flow t=12000000 flow=tmux.newWindow event=registry.topology.installed since_ms=11.000
Remux flow t=13000000 flow=tmux.newWindow event=ui.displayUpdate.rendered since_ms=12.000
Remux flow t=14000000 flow=tmux.newWindow event=ui.viewPresentation.ready since_ms=13.000
Remux flow t=16000000 flow=tmux.newWindow event=registry.runtimePresentation.ready since_ms=15.000
Remux flow t=17000000 flow=tmux.newWindow event=interactive.ready since_ms=16.000
Remux flow t=20000000 flow=tmux.splitPane event=ui.tap.splitPane since_ms=0.000
Remux flow t=21000000 flow=tmux.splitPane event=host.write.send.end since_ms=1.000
Remux flow t=22000000 flow=tmux.splitPane event=tmux.signal.ssh.channelRead.layout-change since_ms=2.000
Remux flow t=23000000 flow=tmux.splitPane event=tmux.signal.host.pump.receive.layout-change since_ms=3.000
Remux flow t=24000000 flow=tmux.splitPane event=tmux.signal.sequencer.enqueue.layout-change since_ms=4.000
Remux flow t=25000000 flow=tmux.splitPane event=tmux.signal.sequencer.drain.layout-change since_ms=5.000
Remux flow t=26000000 flow=tmux.splitPane event=tmux.response.layout-change since_ms=6.000
Remux flow t=26500000 flow=tmux.splitPane event=tmux.signal.host.pump.processOutput.end.layout-change since_ms=6.500
Remux flow t=27000000 flow=tmux.splitPane event=registry.createSurface.begin since_ms=7.000
Remux flow t=28000000 flow=tmux.splitPane event=registry.topology.installed since_ms=8.000
Remux flow t=29000000 flow=tmux.splitPane event=registry.runtimePresentation.ready since_ms=9.000
Remux flow t=30000000 flow=tmux.splitPane event=ui.viewPresentation.ready since_ms=10.000
Remux flow t=31000000 flow=tmux.splitPane event=interactive.ready since_ms=11.000
Remux flow t=1000000 flow=tmux.newWindow event=ui.tap.newWindow since_ms=0.000
""".strip()
    events = []
    for line in sample.splitlines():
        match = FLOW_RE.search(line)
        if match is None:
            continue
        events.append(
            FlowEvent(
                timestamp=int(match.group("timestamp")),
                flow=match.group("flow"),
                event=match.group("event"),
                since_ms=float(match.group("since")),
                source="self-test",
            )
        )

    instances = group_flow_instances(events)
    output = report(instances)
    assert "distinct_action_flows=2" in output
    assert "send_end->ssh_channel_read: n=1 p50_ms=1.000" in output
    assert "topology_installed->interactive_ready: n=1 p50_ms=5.000" in output
    assert (
        "view_presented->runtime_presentation_ready: "
        "n=0 missing=0 out_of_order=1"
    ) in output
    assert "last_presentation_fact->interactive_ready: n=1 p50_ms=1.000" in output


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize Remux tmux topology flow segment timings."
    )
    parser.add_argument("logs", nargs="*", type=Path, help="Unified log text exports")
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run the built-in parser smoke test",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
        return 0

    if not args.logs:
        print("no log files supplied", file=sys.stderr)
        return 2

    missing = [path for path in args.logs if not path.is_file()]
    if missing:
        for path in missing:
            print(f"missing log file: {path}", file=sys.stderr)
        return 2

    print(report(group_flow_instances(parse_events(args.logs))))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
