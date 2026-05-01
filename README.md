# Remux V2

Remux V2 is an early iOS client for remote tmux sessions.

It saves SSH servers and tmux session names, opens tmux in control mode, and
renders the terminal through `GhosttyKit`. The goal is a native mobile tmux
client, not an SSH terminal with `tmux attach` running inside it.

## Status

This is active development work. It is not ready to use as a production
terminal client.

Working today:

- Saving SSH servers and tmux session names
- Opening tmux control-mode sessions over SSH
- Storing server passwords in Keychain
- Remembering trusted SSH host identities
- Persisting terminal settings
- Rendering terminal surfaces through `GhosttyKit`

SSH is the only transport available today. Mosh is not implemented yet.

## Project Layout

- [RemuxV2App](RemuxV2App): iOS app source
- [RemuxV2AppTests](RemuxV2AppTests): unit and integration-style tests
- [RemuxV2AppUITests](RemuxV2AppUITests): UI tests
- [docs](docs): project documentation
- [project.yml](project.yml): XcodeGen project definition

## Documentation

- [Overview](docs/overview.md)
- [Architecture](docs/architecture.md)
- [Development](docs/development.md)

## Requirements

- Xcode with iOS 18 SDK support
- XcodeGen
- The `GhosttyKit`terminal-renderer XCFramework at the path configured in
  [project.yml](project.yml)

## Generate the Xcode Project

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
