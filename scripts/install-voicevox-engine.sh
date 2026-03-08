#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SUPPORT_DIR="${CCSB_APP_SUPPORT_DIR:-$HOME/Library/Application Support/CCStatusBar}"
ENGINE_INSTALL_DIR="$APP_SUPPORT_DIR/voicevox-engine"
BIN_DIR="$APP_SUPPORT_DIR/bin"
RUNTIME_CONFIG="$APP_SUPPORT_DIR/voicevox-runtime.json"
ENGINE_BASE_URL="${CCSB_VOICEVOX_ENGINE_BASE_URL:-http://127.0.0.1:50021}"
LAUNCH_AGENT_LABEL="com.ccstatusbar.voicevox-engine"
LAUNCH_AGENTS_DIR="${CCSB_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENTS_DIR/$LAUNCH_AGENT_LABEL.plist"
LOG_DIR="${CCSB_VOICEVOX_LOG_DIR:-$HOME/Library/Logs/CCStatusBar}"
RELEASE_API_URL="https://api.github.com/repos/VOICEVOX/voicevox_engine/releases/latest"

tmp_dir=""

usage() {
  cat <<'EOF'
Usage: install-voicevox-engine.sh

Downloads the latest VOICEVOX ENGINE macOS arm64 .vvpp package, installs it to
~/Library/Application Support/CCStatusBar, creates a LaunchAgent on
127.0.0.1:50021, copies the helper script, and enables CCStatusBar Alert Command.

Environment overrides:
  VOICEVOX_ENGINE_ASSET_URL     Override the download URL for the .vvpp asset
  CCSB_VOICEVOX_ENGINE_BASE_URL Override the engine base URL (default: http://127.0.0.1:50021)
  CCSB_APP_SUPPORT_DIR          Override install root (for tests/custom installs)
  CCSB_LAUNCH_AGENTS_DIR        Override LaunchAgents directory
EOF
}

cleanup() {
  if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
}

trap cleanup EXIT

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$1" >&2
    exit 1
  fi
}

shell_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

detect_asset_url() {
  if [ -n "${VOICEVOX_ENGINE_ASSET_URL:-}" ]; then
    printf '%s\n' "$VOICEVOX_ENGINE_ASSET_URL"
    return 0
  fi

  local release_json="$tmp_dir/release.json"
  curl --silent --show-error --fail --location "$RELEASE_API_URL" --output "$release_json"

  jq -r '
    .assets[]
    | select(.name | test("^voicevox_engine-macos-arm64-.*\\.vvpp$"))
    | .browser_download_url
  ' "$release_json" | head -n 1
}

find_payload_root() {
  local extracted_dir="$1"

  if [ -f "$extracted_dir/engine_manifest.json" ]; then
    printf '%s\n' "$extracted_dir"
    return 0
  fi

  local manifest_path=""
  manifest_path="$(find "$extracted_dir" -type f -name engine_manifest.json -print -quit)"
  if [ -z "$manifest_path" ]; then
    return 1
  fi

  dirname "$manifest_path"
}

find_engine_executable() {
  local install_dir="$1"
  local candidate=""

  for candidate in \
    "$install_dir/run" \
    "$install_dir/vv-engine/run"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  candidate="$(find "$install_dir" -type f -name run -perm -111 -print -quit)"
  if [ -z "$candidate" ]; then
    return 1
  fi

  printf '%s\n' "$candidate"
}

write_launch_agent() {
  local executable_path="$1"
  local working_dir
  working_dir="$(dirname "$executable_path")"

  mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

  cat > "$LAUNCH_AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LAUNCH_AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$executable_path</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$working_dir</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/voicevox-engine.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/voicevox-engine.error.log</string>
</dict>
</plist>
EOF
}

restart_launch_agent() {
  local domain="gui/$UID"

  launchctl bootout "$domain" "$LAUNCH_AGENT_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "$domain" "$LAUNCH_AGENT_PLIST"
  launchctl kickstart -k "$domain/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
}

