#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/remux_live_regression_matrix.sh [--label <name>] [--destination <xcode-destination>] [--config <path>] [--case <case>]... [--continue-on-failure]
  scripts/remux_live_regression_matrix.sh --list

Runs a repeatable live Remux regression matrix through
scripts/remux_live_ui_test_with_cleanup.sh. Use the same cases and destination
on two checkouts or commits before comparing behavior or performance.

Default cases:
  startup action keyboard high-output scroll foreground

Available cases:
  startup      Live SSH startup, input, rendered-content screenshot
  action       New-window/split/select/remove action cycle
  keyboard     Keyboard show/hide resize path
  high-output  Large-output render and terminal responsiveness
  scroll       Scrollback gesture moves rendered content
  foreground   Background/foreground retention and post-foreground action
  warm         Close/reopen warm SSH root reuse
  prewarm      Library prewarmed SSH root path
USAGE
}

case_test_id() {
  case "$1" in
    startup)
      printf '%s\n' 'RemuxUITests/RemuxAppUITests/testLiveSSHSeededServerOpensReadyTerminalWhenConfigured'
      ;;
    action)
      printf '%s\n' 'RemuxUITests/RemuxAppUITests/testLiveSSHTmuxActionCycleWhenConfigured'
      ;;
    keyboard)
      printf '%s\n' 'RemuxUITests/RemuxAppUITests/testLiveSSHKeyboardResizeTraceWhenConfigured'
      ;;
    high-output)
      printf '%s\n' 'RemuxUITests/RemuxAppUITests/testLiveHighOutputRuntimeWhenConfigured'
      ;;
    scroll)
      printf '%s\n' 'RemuxUITests/RemuxAppUITests/testLiveTerminalScrollbackGestureWhenConfigured'
      ;;
    foreground)
      printf '%s\n' 'RemuxUITests/RemuxAppUITests/testLiveSSHBackgroundForegroundRetainsTerminalWhenConfigured'
      ;;
    warm)
      printf '%s\n' 'RemuxUITests/RemuxAppUITests/testLiveWarmSSHRootReuseWhenConfigured'
      ;;
    prewarm)
      printf '%s\n' 'RemuxUITests/RemuxAppUITests/testLiveLibraryPrewarmedSSHRootWhenConfigured'
      ;;
    *)
      return 1
      ;;
  esac
}

print_cases() {
  for name in startup action keyboard high-output scroll foreground warm prewarm; do
    printf '%-12s %s\n' "$name" "$(case_test_id "$name")"
  done
}

safe_token() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

config="/tmp/remux-live-ssh.json"
destination="platform=iOS Simulator,name=iPhone 17,OS=latest"
label=""
continue_on_failure=0
declare -a cases=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --list)
      print_cases
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
    --label)
      label="${2:-}"
      [[ -n "$label" ]] || { usage; exit 2; }
      shift 2
      ;;
    --case)
      case_name="${2:-}"
      [[ -n "$case_name" ]] || { usage; exit 2; }
      case_test_id "$case_name" >/dev/null || {
        printf 'unknown regression case: %s\n' "$case_name" >&2
        print_cases >&2
        exit 2
      }
      cases+=("$case_name")
      shift 2
      ;;
    --continue-on-failure)
      continue_on_failure=1
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "${#cases[@]}" -eq 0 ]]; then
  cases=(startup action keyboard high-output scroll foreground)
fi

if [[ ! -f "$config" ]]; then
  printf 'Missing %s; cannot run live SSH regression matrix.\n' "$config" >&2
  exit 2
fi

branch="$(git branch --show-current 2>/dev/null || true)"
head="$(git rev-parse --short HEAD)"
if [[ -z "$label" ]]; then
  label="${branch:-detached}-$head"
fi

log_dir=".local/logs"
mkdir -p "$log_dir"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
summary="$log_dir/live-regression-$(safe_token "$label")-$stamp.summary"

{
  printf 'label=%s\n' "$label"
  printf 'worktree=%s\n' "$repo_root"
  printf 'branch=%s\n' "${branch:-detached}"
  printf 'head=%s\n' "$head"
  printf 'destination=%s\n' "$destination"
  printf 'config=%s\n' "$config"
  printf 'startedAt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'cases=%s\n' "${cases[*]}"
} >"$summary"

overall_status=0
for case_name in "${cases[@]}"; do
  test_id="$(case_test_id "$case_name")"
  case_log="$log_dir/live-regression-$(safe_token "$label")-$stamp-$(safe_token "$case_name").log"
  printf '\n== Remux live regression case: %s ==\n' "$case_name" | tee -a "$summary"
  printf 'test=%s\nlog=%s\n' "$test_id" "$case_log" | tee -a "$summary"

  case_start="$(date +%s)"
  set +e
  scripts/remux_live_ui_test_with_cleanup.sh \
    --config "$config" \
    --destination "$destination" \
    --only-testing "$test_id" 2>&1 | tee "$case_log"
  status="${PIPESTATUS[0]}"
  set -e
  case_end="$(date +%s)"
  elapsed="$((case_end - case_start))"

  printf 'case=%s status=%s elapsed_s=%s\n' "$case_name" "$status" "$elapsed" | tee -a "$summary"
  if [[ "$status" -ne 0 ]]; then
    overall_status="$status"
    if [[ "$continue_on_failure" -eq 0 ]]; then
      break
    fi
  fi
done

{
  printf 'finishedAt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'overallStatus=%s\n' "$overall_status"
} >>"$summary"

printf '\nsummary=%s\n' "$summary"
exit "$overall_status"
