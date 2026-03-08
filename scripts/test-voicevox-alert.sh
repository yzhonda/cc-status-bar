#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOICEVOX_SCRIPT="$ROOT_DIR/scripts/voicevox-alert.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ccsb-voicevox-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file_contains() {
  local file_path="$1"
  local expected="$2"

  if ! grep -Fq "$expected" "$file_path"; then
    printf 'Expected to find "%s" in %s\n' "$expected" "$file_path" >&2
    printf '--- %s ---\n' "$file_path" >&2
    cat "$file_path" >&2 || true
    fail "missing expected content"
  fi
}

assert_file_empty() {
  local file_path="$1"

  if [ -s "$file_path" ]; then
    printf 'Expected %s to be empty\n' "$file_path" >&2
    printf '--- %s ---\n' "$file_path" >&2
    cat "$file_path" >&2 || true
    fail "file not empty"
  fi
}

setup_stubs() {
  local stub_dir="$1"
  mkdir -p "$stub_dir"

  cat > "$stub_dir/curl" <<'EOF'
#!/bin/bash
set -euo pipefail

log_file="${VOICEVOX_TEST_CURL_LOG:?}"
url=""
output_path=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output)
      output_path="$2"
      shift 2
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      printf '%s\n' "$1" >> "$log_file"
      shift
      ;;
  esac
done

printf 'URL=%s\n' "$url" >> "$log_file"
printf 'OUTPUT=%s\n' "$output_path" >> "$log_file"

case "$url" in
  */audio_query)
    printf '{"accent_phrases":[],"speedScale":1.0}\n' > "$output_path"
    ;;
  */synthesis*)
    printf 'RIFFTEST' > "$output_path"
    ;;
  *)
    printf 'Unexpected curl URL: %s\n' "$url" >&2
    exit 1
    ;;
esac
EOF

  cat > "$stub_dir/afplay" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${VOICEVOX_TEST_AFPLAY_LOG:?}"
EOF

  chmod +x "$stub_dir/curl" "$stub_dir/afplay"
}

run_helper() {
  local project_cwd="$1"
  local waiting_reason="$2"
  local app_support_dir="$3"
  local debug_log="$4"
  local curl_log="$5"
  local afplay_log="$6"
  local stub_dir="$7"

  PATH="$stub_dir:$PATH" \
  CCSB_CWD="$project_cwd" \
  CCSB_WAITING_REASON="$waiting_reason" \
  CCSB_APP_SUPPORT_DIR="$app_support_dir" \
  CCSB_VOICEVOX_DEBUG_LOG="$debug_log" \
  VOICEVOX_TEST_CURL_LOG="$curl_log" \
  VOICEVOX_TEST_AFPLAY_LOG="$afplay_log" \
  "$VOICEVOX_SCRIPT"
}

test_searches_parents_and_prefers_reason_specific_template() {
  local fixture_dir="$tmp_dir/parent-search"
  local project_root="$fixture_dir/project"
  local nested_dir="$project_root/subdir/worktree"
  local app_support_dir="$fixture_dir/app-support"
  local stub_dir="$fixture_dir/stubs"
  local debug_log="$fixture_dir/debug.log"
  local curl_log="$fixture_dir/curl.log"
  local afplay_log="$fixture_dir/afplay.log"

  mkdir -p "$nested_dir" "$app_support_dir"
  setup_stubs "$stub_dir"

  cat > "$project_root/.cc-status-bar.voice.json" <<'EOF'
{
  "version": 1,
  "speaker": 7,
  "templates": {
    "default": ["default-template"],
    "permission_prompt": ["permission-template"],
    "stop": ["stop-template"]
  }
}
EOF

  cat > "$app_support_dir/voicevox-runtime.json" <<'EOF'
{
  "engine_base_url": "http://127.0.0.1:50021",
  "default_speaker": 42
}
EOF

  : > "$debug_log"
  : > "$curl_log"
  : > "$afplay_log"

  run_helper "$nested_dir" "permission_prompt" "$app_support_dir" "$debug_log" "$curl_log" "$afplay_log" "$stub_dir"

  assert_file_contains "$debug_log" "voice_file=$project_root/.cc-status-bar.voice.json"
  assert_file_contains "$debug_log" "speaker=7"
  assert_file_contains "$debug_log" "text=permission-template"
  assert_file_contains "$curl_log" "speaker=7"
  assert_file_contains "$curl_log" "text=permission-template"
}

