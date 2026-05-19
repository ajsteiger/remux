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


def first_event_after(
    instance: FlowInstance,
    anchor: FlowEvent,
    predicate: Callable[[str], bool],
) -> FlowEvent | None:
    for event in instance.events:
        if event.timestamp >= anchor.timestamp and predicate(event.event):
            return event
    return None


def latest_event_after(
    instance: FlowInstance,
    anchor: FlowEvent,
    predicate: Callable[[str], bool],
) -> FlowEvent | None:
    matched = [
        event
        for event in instance.events
        if event.timestamp >= anchor.timestamp and predicate(event.event)
    ]
    if not matched:
        return None
    return max(matched, key=lambda event: event.timestamp)


def first_event_between(
    instance: FlowInstance,
    start: FlowEvent,
    end: FlowEvent,
    predicate: Callable[[str], bool],
) -> FlowEvent | None:
    for event in instance.events:
        if start.timestamp <= event.timestamp <= end.timestamp and predicate(event.event):
            return event
    return None


def latest_event_between(
    instance: FlowInstance,
    start: FlowEvent,
    end: FlowEvent,
    predicate: Callable[[str], bool],
) -> FlowEvent | None:
    matched = [
        event
        for event in instance.events
        if start.timestamp <= event.timestamp <= end.timestamp and predicate(event.event)
    ]
    if not matched:
        return None
    return max(matched, key=lambda event: event.timestamp)


def after_event(
    anchor: Callable[[FlowInstance], FlowEvent | None],
    predicate: Callable[[str], bool],
) -> Callable[[FlowInstance], FlowEvent | None]:
    def find(instance: FlowInstance) -> FlowEvent | None:
        anchor_event = anchor(instance)
        if anchor_event is None:
            return None
        return first_event_after(instance, anchor_event, predicate)

    return find


def latest_after_event(
    anchor: Callable[[FlowInstance], FlowEvent | None],
    predicate: Callable[[str], bool],
) -> Callable[[FlowInstance], FlowEvent | None]:
    def find(instance: FlowInstance) -> FlowEvent | None:
        anchor_event = anchor(instance)
        if anchor_event is None:
            return None
        return latest_event_after(instance, anchor_event, predicate)

    return find


def topology_installed(instance: FlowInstance) -> FlowEvent | None:
    return first_event(instance, exact("registry.topology.installed"))


def after_topology(predicate: Callable[[str], bool]) -> Callable[[FlowInstance], FlowEvent | None]:
    return after_event(topology_installed, predicate)


def latest_after_topology(predicate: Callable[[str], bool]) -> Callable[[FlowInstance], FlowEvent | None]:
    return latest_after_event(topology_installed, predicate)


def process_output_end(instance: FlowInstance) -> FlowEvent | None:
    return first_event(instance, prefix("tmux.signal.host.pump.processOutput.end."))


def tmux_response(instance: FlowInstance) -> FlowEvent | None:
    return first_event(instance, prefix("tmux.response."))


def runtime_callback_entry(instance: FlowInstance) -> FlowEvent | None:
    return after_event(
        process_output_end,
        any_of(
            "runtime.callback.createSurfaceTree.entry",
            "runtime.callback.createSurface.entry",
        ),
    )(instance)


def runtime_wakeup_entry(instance: FlowInstance) -> FlowEvent | None:
    response = tmux_response(instance)
    callback = runtime_callback_entry(instance)
    if response is None or callback is None:
        return None
    return latest_event_between(
        instance,
        response,
        callback,
        exact("runtime.wakeup.entry"),
    )


def runtime_wakeup_main_actor_schedule(instance: FlowInstance) -> FlowEvent | None:
    entry = runtime_wakeup_entry(instance)
    callback = runtime_callback_entry(instance)
    if entry is None or callback is None:
        return None
    return first_event_between(
        instance,
        entry,
        callback,
        exact("runtime.wakeup.mainActor.schedule"),
    )


