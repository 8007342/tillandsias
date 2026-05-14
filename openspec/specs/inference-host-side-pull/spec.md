<!-- @tombstone superseded:inference-container+zen-default-with-ollama-analysis-pool -->
<!-- @trace spec:inference-host-side-pull -->
# inference-host-side-pull Specification

## Status

obsolete

## Purpose

Historical wrapper retained for traceability only. The live inference
startup and model-pull contract now lives in `inference-container` and
`zen-default-with-ollama-analysis-pool`, with runtime behavior owned by
the inference image entrypoint.

## Superseded By

- `openspec/specs/inference-container/spec.md`
- `openspec/specs/zen-default-with-ollama-analysis-pool/spec.md`

## Notes

- The old host-side pull path has been retired in favor of the current
  inference entrypoint behavior.
- Keep the trace links readable, but do not add new requirements here.
