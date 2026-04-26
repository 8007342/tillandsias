## ADDED Requirements

### Requirement: Status chip is additive across subsystem completions

The tray menu's status chip SHALL be a single line whose emoji prefix accumulates as each infrastructure subsystem comes online. Concretely:

1. The line begins with the constant ASCII emoji `✅` (white-heavy-check).
2. After `✅`, an emoji per completed subsystem appears in stable, deterministic order:
   - `🧭` (compass) — browser runtime
   - `🕸️` (spider web) — enclave network
   - `🛡️` (shield) — proxy
   - `🧠` (brain) — inference
   - `🔀` (shuffle) — router
   - `🪞` (mirror) — git mirror
   - `🔨` (hammer) — forge image
3. The tail of the line is the current action text:
   - While a build is in progress: `Building <subsystem-friendly-name> …`
   - For 2 seconds after a build completes: `<subsystem-friendly-name> OK`
4. On `Stage::NetIssue`, ` · GitHub unreachable — using cached list` is appended to the tail.

A subsystem's emoji appears once per build. Re-builds of the same subsystem (e.g., proxy crashed and was restarted) do NOT add a duplicate emoji to the prefix; the dedup is by sort order.

#### Scenario: Cold start chip — verifying baseline
- **WHEN** the tray launches AND no build has completed AND no build is in progress AND `Stage::Booting`
- **THEN** the chip text SHALL be `✅ Verifying environment …` (the localized value of `menu.status.verifying_environment`)

#### Scenario: First completion adds emoji + flash
- **WHEN** the browser runtime build completes AND no other build is in progress
- **THEN** the chip text SHALL be `✅🧭 Browser runtime OK` for 2 seconds
- **AND** after 2 seconds the chip SHALL be removed from the menu (no in-progress, no flash window)

#### Scenario: Multiple completions accumulate
- **WHEN** browser runtime + enclave + proxy have all completed AND inference is currently building
- **THEN** the chip text SHALL be `✅🧭🕸️🛡️ Building Inference Engine …`
- **AND** the emojis SHALL appear in the deterministic order above (compass → web → shield), regardless of completion timing

#### Scenario: NetIssue suffix joins same chip line
- **WHEN** `Stage::NetIssue` AND browser + enclave + proxy completed AND no in-progress builds AND a recent completion is within the 2 s flash window
- **THEN** the chip SHALL contain both the per-subsystem emoji prefix AND the GitHub-unreachable suffix on a single line, separated by ` · `

### Requirement: Unhealthy stage collapses menu to single status item

When `current_stage` detects a failed build with no concurrent retry in flight, it SHALL return `Stage::Unhealthy`. The menu's dynamic region SHALL collapse to a single disabled item with the localized value of `menu.unhealthy_environment` (default English: `🥀 Unhealthy environment`). The sign-in action, running-stack submenus, `🏠 ~/src ▸`, and `☁️ Cloud ▸` SHALL all be hidden in this stage.

Detail of which specific subsystem failed lives in the accountability log, NOT in the menu. The menu's job is signalling severity ("something is wrong, look at the logs"), not enumerating failures.

#### Scenario: Failed forge build → Unhealthy
- **WHEN** the forge image build returns `BuildProgressEvent::Failed` AND no retry has fired yet
- **THEN** `current_stage` SHALL return `Stage::Unhealthy`
- **AND** the menu's dynamic region SHALL contain only `🥀 Unhealthy environment`
- **AND** the static row at the bottom SHALL still contain `[separator] [signature] [Quit Tillandsias]`

#### Scenario: Retry supersedes Unhealthy
- **WHEN** an Unhealthy state transitions to a fresh `BuildProgressEvent::Started` for the same image
- **THEN** the prior `Failed` row in `state.active_builds` SHALL be cleared (per existing `event_loop.rs::handle_build_progress_event::Started` behaviour)
- **AND** `current_stage` SHALL return `Stage::Booting`
- **AND** the chip SHALL re-appear with the prior emoji prefix preserved (completed subsystems are NOT lost on Unhealthy → Booting transitions)

### Requirement: Sign-in label uses "GitHub Login" wording

The localized value of `menu.sign_in_github` SHALL be `🔑 GitHub Login` (en) / `🔑 GitHub-Anmeldung` (de) / `🔑 Iniciar sesión en GitHub` (es). The change is wording-only — the menu item ID (`tm.sign-in`) and dispatch (`MenuCommand::GitHubLogin`) are unchanged.

#### Scenario: NoAuth shows the new wording
- **WHEN** `Stage::NoAuth` AND the menu is open
- **THEN** the menu item with id `tm.sign-in` SHALL render the text `🔑 GitHub Login` (in the active locale)

## Sources of Truth

- `cheatsheets/agents/openspec.md` (DRAFT) — workflow.
- `cheatsheets/runtime/forge-container.md` (DRAFT) — runtime context this state machine projects.