def runtime_wakeup_main_actor_begin(instance: FlowInstance) -> FlowEvent | None:
    schedule = runtime_wakeup_main_actor_schedule(instance)
    callback = runtime_callback_entry(instance)
    if schedule is None or callback is None:
        return None
    return first_event_between(
        instance,
        schedule,
        callback,
        exact("runtime.wakeup.mainActor.begin"),
    )


def runtime_wakeup_app_tick_begin(instance: FlowInstance) -> FlowEvent | None:
    begin = runtime_wakeup_main_actor_begin(instance)
    callback = runtime_callback_entry(instance)
    if begin is None or callback is None:
        return None
    return first_event_between(
        instance,
        begin,
        callback,
        exact("runtime.wakeup.appTick.begin"),
    )


def runtime_wakeup_app_tick_end(instance: FlowInstance) -> FlowEvent | None:
    return after_event(
        runtime_wakeup_app_tick_begin,
        exact("runtime.wakeup.appTick.end"),
    )(instance)


def runtime_callback_main_actor_schedule(instance: FlowInstance) -> FlowEvent | None:
    return after_event(
        runtime_callback_entry,
        any_of(
            "runtime.callback.createSurfaceTree.mainActor.schedule",
            "runtime.callback.createSurface.mainActor.schedule",
        ),
    )(instance)


def runtime_callback_main_actor_begin(instance: FlowInstance) -> FlowEvent | None:
    return after_event(
        runtime_callback_entry,
        any_of(
            "runtime.callback.createSurfaceTree.mainActor.begin",
            "runtime.callback.createSurface.mainActor.begin",
        ),
    )(instance)


def registry_callback_begin(instance: FlowInstance) -> FlowEvent | None:
    anchor = runtime_callback_entry(instance) or process_output_end(instance)
    if anchor is None:
        return None
    return first_event_after(
        instance,
        anchor,
        any_of("registry.createSurfaceTree.begin", "registry.createSurface.begin"),
    )


def registry_callback_event(name: str) -> Callable[[FlowInstance], FlowEvent | None]:
    def find(instance: FlowInstance) -> FlowEvent | None:
        start = registry_callback_begin(instance)
        end = topology_installed(instance)
        if start is None or end is None:
            return None
        return first_event_between(instance, start, end, exact(name))

    return find


registry_debug_update_begin = registry_callback_event("registry.debugSummary.update.begin")
registry_debug_update_end = registry_callback_event("registry.debugSummary.update.end")
registry_notify_begin = registry_callback_event("registry.notifyChanged.begin")
registry_notify_end = registry_callback_event("registry.notifyChanged.end")
registry_managed_create_begin = registry_callback_event("registry.managedSurface.create.begin")
registry_managed_create_end = registry_callback_event("registry.managedSurface.create.end")
registry_managed_register_begin = registry_callback_event("registry.managedSurface.register.begin")
registry_managed_register_end = registry_callback_event("registry.managedSurface.register.end")
registry_stage_presentation_begin = registry_callback_event("registry.stagePresentation.begin")
registry_stage_presentation_end = registry_callback_event("registry.stagePresentation.end")
registry_insert_parent_begin = registry_callback_event("registry.insertSplit.parentLookup.begin")
registry_insert_parent_end = registry_callback_event("registry.insertSplit.parentLookup.end")
registry_insert_assign_begin = registry_callback_event("registry.insertSplit.assign.begin")
registry_insert_assign_end = registry_callback_event("registry.insertSplit.assign.end")
registry_tree_decode_begin = registry_callback_event("registry.createSurfaceTree.decode.begin")
registry_tree_decode_end = registry_callback_event("registry.createSurfaceTree.decode.end")
registry_tree_leaves_begin = registry_callback_event("registry.createSurfaceTree.leaves.begin")
registry_tree_leaves_end = registry_callback_event("registry.createSurfaceTree.leaves.end")
registry_tree_build_begin = registry_callback_event("registry.createSurfaceTree.build.begin")
registry_tree_build_end = registry_callback_event("registry.createSurfaceTree.build.end")
registry_tree_install_begin = registry_callback_event("registry.createSurfaceTree.install.begin")
registry_tree_install_end = registry_callback_event("registry.createSurfaceTree.install.end")
registry_tree_handle_write_begin = registry_callback_event("registry.createSurfaceTree.handleWrite.begin")
registry_tree_handle_write_end = registry_callback_event("registry.createSurfaceTree.handleWrite.end")


