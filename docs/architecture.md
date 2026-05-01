# Architecture

Remux keeps the iOS app shell separate from the tmux transport and the
Ghostty terminal runtime.

SwiftUI owns presentation and user intent. The transport layer moves bytes.
Ghostty renders terminal surfaces. Persistence is hidden behind repository and
store interfaces.

## Main Types

- `RemuxRootModel`: top-level app coordinator for the library, setup flow,
  terminal sessions, and settings.
- `ConnectionProfileRepository`: persisted saved servers and tmux workspaces.
- `PasswordStore`: saved server passwords, backed by Keychain in live builds.
- `TrustedHostStore`: SSH host identity persistence and validation.
- `TerminalSettingsRepository`: persisted terminal appearance settings.
- `TmuxControlTransport`: byte-stream transport boundary for tmux control mode.
- `GhosttySurfaceScreenModel`: terminal screen coordinator that connects a
  target, transport, and Ghostty runtime.
- `GhosttyRuntimeSurfaceRegistry`: tracks runtime-created Ghostty surfaces and
  focused pane state.

## Runtime Flow

```text
Saved server + workspace
-> TmuxConnectionTarget
-> TmuxControlTransport
-> GhosttyControlHostSurface
-> Ghostty runtime callbacks
-> Ghostty-managed pane surfaces
-> SwiftUI/UIKit shell
```

Transport code does not import UI concepts. Ghostty surface views do not read
repositories directly.

## Persistence

Live builds store app data under the app's application-support root:

- saved servers in JSON
- saved workspaces in JSON
- terminal settings in JSON
- server passwords in Keychain
- trusted host identities in the trusted-host store

UI tests use in-memory repositories and deterministic transports when possible.

## Transport

SSH is the implemented transport. Unsupported transports fail explicitly
instead of silently falling back to SSH.

The transport boundary is small: start, resize, write bytes, stream inbound
bytes, and close. tmux command semantics and terminal rendering stay out of
generic app views.
