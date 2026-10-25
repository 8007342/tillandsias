## ADDED Requirements

### Requirement: Forge storage layers are explicit

A forge SHALL expose four storage layers: L0 ram (tmpfs source workspace and
small temp), L1 per-forge disk scratch, L2 reusable per-project cache, L3
durable source of truth (git remote). Each layer SHALL have a declared
mount, size rule, lifetime and corruption rule.

#### Scenario: L1 scratch is truly ephemeral

- **WHEN** a forge is removed
- **THEN** its L1 scratch volume is deleted
- **AND** a new forge of the same lane starts with an empty L1

#### Scenario: TMPDIR points at L1

- **WHEN** an agent shell starts in a forge
- **THEN** `TMPDIR` is under the L1 scratch mount, not under L0 and not under L2

### Requirement: Downloads never land on the ram layer

Toolchain and package-manager download and install paths (Go, Ruby gems,
Homebrew cache, pub, npm/pnpm, cargo registry, models) SHALL resolve to L2,
and transient tool downloads to L1. None SHALL resolve to a tmpfs.

#### Scenario: Go and Ruby paths

- **WHEN** an agent shell starts in a forge
- **THEN** `GOPATH`, `GOMODCACHE`, `GEM_HOME` and `HOMEBREW_CACHE` are under the L2 cache mount

### Requirement: Reusable cache is wiped, never repaired

L2 SHALL carry a version stamp. When the stamp is missing, mismatched, or a
corruption probe fails, the affected L2 subtree SHALL be wiped and recreated
empty; no repair SHALL be attempted.

#### Scenario: corrupted stamp

- **GIVEN** an L2 subtree whose stamp is unreadable
- **WHEN** the forge starts
- **THEN** the subtree is recreated empty and the event is logged once

### Requirement: Swap backs the ram layer

The host SHALL have an active disk-backed swap device at least the sum of
the L0 caps of running forges (floor 8 GiB). zram alone SHALL NOT satisfy
this. When unmet, the tray SHALL show a persistent warning naming the
remedy `tillandsias --swap on`; forge launch SHALL NOT be blocked.

#### Scenario: zram only

- **GIVEN** `/proc/swaps` lists only a zram device
- **WHEN** the tray computes its status
- **THEN** a swap warning status line is shown until disk swap is active
