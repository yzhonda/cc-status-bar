#!/bin/bash
set -euo pipefail

VOICE_FILE_NAME=".cc-status-bar.voice.json"
APP_SUPPORT_DIR="${CCSB_APP_SUPPORT_DIR:-$HOME/Library/Application Support/CCStatusBar}"
RUNTIME_CONFIG="${CCSB_VOICEVOX_RUNTIME_CONFIG:-$APP_SUPPORT_DIR/voicevox-runtime.json}"
DEFAULT_BASE_URL="${CCSB_VOICEVOX_ENGINE_BASE_URL:-http://127.0.0.1:50021}"
FALLBACK_SOUND="${CCSB_VOICEVOX_FALLBACK_SOUND:-/System/Library/Sounds/Ping.aiff}"
DEBUG_LOG="${CCSB_VOICEVOX_DEBUG_LOG:-}"

tmp_dir=""

usage() {
  cat <<'EOF'
Usage: voicevox-alert.sh

Reads CCSB_* alert context, resolves the nearest .cc-status-bar.voice.json from
CCSB_CWD upward, synthesizes speech with VOICEVOX ENGINE, and falls back to
/System/Library/Sounds/Ping.aiff when speech is unavailable.
EOF
}

cleanup() {
  if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
}

trap cleanup EXIT

debug_log() {
  if [ -n "$DEBUG_LOG" ]; then
    printf '%s\n' "$1" >> "$DEBUG_LOG"
  fi
}

play_fallback_sound() {
  debug_log "fallback=1"
  if command -v afplay >/dev/null 2>&1 && [ -f "$FALLBACK_SOUND" ]; then
    afplay "$FALLBACK_SOUND" >/dev/null 2>&1 || true
    return
  fi

  printf '\a' >&2 || true
}

require_tool() {
  command -v "$1" >/dev/null 2>&1
}

json_value_or_empty() {
  local file_path="$1"
  local filter="$2"
  jq -r "$filter // empty" "$file_path" 2>/dev/null || true
}

find_voice_file() {
  local start_path="$1"
  local current_dir

  if [ -z "$start_path" ]; then
    return 1
  fi

  if [ -d "$start_path" ]; then
    current_dir="$start_path"
  else
    current_dir="$(dirname "$start_path")"
  fi

  while true; do
    if [ -f "$current_dir/$VOICE_FILE_NAME" ]; then
      printf '%s\n' "$current_dir/$VOICE_FILE_NAME"
      return 0
    fi

    if [ "$current_dir" = "/" ]; then
      break
    fi

    current_dir="$(dirname "$current_dir")"
  done

  return 1
}

template_count() {
  local voice_file="$1"
  local waiting_reason="$2"

  jq -r --arg reason "$waiting_reason" '
    def candidates:
      if $reason == "permission_prompt"
         and (.templates.permission_prompt? | type == "array")
         and ((.templates.permission_prompt | length) > 0)
      then
        .templates.permission_prompt
      elif $reason == "stop"
         and (.templates.stop? | type == "array")
         and ((.templates.stop | length) > 0)
      then
        .templates.stop
      else
        .templates.default
      end;

    if (.templates.default? | type != "array") or ((.templates.default | length) == 0) then
      0
    else
      (candidates | length)
    end
  ' "$voice_file" 2>/dev/null || printf '0\n'
}

template_text() {
  local voice_file="$1"
  local waiting_reason="$2"
  local template_index="$3"

  jq -r --arg reason "$waiting_reason" --argjson index "$template_index" '
    def candidates:
      if $reason == "permission_prompt"
         and (.templates.permission_prompt? | type == "array")
         and ((.templates.permission_prompt | length) > 0)
      then
        .templates.permission_prompt
      elif $reason == "stop"
         and (.templates.stop? | type == "array")
         and ((.templates.stop | length) > 0)
      then
        .templates.stop
      else
        .templates.default
      end;

    candidates[$index] // empty
  ' "$voice_file" 2>/dev/null || true
}

run_voicevox() {
  local base_url="$1"
  local speaker="$2"
  local text="$3"

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ccsb-voicevox.XXXXXX")"
  local query_json="$tmp_dir/audio-query.json"
  local output_wav="$tmp_dir/output.wav"

  if ! curl --silent --show-error --fail --max-time 15 \
    --request POST \
    --get \
    --data-urlencode "speaker=$speaker" \
    --data-urlencode "text=$text" \
    "$base_url/audio_query" \
    --output "$query_json"; then
    return 1
  fi

  if ! curl --silent --show-error --fail --max-time 30 \
    --request POST \
    --header 'Content-Type: application/json' \
    "$base_url/synthesis?speaker=$speaker" \
    --data-binary "@$query_json" \
    --output "$output_wav"; then
    return 1
  fi

  if command -v afplay >/dev/null 2>&1; then
    afplay "$output_wav" >/dev/null 2>&1
    return $?
  fi

  return 1
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

  if ! require_tool jq || ! require_tool curl; then
    play_fallback_sound
    exit 0
  fi

  local working_dir="${CCSB_CWD:-$PWD}"
  local waiting_reason="${CCSB_WAITING_REASON:-unknown}"
  local base_url="$DEFAULT_BASE_URL"
  local default_speaker=""

  if [ -f "$RUNTIME_CONFIG" ]; then
    local config_base_url
    config_base_url="$(json_value_or_empty "$RUNTIME_CONFIG" '.engine_base_url')"
    if [ -n "$config_base_url" ]; then
      base_url="$config_base_url"
    fi

    default_speaker="$(json_value_or_empty "$RUNTIME_CONFIG" '.default_speaker')"
  fi

  local voice_file=""
  if ! voice_file="$(find_voice_file "$working_dir")"; then
    debug_log "voice_file="
    play_fallback_sound
    exit 0
  fi

  debug_log "voice_file=$voice_file"

  local count
  count="$(template_count "$voice_file" "$waiting_reason")"
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -eq 0 ]; then
    play_fallback_sound
    exit 0
  fi

  local index=$((RANDOM % count))
  local text
  text="$(template_text "$voice_file" "$waiting_reason" "$index")"
  if [ -z "$text" ]; then
    play_fallback_sound
    exit 0
  fi

  local speaker
  speaker="$(json_value_or_empty "$voice_file" '.speaker')"
  if [ -z "$speaker" ]; then
    speaker="$default_speaker"
  fi

  if [ -z "$speaker" ]; then
    play_fallback_sound
    exit 0
  fi

  debug_log "base_url=$base_url"
  debug_log "speaker=$speaker"
  debug_log "text=$text"
  debug_log "reason=$waiting_reason"

  if ! run_voicevox "$base_url" "$speaker" "$text"; then
    play_fallback_sound
    exit 0
  fi
}

main "$@"