wait_for_engine() {
  local speakers_path="$1"
  local attempt=0

  while [ "$attempt" -lt 60 ]; do
    if curl --silent --show-error --fail "$ENGINE_BASE_URL/version" >/dev/null 2>&1 &&
       curl --silent --show-error --fail "$ENGINE_BASE_URL/speakers" --output "$speakers_path" >/dev/null 2>&1; then
      return 0
    fi

    attempt=$((attempt + 1))
    sleep 1
  done

  return 1
}

write_runtime_config() {
  local speakers_path="$1"
  local default_speaker=""
  default_speaker="$(jq -r 'first(.[]?.styles[]?.id) // empty' "$speakers_path")"

  if [ -z "$default_speaker" ]; then
    printf 'Failed to determine default speaker from %s\n' "$ENGINE_BASE_URL/speakers" >&2
    exit 1
  fi

  mkdir -p "$APP_SUPPORT_DIR"
  jq -n \
    --arg engine_base_url "$ENGINE_BASE_URL" \
    --argjson default_speaker "$default_speaker" \
    '{engine_base_url: $engine_base_url, default_speaker: $default_speaker}' \
    > "$RUNTIME_CONFIG"
}

install_helper_script() {
  mkdir -p "$BIN_DIR"
  install -m 755 "$SCRIPT_DIR/voicevox-alert.sh" "$BIN_DIR/voicevox-alert.sh"
}

configure_alert_command() {
  local helper_command
  helper_command="$(shell_quote "$BIN_DIR/voicevox-alert.sh")"

  defaults write com.ccstatusbar.app alertCommand -string "$helper_command"
  defaults write com.ccstatusbar.app alertsEnabled -bool true
}

main() {
  case "${1:-}" in
    "")
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac

  if [ "$(uname -m)" != "arm64" ]; then
    printf 'This installer currently supports macOS arm64 only.\n' >&2
    exit 1
  fi

  require_tool curl
  require_tool ditto
  require_tool jq
  require_tool launchctl
  require_tool defaults

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ccsb-voicevox-install.XXXXXX")"

  local asset_url=""
  asset_url="$(detect_asset_url)"
  if [ -z "$asset_url" ]; then
    printf 'Failed to resolve VOICEVOX .vvpp asset URL.\n' >&2
    exit 1
  fi

  local vvpp_path="$tmp_dir/voicevox-engine.vvpp"
  local extract_dir="$tmp_dir/extracted"
  local staged_dir="$tmp_dir/install-staged"
  local payload_root=""
  local executable_path=""
  local speakers_path="$tmp_dir/speakers.json"

  printf 'Downloading %s\n' "$asset_url"
  curl --fail --location --progress-bar "$asset_url" --output "$vvpp_path"

  mkdir -p "$extract_dir"
  ditto -x -k "$vvpp_path" "$extract_dir"

  payload_root="$(find_payload_root "$extract_dir")"
  if [ -z "$payload_root" ]; then
    printf 'Failed to locate engine_manifest.json in extracted VOICEVOX payload.\n' >&2
    exit 1
  fi

  mkdir -p "$(dirname "$ENGINE_INSTALL_DIR")"
  rm -rf "$staged_dir"
  mkdir -p "$staged_dir"
  ditto "$payload_root" "$staged_dir"

  rm -rf "$ENGINE_INSTALL_DIR"
  mv "$staged_dir" "$ENGINE_INSTALL_DIR"

  executable_path="$(find_engine_executable "$ENGINE_INSTALL_DIR")"
  if [ -z "$executable_path" ]; then
    printf 'Failed to locate VOICEVOX engine executable under %s\n' "$ENGINE_INSTALL_DIR" >&2
    exit 1
  fi

  install_helper_script
  write_launch_agent "$executable_path"
  restart_launch_agent

  if ! wait_for_engine "$speakers_path"; then
    printf 'VOICEVOX engine did not become ready at %s within 60 seconds.\n' "$ENGINE_BASE_URL" >&2
    exit 1
  fi

  write_runtime_config "$speakers_path"
  configure_alert_command

  printf 'VOICEVOX engine installed.\n'
  printf 'Engine: %s\n' "$executable_path"
  printf 'Helper: %s\n' "$BIN_DIR/voicevox-alert.sh"
  printf 'Runtime config: %s\n' "$RUNTIME_CONFIG"
}

main "$@"
