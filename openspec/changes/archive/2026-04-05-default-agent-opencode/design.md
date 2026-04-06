## Context
SelectedAgent enum has OpenCode and Claude variants. Default impl returns Claude.

## Goals / Non-Goals
**Goals:** Change default to OpenCode
**Non-Goals:** Changing any other agent behavior

## Decisions
- Single line change: `Self::Claude` → `Self::OpenCode`
- Existing user configs with `selected = "claude"` are unaffected (explicit selection persists)
