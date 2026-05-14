# Methodology Events

Use this directory for compact, idempotent refinement records that help future agents resume work without conversational memory.

Guidelines:
- Write an immediate bootstrap note before edits begin so the next agent sees live intent, not just the end state.
- Write one file per meaningful refinement event.
- Prefer stable names such as `2026-05-14-browser-launcher-refinement.yaml`.
- Include `task_id`, `branch`, `status`, `progress`, `next_action`, `blockers`, and `checkpoint_commit` when available.
- Refresh the same task note after each meaningful substep or blocker instead of waiting for completion.
- Keep entries cold-start readable and safe to replay.
- If a task is ambiguous, record the question and a recommended default instead of stalling in chat.
