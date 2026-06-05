#!/bin/bash
# Reset Relay Runner privacy grants and first-run permission state.
#
# Default mode is a dry run. Use --execute to actually reset macOS TCC entries
# and Relay Runner's own onboarding sentinels.

set -euo pipefail

APP_BUNDLE_ID="${RELAY_RUNNER_BUNDLE_ID:-com.relayrunner.app}"
DEFAULTS_DOMAIN="com.relayrunner.app"
APP_SUPPORT_DIR="$HOME/Library/Application Support/relay-runner"

DRY_RUN=1
INCLUDE_PARENT_APPS=0
RESET_LOCAL_STATE=1
CUSTOM_BUNDLE_ID=0

RELAY_TCC_SERVICES=(
    Microphone
    Accessibility
    ListenEvent
    ScreenCapture
    AppleEvents
)

PARENT_TCC_SERVICES=(
    Accessibility
    ScreenCapture
)

ONBOARDING_FLAGS=(
    "$APP_SUPPORT_DIR/.onboarded"
    "$APP_SUPPORT_DIR/.onboarding-started"
    "$APP_SUPPORT_DIR/.session-run"
    "$APP_SUPPORT_DIR/.agent-choice-v1"
)

DEFAULT_KEYS=(
    "com.relayrunner.onboardedParents"
    "com.relayrunner.lastKnownPermission.microphone"
    "com.relayrunner.lastKnownPermission.accessibility"
    "com.relayrunner.lastKnownPermission.inputMonitoring"
    "com.relayrunner.lastKnownPermission.screenRecording"
    "com.relayrunner.onboarding.resume.step"
    "com.relayrunner.onboarding.resume.provider"
    "com.relayrunner.onboarding.resume.parentPermissionsReviewed"
)

PARENT_APP_PATHS=(
    "/System/Applications/Utilities/Terminal.app"
    "/Applications/Utilities/Terminal.app"
    "/Applications/Codex.app"
    "/Applications/Claude.app"
    "/Applications/Warp.app"
    "/Applications/iTerm.app"
    "/Applications/iTerm2.app"
    "/Applications/Visual Studio Code.app"
    "/Applications/Cursor.app"
    "/Applications/Ghostty.app"
    "/Applications/kitty.app"
    "/Applications/Alacritty.app"
    "/Applications/WezTerm.app"
)

usage() {
    cat <<'EOF'
Usage: scripts/reset-relay-permissions.sh [options]

Options:
  --dry-run                 Print what would be reset. This is the default.
  --execute                 Actually reset TCC entries and local state.
  --bundle-id ID            Reset this Relay Runner bundle ID instead of auto-detected/default.
  --include-parent-apps     Also reset Accessibility and Screen Recording for known parent apps
                            such as Terminal, Codex, Claude, Warp, iTerm, VS Code, and Cursor.
  --no-local-state          Leave Relay Runner onboarding/defaults state intact.
  -h, --help                Show this help.

Environment:
  RELAY_RUNNER_BUNDLE_ID    Default bundle ID override when --bundle-id is not provided.

Notes:
  This intentionally avoids `tccutil reset All`. It resets only the services
  Relay Runner uses, and it does not delete config.toml, models, orchestrator
  run history, or worktrees under Application Support.
EOF
}

print_cmd() {
    printf '  '
    local arg
    for arg in "$@"; do
        printf '%q ' "$arg"
    done
    printf '\n'
}

run_cmd() {
    if [ "$DRY_RUN" -eq 1 ]; then
        print_cmd "$@"
        return 0
    fi

    print_cmd "$@"
    if "$@"; then
        return 0
    else
        local status=$?
        printf '    warning: command failed with exit %s\n' "$status" >&2
        return 0
    fi
}

bundle_id_for_app() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"
    if [ ! -f "$plist" ]; then
        return 1
    fi
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null
}

detect_relay_bundle_id() {
    if [ "$CUSTOM_BUNDLE_ID" -eq 1 ]; then
        return 0
    fi

    local installed_app="/Applications/Relay Runner.app"
    local detected=""
    if [ -d "$installed_app" ]; then
        detected="$(bundle_id_for_app "$installed_app" || true)"
    fi
    if [ -n "$detected" ]; then
        APP_BUNDLE_ID="$detected"
    fi
}

