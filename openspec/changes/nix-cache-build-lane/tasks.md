# Tasks: nix-cache-build-lane

Created 2026-08-28 during the 873-b1nx/790-6n2k reconciliation (this change
shipped with design.md + proposal.md only; the task list is reconstructed
from the design's "What remains" so completion is checkable).

## Linux lane (per-host)

- [x] One builder lineage: `images/builder/Containerfile` (distro nix,
      curl+jq for the prefetch fallback, bash entrypoint); `nix/builder/`
      deleted; wrapper and e2e repointed.
- [x] Runtime-injected cache identity: baked host pubkey and
      `https://nix-cache:5000` removed from `images/builder/nix.conf`;
      upstream substituter kept (degrade-to-cold).
- [x] Lane selection renamed to `TILLANDSIAS_BUILD_LANE=container`
      (design.md wins over the wrapper's `NIX_BUILD_LANE`); byte-identical
      pass-through while unset; lane var rides the `TILLANDSIAS_*`
      forwarding loop.
- [x] Per-host substituter wiring in `with-nix-builder.sh`:
      `nix-cache-service.sh substituter-args` consulted; empty = cold, no
      flags; `--ssl-cert-file` value rewritten to the read-only in-container
      mount at `/run/tillandsias/ca-bundle.crt`.
- [x] Store topology (A): `/nix` on named volume `tillandsias-builder-nix`;
      chroot store rw at `/host-store`; post-build in-container
      `nix copy --to /host-store --no-check-sigs` (`ok:nix-populate:copied=<n>`)
      plus host-side `nix-toolbox.sh pin`.
- [x] `nix-push-cache.sh` re-cut to the local mechanism (host-store →
      chroot-store copy + pin); the https push against serve-only harmonia
      removed.
- [x] Prefetch (`nix-build-container.sh`) kept as explicit fallback behind
      `TILLANDSIAS_NIX_PREFETCH=1`; in-container path fixed
      (`/work/scripts/...`).
- [x] `litmus:nix-container-lane-shape` authored (spec dev-build): wrappers
      parse + sourced, unset-lane byte-identical + options untouched, loud
      non-nix refusal, nesting guard names itself, one lineage, substituter
      wiring present. (Binding row applied by the orchestrator.)
- [x] `litmus:nix-builder-shape` re-cut for nixpkgs-26.05
      (`buildLayeredImage` → `contents`; named FAIL lines; negative control
      run red per 921-vtf4 EC2) with the spec requirement re-worded.

## Remaining

- [ ] End-to-end verdict on this host: `scripts/check-nix-builder-e2e.sh`
      against a running cache (blocked at reconciliation time — see the
      ledger event on 790-6n2k for the exact state).
- [ ] Store-topology measurement: (A) copy-based populate vs (B)
      `store = /host-store` structural sharing, on the 96 s shape.
- [ ] WSL2 lane measurement or recorded deferral with cost (exit
      criterion 4).
- [ ] macOS (VFR guest) lane measurement or recorded deferral with cost
      (exit criterion 4).
- [ ] Shared cross-host cache design — blocked on operator decision; cache
      stays per-host until then (operator 2026-08-28).
