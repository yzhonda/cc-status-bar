# VOICEVOX Template Contract

This file defines the project-local speech source-of-truth used by
`scripts/voicevox-alert.sh`.

## File Name

```text
<project-root>/.cc-status-bar.voice.json
```

The helper starts from `CCSB_CWD` and walks upward toward `/`.
The first matching file wins.

## Schema

```json
{
  "version": 1,
  "speaker": 3,
  "templates": {
    "default": [
      "cc-status-bar is waiting."
    ],
    "stop": [
      "cc-status-bar stopped for input."
    ],
    "permission_prompt": [
      "cc-status-bar needs permission."
    ]
  }
}
```

## Fields

- `version`
  - Required.
  - Current value is `1`.
- `speaker`
  - Optional.
  - VOICEVOX style id to use for this project.
  - If omitted, the helper uses `default_speaker` from
    `~/Library/Application Support/CCStatusBar/voicevox-runtime.json`.
- `templates.default`
  - Required.
  - Non-empty array of literal text strings.
- `templates.stop`
  - Optional.
  - Used only when `CCSB_WAITING_REASON=stop`.
- `templates.permission_prompt`
  - Optional.
  - Used only when `CCSB_WAITING_REASON=permission_prompt`.

## Selection Rules

1. If `CCSB_WAITING_REASON=permission_prompt` and
   `templates.permission_prompt` exists and is non-empty, pick a random entry
   from that array.
2. Else if `CCSB_WAITING_REASON=stop` and `templates.stop` exists and is
   non-empty, pick a random entry from that array.
3. Else pick a random entry from `templates.default`.
4. If no valid candidate exists, play the Ping fallback sound.

## Notes

- Templates are treated as literal text in v1.
- No placeholder expansion happens in v1.
- Nearest parent file wins, so nested worktrees can override speech locally.
- Missing file or invalid JSON does not break alerts; the helper falls back to
  `Ping.aiff`.