reset_tcc_for_bundle() {
    local label="$1"
    local bundle_id="$2"
    shift 2

    printf '\n%s (%s):\n' "$label" "$bundle_id"
    local service
    for service in "$@"; do
        run_cmd /usr/bin/tccutil reset "$service" "$bundle_id"
    done
}

delete_default_key() {
    local key="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        print_cmd /usr/bin/defaults delete "$DEFAULTS_DOMAIN" "$key"
        return 0
    fi

    print_cmd /usr/bin/defaults delete "$DEFAULTS_DOMAIN" "$key"
    /usr/bin/defaults delete "$DEFAULTS_DOMAIN" "$key" >/dev/null 2>&1 || true
}

reset_local_state() {
    printf '\nRelay Runner onboarding state:\n'
    local path
    for path in "${ONBOARDING_FLAGS[@]}"; do
        run_cmd /bin/rm -f "$path"
    done

    printf '\nRelay Runner permission defaults:\n'
    local key
    for key in "${DEFAULT_KEYS[@]}"; do
        delete_default_key "$key"
    done
}

detect_parent_bundle_ids() {
    PARENT_BUNDLE_IDS=()
    local seen="|"

    local app_path
    local bundle_id
    for app_path in "${PARENT_APP_PATHS[@]}"; do
        if [ ! -d "$app_path" ]; then
            continue
        fi
        bundle_id="$(bundle_id_for_app "$app_path" || true)"
        if [ -n "$bundle_id" ]; then
            case "$seen" in
                *"|$bundle_id|"*)
                    ;;
                *)
                    PARENT_BUNDLE_IDS+=("$bundle_id")
                    seen="$seen$bundle_id|"
                    ;;
            esac
        fi
    done
}

warn_if_running() {
    if pgrep -x 'relay-runner' >/dev/null 2>&1; then
        printf 'warning: Relay Runner appears to be running. Quit and relaunch it after executing this reset.\n\n' >&2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --execute)
            DRY_RUN=0
            ;;
        --bundle-id)
            if [ "$#" -lt 2 ]; then
                printf 'error: --bundle-id requires a value\n' >&2
                exit 2
            fi
            APP_BUNDLE_ID="$2"
            CUSTOM_BUNDLE_ID=1
            shift
            ;;
        --include-parent-apps)
            INCLUDE_PARENT_APPS=1
            ;;
        --no-local-state)
            RESET_LOCAL_STATE=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'error: unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

detect_relay_bundle_id

if [ "$INCLUDE_PARENT_APPS" -eq 1 ]; then
    detect_parent_bundle_ids
else
    PARENT_BUNDLE_IDS=()
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf 'Mode: dry run. Add --execute to make changes.\n'
else
    printf 'Mode: execute.\n'
fi
printf 'Relay Runner bundle ID: %s\n' "$APP_BUNDLE_ID"
printf 'Local onboarding state: '
if [ "$RESET_LOCAL_STATE" -eq 1 ]; then
    printf 'reset\n'
else
    printf 'preserve\n'
fi
printf 'Parent app permissions: '
if [ "$INCLUDE_PARENT_APPS" -eq 1 ]; then
    printf 'reset for detected parent apps\n'
else
    printf 'preserve\n'
fi
printf '\n'

warn_if_running

reset_tcc_for_bundle "Relay Runner TCC entries" "$APP_BUNDLE_ID" "${RELAY_TCC_SERVICES[@]}"

if [ "$RESET_LOCAL_STATE" -eq 1 ]; then
    reset_local_state
fi

if [ "$INCLUDE_PARENT_APPS" -eq 1 ]; then
    if [ "${#PARENT_BUNDLE_IDS[@]}" -eq 0 ]; then
        printf '\nNo known parent apps were detected under /Applications.\n'
    else
        local_parent_id=""
        for local_parent_id in "${PARENT_BUNDLE_IDS[@]}"; do
            reset_tcc_for_bundle "Parent app TCC entries" "$local_parent_id" "${PARENT_TCC_SERVICES[@]}"
        done
    fi
fi

printf '\nDone. For a clean walkthrough, quit Relay Runner, run this script with --execute, then launch Relay Runner again.\n'
