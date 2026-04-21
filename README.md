# Remux V2

Remux V2 is being rebuilt as a native iOS tmux client on top of Ghostty.

This workspace was reset after the previous app drifted into rendering a normal
`tmux attach-session` TUI inside one terminal surface. That path is not the
target architecture.

The target path is:

```text
SSH transport
-> tmux -CC control mode
-> Ghostty tmux parser/viewer
-> native Remux window/pane model
-> Ghostty-backed pane surfaces
-> iOS UI
```

The retained architecture and planning context lives under `docs/`.

## Current State

- The app boots into persisted connection setup or a real SSH-backed `tmux -CC attach-session` target.
- Remux owns a real Ghostty runtime on iOS and creates manual-backed `ghostty_surface_t` instances through the embedded runtime API.
- Ghostty runtime callbacks for `create_surface` and `create_surface_tree` are implemented on the Remux side, so tmux-driven child panes can be materialized as native iOS-managed surface trees.
- The visible pane tree now tracks per-top-level focused pane state and tap-to-focus selection.
- The host/control surface is hidden from the UI and marked not visible; visible pane surfaces are marked visible so Ghostty can actually render them.
- Live end-to-end validation now proves tmux creates a native Ghostty pane surface, Remux routes focused-pane input through `ghostty_surface_text`, Ghostty emits `send-keys -H`, and tmux returns live `%output`.
- Current remaining gap: mobile viewport/font sizing and complete initial pane state restoration are still rough.

## Generate Project

```bash
xcodegen generate
```

## Build

```bash
xcodebuild build \
  -project RemuxV2.xcodeproj \
  -scheme RemuxV2 \
  -destination 'generic/platform=iOS Simulator'
```

## Test

```bash
xcodebuild test \
  -project RemuxV2.xcodeproj \
  -scheme RemuxV2 \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

## Debug Seed

Debug builds can seed one saved connection through explicit launch
environment variables. This uses the same JSON profile repository and Keychain
password store as the setup form.

```bash
REMUX_DEBUG_SEED_CONNECTION=1
REMUX_DEBUG_SERVER_NAME="My Mac"
REMUX_DEBUG_SERVER_HOST="server.example.com"
REMUX_DEBUG_SERVER_PORT=22
REMUX_DEBUG_SERVER_USERNAME="alice"
REMUX_DEBUG_SERVER_PASSWORD="<password>"
REMUX_DEBUG_TMUX_SESSION="base"
```

Debug builds can also submit one command to the first focused native tmux pane
after the Ghostty transport is running and the pane surface exists. This goes
through the same raw `ghostty_surface_input` path as user input.

```bash
REMUX_DEBUG_PANE_INPUT="echo REMUX_INPUT_TEST"
```
