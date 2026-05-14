# Methodology Events

Use this directory for compact, idempotent refinement records that help future agents resume work without conversational memory.

Guidelines:
- Write one file per meaningful refinement event.
- Prefer stable names such as `2026-05-14-browser-launcher-refinement.yaml`.
- Include `task_id`, `branch`, `status`, `progress`, `next_action`, `blockers`, and `checkpoint_commit` when available.
- Keep entries cold-start readable and safe to replay.
- If a task is ambiguous, record the question and a recommended default instead of stalling in chat.