test_uses_runtime_default_speaker_when_project_file_does_not_define_one() {
  local fixture_dir="$tmp_dir/default-speaker"
  local project_root="$fixture_dir/project"
  local app_support_dir="$fixture_dir/app-support"
  local stub_dir="$fixture_dir/stubs"
  local debug_log="$fixture_dir/debug.log"
  local curl_log="$fixture_dir/curl.log"
  local afplay_log="$fixture_dir/afplay.log"

  mkdir -p "$project_root" "$app_support_dir"
  setup_stubs "$stub_dir"

  cat > "$project_root/.cc-status-bar.voice.json" <<'EOF'
{
  "version": 1,
  "templates": {
    "default": ["default-template"]
  }
}
EOF

  cat > "$app_support_dir/voicevox-runtime.json" <<'EOF'
{
  "engine_base_url": "http://127.0.0.1:50021",
  "default_speaker": 42
}
EOF

  : > "$debug_log"
  : > "$curl_log"
  : > "$afplay_log"

  run_helper "$project_root" "unknown" "$app_support_dir" "$debug_log" "$curl_log" "$afplay_log" "$stub_dir"

  assert_file_contains "$debug_log" "speaker=42"
  assert_file_contains "$debug_log" "text=default-template"
  assert_file_contains "$curl_log" "speaker=42"
}

test_missing_project_file_falls_back_without_calling_voicevox() {
  local fixture_dir="$tmp_dir/missing-project-file"
  local project_root="$fixture_dir/project"
  local app_support_dir="$fixture_dir/app-support"
  local stub_dir="$fixture_dir/stubs"
  local debug_log="$fixture_dir/debug.log"
  local curl_log="$fixture_dir/curl.log"
  local afplay_log="$fixture_dir/afplay.log"

  mkdir -p "$project_root" "$app_support_dir"
  setup_stubs "$stub_dir"

  : > "$debug_log"
  : > "$curl_log"
  : > "$afplay_log"

  run_helper "$project_root" "stop" "$app_support_dir" "$debug_log" "$curl_log" "$afplay_log" "$stub_dir"

  assert_file_contains "$debug_log" "voice_file="
  assert_file_contains "$afplay_log" "/System/Library/Sounds/Ping.aiff"
  assert_file_empty "$curl_log"
}

test_invalid_json_falls_back_to_ping() {
  local fixture_dir="$tmp_dir/invalid-json"
  local project_root="$fixture_dir/project"
  local app_support_dir="$fixture_dir/app-support"
  local stub_dir="$fixture_dir/stubs"
  local debug_log="$fixture_dir/debug.log"
  local curl_log="$fixture_dir/curl.log"
  local afplay_log="$fixture_dir/afplay.log"

  mkdir -p "$project_root" "$app_support_dir"
  setup_stubs "$stub_dir"

  cat > "$project_root/.cc-status-bar.voice.json" <<'EOF'
{ invalid json
EOF

  : > "$debug_log"
  : > "$curl_log"
  : > "$afplay_log"

  run_helper "$project_root" "stop" "$app_support_dir" "$debug_log" "$curl_log" "$afplay_log" "$stub_dir"

  assert_file_contains "$afplay_log" "/System/Library/Sounds/Ping.aiff"
}

test_searches_parents_and_prefers_reason_specific_template
test_uses_runtime_default_speaker_when_project_file_does_not_define_one
test_missing_project_file_falls_back_without_calling_voicevox
test_invalid_json_falls_back_to_ping

printf 'VOICEVOX helper tests passed\n'
