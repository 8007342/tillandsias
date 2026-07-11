# Research: Preventing Silent Failures in Long-Running Background Tasks

## Context
When a user launches Tillandsias for the first time, or after an update, the macOS tray app auto-boots the VM and initiates `tillandsias --init` inside the guest. This process builds multiple container images (e.g. `git`, `proxy`, `vault`, `inference`) which can take several minutes. 

During this time, the tray UI simply displays `🏁 Setting up...` based on the presence of items in `TrayState::active_builds`. 

## The Problem (Silent Failures)
If the backend process encounters a network restriction or an offline environment, a known issue (`build-image-vault-hang-offline-2026-07-06.md`) bounds the `podman build` command to an 1800s (30 minute) timeout *per image*.
Because the tray UI has no visibility into the progress or the timeout, the user is left staring at `🏁 Setting up...` for up to 2 hours without any indication that the process is effectively deadlocked.

This creates a "silent failure" from the user's perspective. The underlying process might not have officially panicked, but the system is degraded and the user has zero feedback.

## Root Cause Analysis
1. **Opaque Backend Delegation**: The tray relies on a fire-and-forget execution (or a simple control wire invocation) that only reports `Started`, `Completed`, or `Failed`. It does not report `Stalled`, `Retrying`, or granular progress (e.g., "Step 2 of 15").
2. **Lack of Watchdog**: The tray state machine does not enforce its own time-to-live (TTL) on `InProgress` states. If a build is `InProgress` for 30 minutes, the UI blindly trusts it.
3. **Missing Diagnostics**: Users cannot inspect the background process (since stdout/stderr are routed to `/dev/null` on macOS GUI apps, and the VM logs are internal).

## Requirements for a Robust UX
To prevent future silent failures across *any* long-running operation, we must establish a generic framework:
1. **Heartbeats/Progress Streams**: Long-running operations must emit continuous progress.
2. **UI Watchdogs**: The UI must downgrade the state to `Stalled` or `Warning` if an operation exceeds a normal duration threshold, alerting the user before the hard-timeout occurs.
3. **Actionable Recovery**: The user must be given a way to abort, retry, or view the logs when a stall is detected.
