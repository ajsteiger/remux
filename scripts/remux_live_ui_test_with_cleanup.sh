#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/remux_live_ui_test_with_cleanup.sh --only-testing <test-id> [--only-testing <test-id> ...]
  scripts/remux_live_ui_test_with_cleanup.sh --dry-run-cleanup <manifest-file>

Runs selected Remux live SSH UI tests using /tmp/remux-live-ssh.json and
remotely removes only the exact allowlisted remux-latency-* tmux sessions that
the UI tests record in their cleanup manifest.

This script reads live SSH details from /tmp/remux-live-ssh.json but does not
store credentials in the repository or print the password.
USAGE
}

config="/tmp/remux-live-ssh.json"
destination="platform=iOS Simulator,name=iPhone 17,OS=latest"
declare -a only_testing=()
dry_run_manifest=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --config)
      config="${2:-}"
      [[ -n "$config" ]] || { usage; exit 2; }
      shift 2
      ;;
    --destination)
      destination="${2:-}"
      [[ -n "$destination" ]] || { usage; exit 2; }
      shift 2
      ;;
    --only-testing)
      test_id="${2:-}"
      [[ -n "$test_id" ]] || { usage; exit 2; }
      only_testing+=("$test_id")
      shift 2
      ;;
    --dry-run-cleanup)
      dry_run_manifest="${2:-}"
      [[ -n "$dry_run_manifest" ]] || { usage; exit 2; }
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

session_allowlist='^remux-latency-[A-Za-z0-9._-]+$'

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required tool: %s\n' "$1" >&2
    exit 127
  fi
}

validate_manifest() {
  local manifest="$1"
  local bad=0

  if [[ ! -f "$manifest" ]]; then
    printf 'missing generated-session manifest: %s\n' "$manifest" >&2
    return 1
  fi

  while IFS= read -r session || [[ -n "$session" ]]; do
    [[ -n "$session" ]] || continue
    if [[ ! "$session" =~ $session_allowlist ]]; then
      printf 'refusing non-allowlisted generated session: %s\n' "$session" >&2
      bad=1
    fi
  done <"$manifest"

  return "$bad"
}

manifest_sessions() {
  local manifest="$1"
  validate_manifest "$manifest" >/dev/null || return 1
  awk 'NF { print $0 }' "$manifest" | sort -u
}

if [[ -n "$dry_run_manifest" ]]; then
  validate_manifest "$dry_run_manifest"
  manifest_sessions "$dry_run_manifest" | sed 's/^/dry-run cleanup session: /'
  exit 0
fi

if [[ "${#only_testing[@]}" -eq 0 ]]; then
  echo "At least one --only-testing target is required." >&2
  usage
  exit 2
fi

if [[ ! -f "$config" ]]; then
  printf 'Missing %s; cannot run live SSH UI tests.\n' "$config" >&2
  exit 2
fi

require_tool ruby
require_tool ssh
require_tool xcodebuild

json_string() {
  ruby -rjson -e '
    data = JSON.parse(File.read(ARGV.fetch(0)))
    value = data[ARGV.fetch(1)]
    if value.nil?
      exit(ARGV.fetch(2) == "optional" ? 0 : 2)
    end
    exit 1 unless value.is_a?(String)
    print value
  ' "$config" "$1" "${2:-required}"
}

host="$(json_string host)"
username="$(json_string username)"
password="$(json_string password)"
port="$(json_string port optional)"
port="${port:-22}"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/remux-live-ui-cleanup.XXXXXX")"
manifest="/tmp/remux-live-generated-sessions.txt"
askpass="$work_dir/askpass.sh"
log_dir=".local/logs"
mkdir -p "$log_dir"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
log="$log_dir/live-ui-cleanup-${stamp}.log"
result_bundle="$log_dir/live-ui-cleanup-${stamp}.xcresult"
cleanup_done=0

cat >"$askpass" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$REMUX_LIVE_SSH_PASSWORD"
EOF
chmod 700 "$askpass"
rm -f "$manifest"

cleanup_generated_sessions() {
  local status=0

  if [[ ! -s "$manifest" ]]; then
    echo "No generated tmux sessions were recorded for cleanup."
    return 0
  fi

  if ! validate_manifest "$manifest"; then
    return 1
  fi

  while IFS= read -r session; do
    [[ -n "$session" ]] || continue
    printf 'Cleaning generated tmux session: %s\n' "$session"
    local remote_command
    remote_command="session=$session; tmux_bin=\$(command -v tmux 2>/dev/null || true); if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; \"\$tmux_bin\" kill-session -t \"\$session\" 2>/dev/null || true"

    if ! REMUX_LIVE_SSH_PASSWORD="$password" \
      SSH_ASKPASS="$askpass" \
      SSH_ASKPASS_REQUIRE=force \
      DISPLAY=remux \
      ssh \
        -p "$port" \
        -o BatchMode=no \
        -o NumberOfPasswordPrompts=1 \
        -o ConnectTimeout=10 \
        "$username@$host" \
        "$remote_command" </dev/null; then
      status=1
    fi
  done < <(manifest_sessions "$manifest")

  return "$status"
}

finish() {
  local status=$?
  if [[ "$cleanup_done" -eq 0 ]]; then
    cleanup_generated_sessions || status=$?
  fi
  rm -rf "$work_dir"
  rm -f "$manifest"
  exit "$status"
}
trap finish EXIT

declare -a xcode_args=(
  test
  -project Remux.xcodeproj
  -scheme Remux
  -destination "$destination"
  -resultBundlePath "$result_bundle"
)

for target in "${only_testing[@]}"; do
  xcode_args+=("-only-testing:$target")
done

set +e
REMUX_LIVE_GENERATED_SESSION_MANIFEST="$manifest" \
REMUX_TRACE_LATENCY=1 \
REMUX_TRACE_PERF=1 \
xcodebuild "${xcode_args[@]}" 2>&1 | tee "$log"
xcode_status=$?
set -e

cleanup_generated_sessions
cleanup_status=$?
cleanup_done=1
trap - EXIT
rm -rf "$work_dir"
rm -f "$manifest"

printf 'live UI test log: %s\n' "$log"
printf 'live UI test result bundle: %s\n' "$result_bundle"

if [[ "$xcode_status" -ne 0 ]]; then
  exit "$xcode_status"
fi
exit "$cleanup_status"
