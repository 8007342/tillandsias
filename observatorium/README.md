# Observatorium Pickup Notes

Local-only v0 for the clickable-trace-index observability surface.

Launch:

```bash
./scripts/run-observatorium.sh [--recreate]
```

Current contract:
- serve the current checkout directly
- prefer the private Chromium sandbox first
- fall back to host browser launch if needed
- keep the UI minimal: dark theme, soft rounded panels, three columns for specs / code / cheatsheets

Implementation notes:
- the launcher must stay idempotent through `podman create` short-circuiting
- `--recreate` must force container replacement
- the viewer should use `cache: no-store` for local source fetches

Next useful followups:
- improve reverse-hit matching between cheatsheets and specs
- add release snapshot embedding once the fake-local prototype is stable
- keep the UI and trace index in lockstep with `clickable-trace-index`