model_revision_published = after_topology(exact("model.surfaceRegistryRevision.published"))
update_ui_view_begin = after_topology(exact("ui.updateUIView.begin"))
tree_update_begin = after_topology(exact("ui.tree.update.begin"))
tree_sync_begin = after_topology(exact("ui.tree.sync.begin"))
tree_sync_end = after_topology(exact("ui.tree.sync.end"))
tree_update_end = after_topology(exact("ui.tree.update.end"))
layout_visible_begin = after_topology(exact("ui.tree.layoutVisible.begin"))
managed_update_display_begin = after_topology(exact("managed.updateDisplay.begin"))
managed_update_display_applied = after_topology(exact("managed.updateDisplay.applied"))
managed_update_display_end = after_topology(exact("managed.updateDisplay.end"))
display_rendered = after_topology(exact("ui.displayUpdate.rendered"))
record_presentation_begin = after_topology(exact("ui.recordSurfacePresentation.begin"))
view_presented = after_topology(exact("ui.viewPresentation.ready"))
runtime_presentation_ready = after_topology(exact("registry.runtimePresentation.ready"))


def overlay_update_begin(instance: FlowInstance) -> FlowEvent | None:
    start = tree_update_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.update.begin"),
    )


def overlay_update_end(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_update_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.update.end"),
    )


def overlay_clear_begin(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_update_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.clear.begin"),
    )


def overlay_clear_end(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_clear_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.clear.end"),
    )


def overlay_snapshot_begin(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_update_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.snapshot.begin"),
    )


def overlay_snapshot_end(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_snapshot_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.snapshot.end"),
    )


def overlay_hold_begin(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_update_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.hold.begin"),
    )


def overlay_hold_end(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_hold_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.hold.end"),
    )


def overlay_add_snapshot_end(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_snapshot_end(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.addSnapshot.end"),
    )


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
        process_output_end,
    ),
    Segment(
        "tmux_response->runtime_wakeup_entry",
        tmux_response,
        runtime_wakeup_entry,
    ),
    Segment(
        "runtime_wakeup_entry->processOutput_end",
        runtime_wakeup_entry,
        process_output_end,
    ),
    Segment(
        "processOutput_end->runtime_callback_entry",
        process_output_end,
        runtime_callback_entry,
    ),
    Segment(
        "processOutput_end->runtime_wakeup_entry",
        process_output_end,
        runtime_wakeup_entry,
    ),
    Segment(
        "runtime_wakeup_entry->wakeup_mainActor_schedule",
        runtime_wakeup_entry,
        runtime_wakeup_main_actor_schedule,
    ),
    Segment(
        "wakeup_mainActor_schedule->wakeup_mainActor_begin",
        runtime_wakeup_main_actor_schedule,
        runtime_wakeup_main_actor_begin,
    ),
    Segment(
        "wakeup_mainActor_begin->app_tick_begin",
        runtime_wakeup_main_actor_begin,
        runtime_wakeup_app_tick_begin,
    ),
    Segment(
        "app_tick_begin->runtime_callback_entry",
        runtime_wakeup_app_tick_begin,
        runtime_callback_entry,
    ),
    Segment(
        "app_tick_begin->app_tick_end",
        runtime_wakeup_app_tick_begin,
        runtime_wakeup_app_tick_end,
    ),
    Segment(
        "runtime_callback_entry->mainActor_schedule",
        runtime_callback_entry,
        runtime_callback_main_actor_schedule,
    ),
    Segment(
        "mainActor_schedule->mainActor_begin",
        runtime_callback_main_actor_schedule,
        runtime_callback_main_actor_begin,
    ),
    Segment(
        "runtime_callback_entry->mainActor_begin",
        runtime_callback_entry,
        runtime_callback_main_actor_begin,
    ),
    Segment(
        "mainActor_begin->registry_callback_begin",
        runtime_callback_main_actor_begin,
        registry_callback_begin,
    ),
    Segment(
        "runtime_callback_entry->registry_callback_begin",
        runtime_callback_entry,
        registry_callback_begin,
    ),
    Segment(
        "processOutput_end->registry_callback_begin",
        process_output_end,
        registry_callback_begin,
    ),
    Segment(
        "registry_callback_begin->topology_installed",
        registry_callback_begin,
        lambda flow: first_event(flow, exact("registry.topology.installed")),
    ),
    Segment(
        "registry_callback_begin->debug_update_begin",
        registry_callback_begin,
        registry_debug_update_begin,
    ),
    Segment(
        "debug_update_begin->debug_update_end",
        registry_debug_update_begin,
        registry_debug_update_end,
    ),
    Segment(
        "debug_update_end->notify_begin",
        registry_debug_update_end,
        registry_notify_begin,
    ),
    Segment(
        "notify_begin->notify_end",
        registry_notify_begin,
        registry_notify_end,
    ),
    Segment(
        "registry_callback_begin->managed_create_begin",
        registry_callback_begin,
        registry_managed_create_begin,
    ),
    Segment(
        "managed_create_begin->managed_create_end",
        registry_managed_create_begin,
        registry_managed_create_end,
    ),
    Segment(
        "managed_create_end->insert_parent_lookup_begin",
        registry_managed_create_end,
        registry_insert_parent_begin,
    ),
    Segment(
        "insert_parent_lookup_begin->insert_parent_lookup_end",
        registry_insert_parent_begin,
        registry_insert_parent_end,
    ),
    Segment(
        "insert_parent_lookup_end->managed_register_begin",
        registry_insert_parent_end,
        registry_managed_register_begin,
    ),
    Segment(
        "managed_create_end->managed_register_begin",
        registry_managed_create_end,
        registry_managed_register_begin,
    ),
    Segment(
        "managed_register_begin->managed_register_end",
        registry_managed_register_begin,
        registry_managed_register_end,
    ),
    Segment(
        "managed_register_end->insert_assign_begin",
        registry_managed_register_end,
        registry_insert_assign_begin,
    ),
    Segment(
        "insert_assign_begin->insert_assign_end",
        registry_insert_assign_begin,
        registry_insert_assign_end,
    ),
    Segment(
        "insert_assign_end->stage_presentation_begin",
        registry_insert_assign_end,
        registry_stage_presentation_begin,
    ),
    Segment(
        "managed_register_end->stage_presentation_begin",
        registry_managed_register_end,
        registry_stage_presentation_begin,
    ),
    Segment(
        "stage_presentation_begin->stage_presentation_end",
        registry_stage_presentation_begin,
        registry_stage_presentation_end,
    ),
    Segment(
        "stage_presentation_end->topology_installed",
        registry_stage_presentation_end,
        topology_installed,
    ),
    Segment(
        "tree_decode_begin->tree_decode_end",
        registry_tree_decode_begin,
        registry_tree_decode_end,
    ),
    Segment(
        "tree_decode_end->tree_leaves_begin",
        registry_tree_decode_end,
        registry_tree_leaves_begin,
    ),
    Segment(
        "tree_leaves_begin->tree_leaves_end",
        registry_tree_leaves_begin,
        registry_tree_leaves_end,
    ),
    Segment(
        "tree_leaves_end->tree_build_begin",
        registry_tree_leaves_end,
        registry_tree_build_begin,
    ),
    Segment(
        "tree_build_begin->tree_build_end",
        registry_tree_build_begin,
        registry_tree_build_end,
    ),
    Segment(
        "tree_build_end->tree_install_begin",
        registry_tree_build_end,
        registry_tree_install_begin,
    ),
    Segment(
        "tree_install_begin->tree_install_end",
        registry_tree_install_begin,
        registry_tree_install_end,
    ),
    Segment(
        "tree_install_end->tree_handle_write_begin",
        registry_tree_install_end,
        registry_tree_handle_write_begin,
    ),
    Segment(
        "tree_handle_write_begin->tree_handle_write_end",
        registry_tree_handle_write_begin,
        registry_tree_handle_write_end,
    ),
    Segment(
        "tree_handle_write_end->topology_installed",
        registry_tree_handle_write_end,
        topology_installed,
    ),
    Segment(
        "topology_installed->model_revision_published",
        topology_installed,
        model_revision_published,
    ),
    Segment(
        "model_revision_published->updateUIView_begin",
        model_revision_published,
        after_event(model_revision_published, exact("ui.updateUIView.begin")),
    ),
    Segment(
        "topology_installed->updateUIView_begin",
        topology_installed,
        update_ui_view_begin,
    ),
    Segment(
        "updateUIView_begin->tree_update_begin",
        update_ui_view_begin,
        after_event(update_ui_view_begin, exact("ui.tree.update.begin")),
    ),
    Segment(
        "tree_update_begin->tree_sync_begin",
        tree_update_begin,
        after_event(tree_update_begin, exact("ui.tree.sync.begin")),
    ),
    Segment(
        "tree_update_begin->overlay_update_begin",
        tree_update_begin,
        overlay_update_begin,
    ),
    Segment(
        "overlay_update_begin->snapshot_begin",
        overlay_update_begin,
        overlay_snapshot_begin,
    ),
    Segment(
        "snapshot_begin->snapshot_end",
        overlay_snapshot_begin,
        overlay_snapshot_end,
    ),
    Segment(
        "snapshot_end->addSnapshot_end",
        overlay_snapshot_end,
        overlay_add_snapshot_end,
    ),
    Segment(
        "addSnapshot_end->tree_sync_begin",
        overlay_add_snapshot_end,
        tree_sync_begin,
    ),
    Segment(
        "overlay_update_begin->hold_begin",
        overlay_update_begin,
        overlay_hold_begin,
    ),
    Segment(
        "hold_begin->hold_end",
        overlay_hold_begin,
        overlay_hold_end,
    ),
    Segment(
        "hold_end->tree_sync_begin",
        overlay_hold_end,
        tree_sync_begin,
    ),
    Segment(
        "overlay_update_begin->overlay_update_end",
        overlay_update_begin,
        overlay_update_end,
    ),
    Segment(
        "overlay_update_end->tree_sync_begin",
        overlay_update_end,
        tree_sync_begin,
    ),
    Segment(
        "overlay_clear_begin->overlay_clear_end",
        overlay_clear_begin,
        overlay_clear_end,
    ),
    Segment(
        "tree_sync_begin->tree_sync_end",
        tree_sync_begin,
        after_event(tree_sync_begin, exact("ui.tree.sync.end")),
    ),
    Segment(
        "tree_update_begin->tree_sync_end",
        tree_update_begin,
        tree_sync_end,
    ),
    Segment(
        "tree_sync_end->tree_update_end",
        tree_sync_end,
        after_event(tree_sync_end, exact("ui.tree.update.end")),
    ),
    Segment(
        "tree_sync_end->layout_visible_begin",
        tree_sync_end,
        after_event(tree_sync_end, exact("ui.tree.layoutVisible.begin")),
    ),
    Segment(
        "tree_update_end->layout_visible_begin",
        tree_update_end,
        after_event(tree_update_end, exact("ui.tree.layoutVisible.begin")),
    ),
    Segment(
        "layout_visible_begin->managed_update_display_begin",
        layout_visible_begin,
        after_event(layout_visible_begin, exact("managed.updateDisplay.begin")),
    ),
    Segment(
        "managed_update_display_begin->managed_update_display_applied",
        managed_update_display_begin,
        after_event(managed_update_display_begin, exact("managed.updateDisplay.applied")),
    ),
    Segment(
        "managed_update_display_applied->display_rendered",
        managed_update_display_applied,
        after_event(managed_update_display_applied, exact("ui.displayUpdate.rendered")),
    ),
    Segment(
        "display_rendered->managed_update_display_end",
        display_rendered,
        after_event(display_rendered, exact("managed.updateDisplay.end")),
    ),
    Segment(
        "managed_update_display_end->record_presentation_begin",
        managed_update_display_end,
        after_event(managed_update_display_end, exact("ui.recordSurfacePresentation.begin")),
    ),
    Segment(
        "record_presentation_begin->view_presented",
        record_presentation_begin,
        after_event(record_presentation_begin, exact("ui.viewPresentation.ready")),
    ),
    Segment(
        "topology_installed->display_rendered",
        topology_installed,
        display_rendered,
    ),
    Segment(
        "display_rendered->view_presented",
        display_rendered,
        view_presented,
    ),
    Segment(
        "view_presented->runtime_presentation_ready",
        view_presented,
        runtime_presentation_ready,
    ),
    Segment(
        "topology_installed->view_presented",
        topology_installed,
        view_presented,
    ),
    Segment(
        "topology_installed->runtime_presentation_ready",
        topology_installed,
        runtime_presentation_ready,
    ),
    Segment(
        "last_presentation_fact->interactive_ready",
        latest_after_topology(any_of("ui.viewPresentation.ready", "registry.runtimePresentation.ready")),
        lambda flow: first_event(flow, exact("interactive.ready")),
    ),
    Segment(
        "runtime_presentation_ready->interactive_ready",
        runtime_presentation_ready,
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
Remux flow t=8300000 flow=tmux.newWindow event=runtime.callback.createSurfaceTree.entry since_ms=7.300
Remux flow t=8400000 flow=tmux.newWindow event=runtime.callback.createSurfaceTree.mainActor.begin since_ms=7.400
Remux flow t=8450000 flow=tmux.newWindow event=registry.createSurfaceTree.begin since_ms=7.450
Remux flow t=8500000 flow=tmux.newWindow event=tmux.signal.host.pump.processOutput.end.window-add since_ms=7.500
Remux flow t=8550000 flow=tmux.newWindow event=runtime.wakeup.entry since_ms=7.550
Remux flow t=8600000 flow=tmux.newWindow event=runtime.wakeup.mainActor.schedule since_ms=7.600
Remux flow t=8700000 flow=tmux.newWindow event=runtime.wakeup.mainActor.begin since_ms=7.700
Remux flow t=8750000 flow=tmux.newWindow event=runtime.wakeup.appTick.begin since_ms=7.750
Remux flow t=8900000 flow=tmux.newWindow event=runtime.callback.createSurfaceTree.entry since_ms=7.900
Remux flow t=8950000 flow=tmux.newWindow event=runtime.wakeup.appTick.end since_ms=7.950
Remux flow t=9000000 flow=tmux.newWindow event=runtime.callback.createSurfaceTree.mainActor.schedule since_ms=8.000
Remux flow t=9200000 flow=tmux.newWindow event=runtime.callback.createSurfaceTree.mainActor.begin since_ms=8.200
Remux flow t=9300000 flow=tmux.newWindow event=registry.createSurfaceTree.begin since_ms=8.300
Remux flow t=9400000 flow=tmux.newWindow event=registry.createSurfaceTree.decode.begin since_ms=8.400
Remux flow t=9450000 flow=tmux.newWindow event=registry.createSurfaceTree.decode.end since_ms=8.450
Remux flow t=9500000 flow=tmux.newWindow event=registry.createSurfaceTree.leaves.begin since_ms=8.500
Remux flow t=9800000 flow=tmux.newWindow event=registry.createSurfaceTree.leaves.end since_ms=8.800
Remux flow t=9900000 flow=tmux.newWindow event=registry.createSurfaceTree.build.begin since_ms=8.900
Remux flow t=9950000 flow=tmux.newWindow event=registry.createSurfaceTree.build.end since_ms=8.950
Remux flow t=10000000 flow=tmux.newWindow event=registry.createSurfaceTree.install.begin since_ms=9.000
Remux flow t=10500000 flow=tmux.newWindow event=registry.createSurfaceTree.install.end since_ms=9.500
Remux flow t=11000000 flow=tmux.newWindow event=registry.createSurfaceTree.handleWrite.begin since_ms=10.000
Remux flow t=11200000 flow=tmux.newWindow event=registry.createSurfaceTree.handleWrite.end since_ms=10.200
Remux flow t=12000000 flow=tmux.newWindow event=registry.topology.installed since_ms=11.000
Remux flow t=12100000 flow=tmux.newWindow event=model.surfaceRegistryRevision.published since_ms=11.100
Remux flow t=12200000 flow=tmux.newWindow event=ui.updateUIView.begin since_ms=11.200
Remux flow t=12300000 flow=tmux.newWindow event=ui.tree.update.begin since_ms=11.300
Remux flow t=12310000 flow=tmux.newWindow event=ui.presentationOverlay.update.begin since_ms=11.310
Remux flow t=12320000 flow=tmux.newWindow event=ui.presentationOverlay.hold.begin since_ms=11.320
Remux flow t=12370000 flow=tmux.newWindow event=ui.presentationOverlay.hold.end since_ms=11.370
Remux flow t=12390000 flow=tmux.newWindow event=ui.presentationOverlay.update.end since_ms=11.390
Remux flow t=12400000 flow=tmux.newWindow event=ui.tree.sync.begin since_ms=11.400
Remux flow t=12410000 flow=tmux.newWindow event=ui.tree.sync.end since_ms=11.410
Remux flow t=12500000 flow=tmux.newWindow event=ui.tree.layoutVisible.begin since_ms=11.500
Remux flow t=12600000 flow=tmux.newWindow event=managed.updateDisplay.begin since_ms=11.600
Remux flow t=12700000 flow=tmux.newWindow event=managed.updateDisplay.applied since_ms=11.700
Remux flow t=13000000 flow=tmux.newWindow event=ui.displayUpdate.rendered since_ms=12.000
Remux flow t=13100000 flow=tmux.newWindow event=managed.updateDisplay.end since_ms=12.100
Remux flow t=13200000 flow=tmux.newWindow event=ui.recordSurfacePresentation.begin since_ms=12.200
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
Remux flow t=26450000 flow=tmux.splitPane event=runtime.wakeup.entry since_ms=6.450
Remux flow t=26460000 flow=tmux.splitPane event=runtime.wakeup.mainActor.schedule since_ms=6.460
Remux flow t=26500000 flow=tmux.splitPane event=tmux.signal.host.pump.processOutput.end.layout-change since_ms=6.500
Remux flow t=26570000 flow=tmux.splitPane event=runtime.wakeup.mainActor.begin since_ms=6.570
Remux flow t=26580000 flow=tmux.splitPane event=runtime.wakeup.appTick.begin since_ms=6.580
Remux flow t=26600000 flow=tmux.splitPane event=runtime.callback.createSurface.entry since_ms=6.600
Remux flow t=26650000 flow=tmux.splitPane event=runtime.wakeup.appTick.end since_ms=6.650
Remux flow t=26700000 flow=tmux.splitPane event=runtime.callback.createSurface.mainActor.begin since_ms=6.700
Remux flow t=27000000 flow=tmux.splitPane event=registry.createSurface.begin since_ms=7.000
Remux flow t=27050000 flow=tmux.splitPane event=registry.debugSummary.update.begin since_ms=7.050
Remux flow t=27060000 flow=tmux.splitPane event=registry.debugSummary.update.end since_ms=7.060
Remux flow t=27070000 flow=tmux.splitPane event=registry.notifyChanged.begin since_ms=7.070
Remux flow t=27090000 flow=tmux.splitPane event=registry.notifyChanged.end since_ms=7.090
Remux flow t=27100000 flow=tmux.splitPane event=registry.managedSurface.create.begin since_ms=7.100
Remux flow t=27400000 flow=tmux.splitPane event=registry.managedSurface.create.end since_ms=7.400
Remux flow t=27450000 flow=tmux.splitPane event=registry.insertSplit.parentLookup.begin since_ms=7.450
Remux flow t=27500000 flow=tmux.splitPane event=registry.insertSplit.parentLookup.end since_ms=7.500
Remux flow t=27600000 flow=tmux.splitPane event=registry.managedSurface.register.begin since_ms=7.600
Remux flow t=27700000 flow=tmux.splitPane event=registry.managedSurface.register.end since_ms=7.700
Remux flow t=27750000 flow=tmux.splitPane event=registry.insertSplit.assign.begin since_ms=7.750
Remux flow t=27800000 flow=tmux.splitPane event=registry.insertSplit.assign.end since_ms=7.800
Remux flow t=27850000 flow=tmux.splitPane event=registry.stagePresentation.begin since_ms=7.850
Remux flow t=27900000 flow=tmux.splitPane event=registry.stagePresentation.end since_ms=7.900
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
    assert "processOutput_end->runtime_callback_entry: n=1 p50_ms=0.400" in output
    assert "tmux_response->runtime_wakeup_entry: n=1 p50_ms=0.550" in output
    assert "tmux_response->runtime_wakeup_entry: n=1 p50_ms=0.450" in output
    assert "runtime_wakeup_entry->processOutput_end: n=1 p50_ms=0.050" in output
    assert "processOutput_end->runtime_wakeup_entry: n=1 p50_ms=0.050" in output
    assert (
        "processOutput_end->runtime_wakeup_entry: "
        "n=0 missing=0 out_of_order=1"
    ) in output
    assert (
        "runtime_wakeup_entry->wakeup_mainActor_schedule: "
        "n=1 p50_ms=0.050"
    ) in output
    assert (
        "wakeup_mainActor_schedule->wakeup_mainActor_begin: "
        "n=1 p50_ms=0.100"
    ) in output
    assert "wakeup_mainActor_begin->app_tick_begin: n=1 p50_ms=0.050" in output
    assert "app_tick_begin->runtime_callback_entry: n=1 p50_ms=0.150" in output
    assert "app_tick_begin->app_tick_end: n=1 p50_ms=0.200" in output
    assert "mainActor_schedule->mainActor_begin: n=1 p50_ms=0.200" in output
    assert "runtime_callback_entry->registry_callback_begin: n=1 p50_ms=0.400" in output
    assert "mainActor_begin->registry_callback_begin: n=1 p50_ms=0.100" in output
    assert "processOutput_end->registry_callback_begin: n=1 p50_ms=0.800" in output
    assert "tree_decode_begin->tree_decode_end: n=1 p50_ms=0.050" in output
    assert "tree_leaves_begin->tree_leaves_end: n=1 p50_ms=0.300" in output
    assert "tree_install_begin->tree_install_end: n=1 p50_ms=0.500" in output
    assert "tree_handle_write_end->topology_installed: n=1 p50_ms=0.800" in output
    assert "managed_create_begin->managed_create_end: n=1 p50_ms=0.300" in output
    assert "insert_parent_lookup_begin->insert_parent_lookup_end: n=1 p50_ms=0.050" in output
    assert "managed_register_begin->managed_register_end: n=1 p50_ms=0.100" in output
    assert "stage_presentation_begin->stage_presentation_end: n=1 p50_ms=0.050" in output
    assert "topology_installed->model_revision_published: n=1 p50_ms=0.100" in output
    assert "tree_update_begin->overlay_update_begin: n=1 p50_ms=0.010" in output
    assert "overlay_update_begin->hold_begin: n=1 p50_ms=0.010" in output
    assert "hold_begin->hold_end: n=1 p50_ms=0.050" in output
    assert "hold_end->tree_sync_begin: n=1 p50_ms=0.030" in output
    assert "overlay_update_begin->overlay_update_end: n=1 p50_ms=0.080" in output
    assert "overlay_update_end->tree_sync_begin: n=1 p50_ms=0.010" in output
    assert "managed_update_display_applied->display_rendered: n=1 p50_ms=0.300" in output
    assert "record_presentation_begin->view_presented: n=1 p50_ms=0.800" in output
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
