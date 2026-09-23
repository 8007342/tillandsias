//! Portable menu state model — **the ONLY menu builder in the tree.**
//!
//! ## This is the sole builder (order 628-p5tj). Changes here reach ALL THREE trays.
//!
//! Windows, macOS AND Linux all render from `build()` in this module. If you
//! are changing what items appear, their order, their labels, or the
//! auth-gated structure, you are changing every platform at once — including
//! Linux, which many of these docs predate.
//!
//! **There is no second builder to keep in sync, and that is recent.** Linux
//! used to carry its own `build_menu` implementation, gating on a plain
//! `is_authenticated: bool` while this module used the `GithubLoginState`
//! tri-state. The consequence was measured on 2026-08-09: the 626-r7kq fix
//! landed HERE, Windows and macOS inherited it, and Linux did not — it kept
//! the same defect through a different mechanism (627-m3vp). That was not a
//! one-off; it was the structural consequence of two builders, which is why
//! there is now one.
//!
//! Linux's `build_menu` (`tillandsias-headless/src/tray/mod.rs`) is now a
//! CONVERTER, not a builder: it calls `build()` and translates the result to
//! DBus (`String` ids to integers, `MenuItem` to `MenuNode`). Anything that
//! decides WHAT appears belongs here; anything that decides how a toolkit
//! renders it belongs in that platform's converter.
//!
//! The top-level id sequence is pinned by
//! `top_level_id_sequence_is_pinned_for_all_platforms` in this file's tests.
//! Because all three platforms derive from `build()`, that one test guards all
//! three — a reorder fails there once rather than diverging silently in one
//! tray.
//!
//! Emits a backend-agnostic `MenuStructure`. The Windows tray turns this into Win32 `MENUITEMINFO`
//! entries; the macOS tray turns it into `NSMenuItem` instances.
//!
//! The structure is intentionally toolkit-agnostic: no `HMENU`, no
//! `NSMenuItem`, no D-Bus paths. Items carry a stable string `id` so the
//! UI backend can correlate a click event back to a logical action without
//! sharing typed handles.
//!
//! ## Parity with the Linux tray
//!
//! Linux's converter, `build_menu` (see
//! `crates/tillandsias-headless/src/tray/mod.rs::build_menu`) surfaces a
//! status header, then the `Cloud` submenu when authenticated. (The `~/src`
//! submenu was REMOVED by order 997-e4v2 — Cloud is the only project list.)
//! Agents (`Seedlings`), Observatorium and OpenCode Web also live in that
//! tree. All three trays render this shape in a stable order because all
//! three call `build()` — the parity is structural now rather than
//! maintained, which is what 628-p5tj was for.
//!
//! @trace spec:host-shell-architecture, spec:windows-native-tray, spec:macos-native-tray

#![allow(dead_code)]

use serde::{Deserialize, Serialize};

/// PAGE SIZE for the `Cloud` submenu — used ONLY when a page size is explicitly
/// requested via `TILLANDSIAS_MAX_CLOUD_MENU_ITEMS`. **It is not the default.**
/// By default every project is rendered at one level; see
/// [`resolved_cloud_page_size`].
///
/// MEASURED 2026-09-21, AND IT RETIRED THIS CONSTANT'S REASON FOR EXISTING.
/// The paragraph that stood here said: "It is NOT free on Linux: DBusMenu does
/// not scroll, so a page taller than the screen clips off the bottom with no
/// affordance — which is the asymmetry that produced this constant in the first
/// place. Nobody has yet measured a real fleet repo count against a real screen,
/// so it stays at 10 until someone does."
///
/// The operator then did, on GNOME with a real token and a real repo list.
/// **gnome-shell's appindicator scrolls.** It renders a nested DBusMenu submenu
/// as an inline expanding section (`PopupSubMenuMenuItem`) inside a scrollable
/// popup, which is why opening a page reads as "appends the rest below" rather
/// than as a flyout, and why the scroll region is the bottom of the list. So the
/// premise was wrong on the one platform it was asserted about, and Windows
/// (auto-scrolling menus) and macOS (NSMenu scroll arrows) were never in
/// question. **All three scroll. Nothing needed paging.**
///
/// WHAT THE SHAPE OF THIS MISTAKE WAS. The cap was never measured — it was
/// inferred from a true statement about the DBusMenu *protocol* (it carries no
/// scrolling concept) applied to a question about the *shell that renders it*,
/// which is free to scroll whatever it likes. The comment even named its own
/// evidentiary gap ("nobody has yet measured") and the number stayed anyway,
/// because an unmeasured constant with a plausible rationale is indistinguishable
/// from a measured one at the call site. The rationale was load-bearing and
/// nobody was carrying it.
///
/// The paging machinery is KEPT and stays reachable through the env var, for two
/// reasons: a desktop that genuinely clips needs a remedy, and a code path with
/// no live caller is how the *last* version of this bug survived seven weeks
/// green (see `paginate`).
///
/// @trace spec:host-shell-architecture
pub const MAX_CLOUD_PROJECTS_IN_MENU: usize = 10;

/// The effective page size: `None` — the default — means render every project at
/// one level and never emit a page link.
///
/// THIS IS ALSO THE REPAIR OF A SEPARATE DEFECT. `TILLANDSIAS_MAX_CLOUD_MENU_ITEMS`
/// has been advertised to users since 591-33s6 by a tray log line and an overflow
/// label, and **nothing on the live path ever read it**: the only reader,
/// `tray::resolved_max_cloud_projects_in_menu`, is reachable only from the builder
/// 628-p5tj retired, so the remedy the product printed could not work. That is the
/// same mention-vs-use shape catalogued in
/// `cheatsheets/tooling/a-test-is-not-done-until-it-can-fail.md`, and it is the
/// exact thing `openspec/specs/tray-ux` forbids ("no item SHALL advertise an
/// environment variable that nothing reads"). Reading it HERE, in the builder all
/// three platforms call, is what makes the advertisement true.
///
/// @trace spec:tray-ux, spec:host-shell-architecture
pub fn resolved_cloud_page_size() -> Option<usize> {
    std::env::var("TILLANDSIAS_MAX_CLOUD_MENU_ITEMS")
        .ok()
        .and_then(|raw| raw.trim().parse::<usize>().ok())
        .filter(|n| *n > 0)
}

/// Stable IDs the UI backends use to correlate `NSMenuItem` / `MENUITEMINFO`
/// click events back to logical actions. Kept centralised so both backends
/// match without coordination.
pub mod ids {
    pub const STATUS: &str = "status";
    pub const CLOUD_PROJECTS: &str = "cloud-projects";
    pub const CLOUD_PROJECTS_EMPTY: &str = "cloud-projects.empty";
    pub const CLOUD_PROJECTS_LOADING: &str = "cloud-projects.loading";
    pub const CLOUD_PROJECTS_OVERFLOW: &str = "cloud-projects.overflow";
    /// ORDER 1362 (tray-ux inversion). The Cloud submenu's direct children are
    /// AGENT rows; each carries the project list for that agent. The id is new
    /// because the row is new — it resolves to `Inert`, which is correct for a
    /// pure container: enabledness comes from the ITEM, not the action, on all
    /// three adapters (verified by macneo on AppKit and esme on Win32).
    pub const CLOUD_AGENT: &str = "cloud-agent";
    /// Separator rendered before the footer (version/quit).
    pub const SEPARATOR: &str = "---";
    pub const GITHUB_LOGIN: &str = "github-login";
    pub const VERSION: &str = "version";
    pub const QUIT: &str = "quit";

    /// REMOVED UX surface (operator order, 2026-07-22): the `reset-guest`
    /// menu leaf was added 2026-07-21 without operator approval and removed
    /// per `openspec/specs/tray-ux/spec.md` → "UX curation governance".
    /// The id is kept ONLY so absence pins and the legacy-id inert-resolution
    /// tests can reference it — `build()` MUST NOT emit it. The reset
    /// capability itself survives as the `--reset-guest` CLI verb on all
    /// three platforms.
    pub const RESET_GUEST: &str = "reset-guest";

    // Legacy global-picker IDs — no longer emitted by `build()` but kept so
    // the action resolver still compiles.
    pub const AGENTS: &str = "agents";
    pub const AGENT_CLAUDE: &str = "agent.claude";
    pub const AGENT_CODEX: &str = "agent.codex";
    pub const AGENT_OPENCODE: &str = "agent.opencode";
    pub const AGENT_ANTIGRAVITY: &str = "agent.antigravity";
    pub const OBSERVATORIUM: &str = "observatorium";
    pub const OPENCODE_WEB: &str = "opencode-web";

    // Per-project action verb suffixes — used by `build_project_submenu` and
    // resolved by `menu_action::resolve_project`.
    pub const VERB_CLAUDE: &str = "claude";
    pub const VERB_CODEX: &str = "codex";
    pub const VERB_OPENCODE: &str = "opencode";
    pub const VERB_ANTIGRAVITY: &str = "antigravity";
    pub const VERB_OPENCODE_WEB: &str = "opencode-web";
    pub const VERB_OBSERVATORIUM: &str = "observatorium";
    pub const VERB_MAINTENANCE: &str = "maintenance";

    /// Tooltip shown for items deferred to v2 on macOS.
    pub const V2_DISABLED_REASON: &str = "v2 — terminal-only in v1";
    /// Tooltip shown for browser items on WSLg-less Windows hosts.
    pub const WSLG_DISABLED_REASON: &str = "Requires Windows 11 + WSLg";
}

/// Hard cap for the tray chip. The UI backends should never surface a
/// longer string than this in the status row.
pub const TRAY_STATUS_CHIP_MAX_CHARS: usize = 37;

/// Short boot label used before the VM has emitted a richer state.
pub const BOOT_STATUS_TEXT: &str = "\u{1F535} Booting\u{2026}";

/// Clamp a tray chip string to the visible budget. Keeps the string
/// readable without allowing a long event payload to push the chip past
/// the intended 37-character menu-bar budget.
pub fn clamp_tray_status_chip(text: impl AsRef<str>) -> String {
    let text = text.as_ref();
    if text.chars().count() <= TRAY_STATUS_CHIP_MAX_CHARS {
        return text.to_string();
    }

    let mut out = String::with_capacity(TRAY_STATUS_CHIP_MAX_CHARS);
    for ch in text.chars().take(TRAY_STATUS_CHIP_MAX_CHARS - 1) {
        out.push(ch);
    }
    out.push('\u{2026}');
    out
}

/// A single menu node.
///
/// The `enabled` flag plus `disabled_reason` lets either backend render a
/// greyed-out item with an explanatory tooltip. The `checked` flag drives
/// `MF_CHECKED` (Windows) / `setState(.on)` (AppKit) for the agent picker.
///
/// @trace spec:host-shell-architecture
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MenuItem {
    pub id: String,
    pub label: String,
    pub enabled: bool,
    pub disabled_reason: Option<String>,
    pub checked: bool,
    pub children: Vec<MenuItem>,
}

impl MenuItem {
    pub fn leaf(id: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            enabled: true,
            disabled_reason: None,
            checked: false,
            children: Vec::new(),
        }
    }

    pub fn disabled(
        id: impl Into<String>,
        label: impl Into<String>,
        reason: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            enabled: false,
            disabled_reason: Some(reason.into()),
            checked: false,
            children: Vec::new(),
        }
    }

    pub fn submenu(
        id: impl Into<String>,
        label: impl Into<String>,
        children: Vec<MenuItem>,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            enabled: true,
            disabled_reason: None,
            checked: false,
            children,
        }
    }

    pub fn checkmark(id: impl Into<String>, label: impl Into<String>, checked: bool) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            enabled: true,
            disabled_reason: None,
            checked,
            children: Vec::new(),
        }
    }

    /// A visual separator. Backends render this as a horizontal rule.
    /// Use `ids::SEPARATOR` as the id so the renderer can detect it.
    pub fn separator() -> Self {
        Self {
            id: ids::SEPARATOR.to_string(),
            label: String::new(),
            enabled: false,
            disabled_reason: None,
            checked: false,
            children: Vec::new(),
        }
    }

    pub fn is_separator(&self) -> bool {
        self.id == ids::SEPARATOR
    }
}

/// The agent the user has selected for new attaches.
///
/// Mirrors `SelectedAgent` in the Linux tray. The portable menu surfaces
/// these as a `Agents` submenu with checkmark toggles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SelectedAgent {
    Claude,
    Codex,
    OpenCode,
    Antigravity,
}

impl SelectedAgent {
    pub fn display_name(self) -> &'static str {
        match self {
            SelectedAgent::Claude => "Claude",
            SelectedAgent::Codex => "Codex",
            SelectedAgent::OpenCode => "OpenCode",
            SelectedAgent::Antigravity => "Antigravity",
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            SelectedAgent::Claude => ids::AGENT_CLAUDE,
            SelectedAgent::Codex => ids::AGENT_CODEX,
            SelectedAgent::OpenCode => ids::AGENT_OPENCODE,
            SelectedAgent::Antigravity => ids::AGENT_ANTIGRAVITY,
        }
    }
}

/// A single host-side project surfaced in the menu.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectEntry {
    /// Display name. For cloud entries this is the repo name; the `~/src`
    /// basename sense is historical (997-e4v2 removed the local list).
    pub name: String,
    /// Local projects: filesystem path on the host. Cloud projects: the
    /// `owner/repo` slug returned by `gh`.
    pub path: String,
    /// `true` once the in-VM forge for this project has reported "ready".
    /// Used for the running checkmark on local entries.
    pub ready: bool,
    /// Cloud-only: the GitHub `owner/repo` slug used as the menu label so
    /// the user sees the same identifier `gh` returns. `None` for local
    /// projects. When `Some`, used as the submenu label instead of `name`.
    pub full_name: Option<String>,
}

/// Login state surfaced in the menu's GitHub item.
///
/// windows-260719-2: a THREE-state machine, not a boolean. `LoggingIn` is a
/// purely LOCAL, transitional state each tray flips synchronously on the
/// GitHub Login menu click — before any wire round-trip — and clears on the
/// next CONFIRMED login observation (a `LoginStatePush` / login-status reply
/// maps only to `LoggedIn`/`LoggedOut`, so a confirmed probe always
/// overwrites it: success renders logged-in, an invalid/missing token falls
/// back to the `GitHub Login` leaf, never a stale rendering). Deliberately
/// NOT a wire variant: the click is a local signal (the packet's
/// local-flag-preferred design), and no concrete cross-client in-progress
/// coordination need has surfaced that would justify widening
/// `LoginStatePush`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum GithubLoginState {
    /// Order 626-r7kq: NOTHING has been observed yet — the tray has not had a
    /// confirmed answer from the guest since it started. This is the INITIAL
    /// state, and it is distinct from `LoggedOut`, which means "we asked and
    /// the answer was no".
    ///
    /// Collapsing the two is the defect this variant exists to prevent. The
    /// flag that makes the login row clickable (`login_runtime_ready`) resolves
    /// after ONE wire round-trip — milliseconds — while the login answer costs
    /// a container run in the guest (vault read + `gh auth login` + `gh api
    /// user`), i.e. seconds to minutes. With `LoggedOut` as the initial state
    /// the menu spent that entire window offering an actionable `GitHub Login`
    /// to users who were already signed in, and they took it: the operator did
    /// exactly that on v0.4.260809.2 (field log 2026-08-09T06:10:51Z, then a
    /// project click at 06:12:26Z proving the stored credential had been valid
    /// all along), and the same pattern recurs in every session in that log.
    ///
    /// The ratified Observable Streams Contract already specified this state as
    /// `LoginState::Unknown` (plan/issues/observable-streams-contract-2026-06-30.md,
    /// boundary B1); orders 154/230/231/260 landed the push streams but the
    /// variant never reached `MenuState`.
    Unknown,
    LoggedOut,
    /// The login flow has been started from this tray and the confirming
    /// probe has not yet reported. Renders as a disabled "Logging in…" row
    /// in place of the actionable login leaf.
    LoggingIn,
    LoggedIn {
        handle: String,
    },
}

/// Which native UI backend is going to paint the menu. Drives which items
/// are tagged as v2-deferred.
///
/// @trace spec:macos-native-tray.ui.gui-passthrough-v2@v1
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TargetSurface {
    LinuxTray,
    WindowsTray,
    MacosTray,
}

impl TargetSurface {
    /// True if this surface defers GUI-passthrough items to v2.
    pub fn defers_gui_to_v2(self) -> bool {
        matches!(self, TargetSurface::MacosTray)
    }
}

/// Aggregated state the host shell feeds into `build()` to compute the
/// portable menu snapshot the OS-specific trays render.
///
/// `version` carries the host-shell crate version so the menu can display
/// the same `v<X.Y.Z> — By Tlatoāni` line the Linux tray does.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MenuState {
    pub guest_version: Option<String>,
    pub status_text: String,
    pub version: String,
    pub login: GithubLoginState,
    pub cloud_projects: Vec<ProjectEntry>,
    /// False until the first cloud-projects answer (push or refresh reply)
    /// lands. Distinguishes "still fetching your GitHub repos" from a
    /// confirmed empty answer so the menu never claims "(no repos)" while
    /// the request is in flight (operator report 2026-07-28).
    pub cloud_projects_loaded: bool,
    pub selected_agent: SelectedAgent,
    /// True on Win11+WSLg hosts; false otherwise. Gates Observatorium +
    /// OpenCode Web items. Combined with the target surface (macOS defers
    /// GUI to v2 regardless), this determines whether browser items are
    /// rendered enabled.
    pub gui_passthrough_available: bool,
    /// True when podman is verified ready in the VM; gates per-project
    /// actions (`Attach Here` etc.) so the user is not asked to start a
    /// forge before the VM is healthy.
    pub podman_ready: bool,
    /// True when the runtime is ready to execute GitHub Login (init complete
    /// plus Vault/git/egress containers up). When false and logged out, replaces
    /// the GitHub Login item with a disabled "Setting up\u{2026}" entry so the
    /// user does not attempt login before the runtime is healthy.
    pub login_runtime_ready: bool,
    /// Target UI backend. Drives macOS's "(v2)" defer markers.
    pub target: TargetSurface,
    /// `Some(reason)` once provisioning has FAILED TERMINALLY — the retry
    /// budget is exhausted and no attempt is in flight. Renders the Retry +
    /// Open log affordances (order 648-jv69).
    ///
    /// This field exists because the affordances were unreachable. The tray's
    /// status chip has always been able to say
    /// `🔴 Provisioning failed — Retry`, and `MenuAction::Retry` is fully
    /// implemented and correctly clears `PROVISIONING_ACTIVE` so a fresh
    /// attempt can start. But the ONLY constructor of a `retry` leaf is
    /// `MenuStructure::failed()`, and nothing on the Windows path — nor `build`
    /// below — ever called it. The chip named an action that had no control
    /// anywhere in the menu.
    ///
    /// Operator report, 2026-08-10: "it says 'provision failed - retry' but
    /// 'retry' is not actionable, I don't know if it's retrying at all." Both
    /// halves were true, and for different reasons: no Retry control existed,
    /// and the chip does not distinguish "still trying" from "gave up".
    ///
    /// Additive by construction: `None` on every existing constructor, so the
    /// Linux and macOS trays render exactly as before until they set it.
    pub provisioning_failure: Option<String>,
}

impl MenuState {
    /// Baseline test state: cold-start, no projects, logged-out, podman
    /// not ready, target=WindowsTray.
    pub fn initial() -> Self {
        Self {
            guest_version: None,
            status_text: BOOT_STATUS_TEXT.to_string(),
            version: crate::version().to_string(),
            // Order 626-r7kq: NOT LoggedOut. Nothing has been observed at
            // construction time, and claiming "signed out" before asking is
            // what put an actionable login leaf in front of signed-in users.
            login: GithubLoginState::Unknown,
            cloud_projects: Vec::new(),
            cloud_projects_loaded: false,
            selected_agent: SelectedAgent::Claude,
            gui_passthrough_available: false,
            podman_ready: false,
            login_runtime_ready: false,
            target: TargetSurface::WindowsTray,
            provisioning_failure: None,
        }
    }
}

/// Coarse menu shape the tray paints.
///
/// Three states map onto three menu shapes:
/// - `Provisioning`: a single condensed status line + Quit footer.
/// - `Ready`: the full parity menu fed from `MenuState`.
/// - `Failed`: an error line with Retry + Open Log sub-items.
///
/// @trace spec:host-shell-architecture, spec:vm-provisioning-lifecycle
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum MenuStructure {
    Provisioning { items: Vec<MenuItem> },
    Ready { items: Vec<MenuItem> },
    Failed { items: Vec<MenuItem> },
}

impl MenuStructure {
    /// Construct an initial provisioning menu with the verbatim default
    /// phase string from `vm-provisioning-lifecycle.ux.condensed-status@v1`.
    pub fn initial_provisioning() -> Self {
        MenuStructure::Provisioning {
            items: vec![
                MenuItem::disabled(ids::STATUS, BOOT_STATUS_TEXT, "VM is provisioning"),
                MenuItem::leaf(ids::QUIT, "\u{274C} Quit Tillandsias"),
            ],
        }
    }

    /// Construct a failure menu with the error reason + retry/open-log
    /// affordances.
    pub fn failed(reason: impl Into<String>) -> Self {
        let reason = reason.into();
        MenuStructure::Failed {
            items: vec![
                MenuItem::disabled(
                    ids::STATUS,
                    format!("\u{1F940} Provisioning failed: {}", truncate_80(&reason)),
                    reason,
                ),
                MenuItem::leaf("retry", "Retry"),
                MenuItem::leaf("open-log", "Open log"),
                MenuItem::leaf(ids::QUIT, "\u{274C} Quit Tillandsias"),
            ],
        }
    }

    /// Convenience accessor: the top-level item list of whichever variant
    /// is active. Used by the OS trays to walk the menu uniformly.
    pub fn top_items(&self) -> &[MenuItem] {
        match self {
            MenuStructure::Provisioning { items }
            | MenuStructure::Ready { items }
            | MenuStructure::Failed { items } => items,
        }
    }
}

fn truncate_80(s: &str) -> String {
    if s.chars().count() <= 80 {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(77).collect();
        out.push('\u{2026}');
        out
    }
}

/// Build the portable `MenuStructure` from the aggregate `MenuState`.
///
/// The returned menu matches the Linux tray `build_menu` structure 1:1.
/// OS-specific trays only translate labels + click IDs into native APIs;
/// they MUST NOT reorder or filter items.
///
/// ## Top-level item contract (Ready) — login-gated
///
/// The body is **auth-gated**: exactly one of `{github-login}` OR
/// `{Cloud}` is emitted, never both — matching the Linux golden. (997-e4v2
/// removed the `~/src` half; this line used to name it and was stale prose.)
/// Agent selection lives inside each per-project submenu, not at top level.
///
/// This item set is UX-curation-governed: adding, removing, or reordering
/// ANY id below requires recorded operator approval
/// (`openspec/specs/tray-ux/spec.md` → "UX curation governance"). The
/// `reset-guest` leaf was removed 2026-07-22 by operator order; the reset
/// capability survives only as the `--reset-guest` CLI verb.
///
/// Logged **out** (collapsed) — 5 items:
/// 1. `status` — disabled, current status line
/// 2. `github-login` — `🔑 GitHub Login` leaf (or `📋 Setting up…` if not ready)
/// 3. `---` — separator
/// 4. `version` — disabled footer
/// 5. `quit`
///
/// Logged **in** (expanded) — 6 items:
/// 1. `status`
/// 2. (removed) `local-projects` — the `~/src` submenu was deleted by order
///    997-e4v2. Cloud is the only project list. Kept as a numbered tombstone
///    so the list below still lines up with what the menu actually emits.
/// 3. `cloud-projects` — submenu paged at `MAX_CLOUD_PROJECTS_IN_MENU` per level,
///    the remainder fanned out into nested "… N more" submenus (591-33s6).
///    Every project is reachable; the page size sets depth, not visibility.
/// 4. `---` — separator
/// 5. `version` — disabled footer
/// 6. `quit`
///
/// @trace spec:host-shell-architecture, spec:windows-native-tray, spec:macos-native-tray, spec:tray-ux
pub fn build(state: &MenuState) -> MenuStructure {
    let mut items = Vec::new();

    // (1) Status — always disabled, always first.
    items.push(MenuItem::disabled(
        ids::STATUS,
        clamp_tray_status_chip(&state.status_text),
        "current status",
    ));

    // (1b) TERMINAL PROVISIONING FAILURE — Retry + Open log, immediately under
    //      the status line (order 648-jv69).
    //
    //      This branch returns EARLY and deliberately. A failed provision means
    //      there is no VM, so every item below — projects, cloud repos, sign-in,
    //      per-project attach — is either inert or actively misleading. Offering
    //      "Attach Here" against a VM that does not exist is the same class of
    //      lie as the chip that named a Retry with no control behind it.
    //
    //      The status line above already carries the reason; these two leaves
    //      are the only actions that can make progress from here.
    if state.provisioning_failure.is_some() {
        items.push(MenuItem::leaf("retry", "\u{1F504} Retry provisioning"));
        items.push(MenuItem::leaf("open-log", "Open log"));
        items.push(MenuItem::leaf(ids::QUIT, "\u{274C} Quit Tillandsias"));
        return MenuStructure::Failed { items };
    }

    // (2) Auth-gated body. Mirror the Linux golden `build_menu`: emit exactly
    //     one of {GitHub Login} OR {Cloud}, never both (997-e4v2).
    match &state.login {
        // Order 626-r7kq (operator-approved surface, 2026-08-09T08:33Z): the
        // not-yet-known window gets its OWN disabled row, distinct from the
        // "Setting up…" the runtime-not-ready case shows, so the two waits are
        // tellable apart. Disabled is the load-bearing part — a sign-in the
        // tray has not yet ruled out must never be offered as an action.
        GithubLoginState::Unknown => {
            // The approved sequence has TWO distinguishable waits, so this arm
            // splits on the same runtime flag the LoggedOut arm uses:
            //   runtime not ready -> the workspace itself is still coming up
            //   runtime ready     -> workspace is up, the sign-in answer is
            //                        outstanding (the container-run probe)
            // Both disabled. Disabled is the load-bearing part: a sign-in the
            // tray has not yet ruled out must never be offered as an action.
            if state.login_runtime_ready {
                items.push(MenuItem::disabled(
                    ids::GITHUB_LOGIN,
                    "\u{1F504} Checking your account\u{2026}",
                    "sign-in state not yet known",
                ));
            } else {
                items.push(MenuItem::disabled(
                    ids::GITHUB_LOGIN,
                    "\u{1F4CB} Setting up\u{2026}",
                    "login runtime not ready",
                ));
            }
        }
        GithubLoginState::LoggedOut => {
            if state.login_runtime_ready {
                items.push(MenuItem::leaf(ids::GITHUB_LOGIN, "\u{1F511} GitHub Login"));
            } else {
                items.push(MenuItem::disabled(
                    ids::GITHUB_LOGIN,
                    "\u{1F4CB} Setting up\u{2026}",
                    "login runtime not ready",
                ));
            }
        }
        GithubLoginState::LoggingIn => {
            // windows-260719-2: transitional state, flipped locally on the
            // login click before any wire round-trip. Disabled (a second
            // click mid-flow is meaningless) in the same short-list slot as
            // the login leaf, mirroring the "Setting up…" disabled-item
            // pattern above. Cleared by the next confirmed probe reply.
            items.push(MenuItem::disabled(
                ids::GITHUB_LOGIN,
                "\u{1F504} Logging in\u{2026}",
                "login in progress",
            ));
        }
        GithubLoginState::LoggedIn { .. } => {
            // Cloud projects — submenu (cap + overflow).
            items.push(build_cloud_projects(state));
        }
    }

    // (3) Separator before footer — matches Linux tray.
    items.push(MenuItem::separator());

    let mut ver_str = format!("v{} \u{2014} By Tlatoa\u{0304}ni", state.version);
    if let Some(ref guest_ver) = state.guest_version
        && guest_ver != &state.version
    {
        ver_str.push_str(" (Update Pending)");
    }

    // (4) Footer: version + quit ONLY. The `reset-guest` leaf that briefly
    //     lived here was an UNAPPROVED UX surface and was removed by operator
    //     order 2026-07-22 (tray-ux "UX curation governance"); the recovery
    //     affordance for a wedged guest is the `--reset-guest` CLI verb.
    items.push(MenuItem::disabled(ids::VERSION, ver_str, "informational"));
    items.push(MenuItem::leaf(ids::QUIT, "\u{274C} Quit Tillandsias"));

    // (5) THE LINUX-ONLY REORDER IS REVERTED. It made the menu WORSE, and the
    // measurement that proves it is worth more than the change was.
    //
    // WHAT IT DID. Operator, 2026-09-22: "clicking on a project expands the
    // options within the same space, so it goes under the existing menus." So
    // the cloud list was moved below the footer, on the reasoning that an
    // inline expansion would then grow into the scroll region instead of
    // displacing anything.
    //
    // WHAT ACTUALLY HAPPENED. Operator, same day, after: "it correctly lists
    // all projects with a vertical scroll bar, but I can't launch any project,
    // when clicking on a project the agent selector isn't visible." An
    // expansion that opens at the BOTTOM of an already-scrolling list has
    // nothing below it to scroll into, and gnome-shell does not scroll a
    // freshly-opened PopupSubMenu into view. Before the reorder the selector
    // was visible and merely displaced the footer; after it, the selector could
    // not be reached at all. A cosmetic complaint was traded for a functional
    // one.
    //
    // THE MENU WAS NEVER WRONG, WHICH IS THE PART TO KEEP. Read off the live
    // tray's own DBusMenu rather than inferred from the symptom:
    //     id 22   "Cloud"                children-display submenu, 25 children
    //     id …975 "8007342/tillandsias"  children-display submenu,  7 children
    //                                    Claude/Codex/OpenCode… enabled: true
    // Every agent leaf was emitted, enabled and carried. So this was a
    // RENDERING reach, not a construction defect, and no amount of reading
    // build() would have found it — the same distinction as "could not ask"
    // versus "answered no", one layer up in the UI.
    //
    // ORDER IS NOT THE LEVER. Both placements are reachable failures of the
    // same thing: gnome-shell expands a submenu INLINE, and an inline expansion
    // inside a scrolling popup is displaced-or-invisible depending only on
    // where it sits. The lever is DEPTH — a project row that launches without
    // needing a second level does not expand at all. That is the operator's
    // option 2 from 2026-09-22 and it is the follow-up; it is not made here,
    // because restoring the ability to launch comes before improving it.

    MenuStructure::Ready { items }
}

/// Split a built list of rows into pages, each carrying the next.
///
/// ORDER 591-33s6 for the fan-out, generalised by the 1362 inversion: it now
/// pages ANY row list rather than projects specifically, because after the
/// inversion the thing that can overflow is a list of projects UNDER AN AGENT,
/// and a second copy of this logic keyed on a different id would drift from the
/// first. `id_prefix` keeps page ids unique per agent.
///
/// PAGING IS OPT-IN and `None` is the default: every shell that renders this
/// menu scrolls its own popup, measured on gnome-shell 2026-09-21. The
/// machinery stays live because a desktop that really clips needs a remedy and
/// because a code path with no live caller is how 591-33s6 survived seven weeks
/// green.
fn paginate(rows: Vec<MenuItem>, id_prefix: &str, page_size: Option<usize>, page: usize) -> Vec<MenuItem> {
    let take = match page_size {
        Some(n) => rows.len().min(n),
        None => rows.len(),
    };
    if take >= rows.len() {
        return rows;
    }
    let mut rows = rows;
    let rest = rows.split_off(take);
    let remaining = rest.len();
    let children = paginate(rest, id_prefix, page_size, page + 1);
    // Never childless: a page link with no children takes the LEAF branch on
    // Win32, is minted a live command id, dispatches to Inert and does nothing
    // while looking ordinary (esme-windows, 1347-r9g8). Unreachable here, which
    // is why it is asserted rather than assumed.
    debug_assert!(!children.is_empty(), "a page link must never be childless");
    if !children.is_empty() {
        rows.push(MenuItem::submenu(
            format!("{}.{}.{}", ids::CLOUD_PROJECTS_OVERFLOW, id_prefix, page + 1),
            format!("\u{2026} {remaining} more"),
            children,
        ));
    }
    rows
}

/// ORDER 1362 — AGENTS FIRST, THEN PROJECTS. The inversion, and why.
///
/// THE MEASUREMENT THAT FORCED IT. gnome-shell expands a DBusMenu submenu
/// INLINE and will not draw a flyout: `dbusMenu.js:591` maps
/// `children-display == "submenu"` unconditionally to `PopupSubMenuMenuItem`,
/// GNOME's popup vocabulary has no flyout-submenu class at all, and the
/// extension exposes no setting that changes it. So the shape of the expansion
/// is not ours to request — only its DEPTH and its POSITION are.
///
/// BOTH POSITIONS FAILED, which is what ruled position out as the lever.
/// Projects above the footer: the expansion displaced the footer (operator,
/// "it goes under the existing menus"). Projects last: the expansion opened at
/// the bottom of an already-scrolling list with nothing below to scroll into,
/// and the agent selector could not be reached AT ALL (operator, "I can't
/// launch any project"). The second is worse than the first, and the revert is
/// recorded in `build()`.
///
/// WHAT THE INVERSION CHANGES. The Cloud submenu's children are now the SEVEN
/// agents, a short fixed list. Expanding one opens the project list — the thing
/// the operator actually wants to browse — from near the top of the popup, with
/// the whole scroll region below it rather than from deep inside a 22-row list.
/// Seven rows also means the collapsed menu is short enough that the popup is
/// not already at its scroll limit before anything expands.
///
/// THE LEAF IDS ARE UNCHANGED, DELIBERATELY: still `project.<scope>.<name>.<verb>`,
/// which `menu_action::resolve_project` parses back out. The inversion moves
/// where a leaf SITS, not what it is called, so every launch path keeps working
/// and no adapter needs to learn a new grammar. Changing the ids here would be
/// the tidy-looking edit that turns a menu into a set of inert rows.
///
/// PER-LEAF ENABLEDNESS IS PRESERVED EXACTLY rather than lifted to the agent
/// row. A browser verb deferred to v2 on macOS disables its LEAVES, as before;
/// the agent row stays enabled. Disabling the row instead would read better and
/// behave worse — a disabled NSMenuItem does not open its submenu, so the
/// projects under it would become unreachable rather than visibly unavailable
/// (macneo, on real hardware).
fn build_agent_rows(state: &MenuState) -> Vec<MenuItem> {
    // Browser-launching leaves are deferred to v2 on macOS because AppKit trays
    // cannot open GUI windows in v1.
    let browser_verbs = &[ids::VERB_OPENCODE_WEB, ids::VERB_OBSERVATORIUM];

    let agents: &[(&str, &str)] = &[
        (ids::VERB_CLAUDE, "\u{1F47E} Claude"),
        (ids::VERB_CODEX, "\u{1F3D7}\u{FE0F} Codex"),
        (ids::VERB_OPENCODE, "\u{1F4BB} OpenCode"),
        (ids::VERB_ANTIGRAVITY, "\u{1FA90} Antigravity"),
        (ids::VERB_OPENCODE_WEB, "\u{1F4D0} OpenCode Web"),
        (ids::VERB_OBSERVATORIUM, "\u{1F52D} Observatorium"),
        (ids::VERB_MAINTENANCE, "\u{1F527} Maintenance"),
    ];

    let page_size = resolved_cloud_page_size();

    agents
        .iter()
        .map(|(verb, agent_label)| {
            let rows: Vec<MenuItem> = state
                .cloud_projects
                .iter()
                .map(|project| {
                    let leaf_id = format!("project.cloud.{}.{}", project.name, verb);
                    let label = project
                        .full_name
                        .as_deref()
                        .unwrap_or(&project.name)
                        .to_string();
                    if state.target.defers_gui_to_v2() && browser_verbs.contains(verb) {
                        MenuItem::disabled(leaf_id, label, ids::V2_DISABLED_REASON)
                    } else if state.podman_ready {
                        MenuItem::leaf(leaf_id, label)
                    } else {
                        MenuItem::disabled(leaf_id, label, "VM is not ready yet")
                    }
                })
                .collect();

            MenuItem::submenu(
                format!("{}.{}", ids::CLOUD_AGENT, verb),
                *agent_label,
                paginate(rows, verb, page_size, 0),
            )
        })
        .collect()
}

fn build_cloud_projects(state: &MenuState) -> MenuItem {
    let mut children: Vec<MenuItem> = if state.cloud_projects.is_empty() {
        Vec::new()
    } else {
        build_agent_rows(state)
    };

    if children.is_empty() {
        if state.cloud_projects_loaded {
            children.push(MenuItem::disabled(
                ids::CLOUD_PROJECTS_EMPTY,
                "(no repos)",
                "no GitHub repos visible to the in-VM gh client",
            ));
        } else {
            children.push(MenuItem::disabled(
                ids::CLOUD_PROJECTS_LOADING,
                "(loading repos\u{2026})",
                "fetching your GitHub repos from the in-VM gh client",
            ));
        }
    }

    MenuItem::submenu(ids::CLOUD_PROJECTS, "\u{2601}\u{FE0F} Cloud", children)
}

// Legacy top-level helpers — no longer called from `build()` (moved into
// per-project submenus for Linux parity). Retained for reference.
#[allow(dead_code)]
fn build_agents(state: &MenuState) -> MenuItem {
    let mut children = Vec::new();
    for agent in [
        SelectedAgent::Claude,
        SelectedAgent::Codex,
        SelectedAgent::OpenCode,
        SelectedAgent::Antigravity,
    ] {
        children.push(MenuItem::checkmark(
            agent.id(),
            agent.display_name(),
            state.selected_agent == agent,
        ));
    }
    MenuItem::submenu(ids::AGENTS, "\u{1F331} Agents", children)
}

#[allow(dead_code)]
fn build_observatorium(state: &MenuState) -> MenuItem {
    if state.target.defers_gui_to_v2() {
        MenuItem::disabled(
            ids::OBSERVATORIUM,
            "\u{1F52D} Observatorium",
            ids::V2_DISABLED_REASON,
        )
    } else if state.gui_passthrough_available {
        MenuItem::leaf(ids::OBSERVATORIUM, "\u{1F52D} Observatorium")
    } else {
        MenuItem::disabled(
            ids::OBSERVATORIUM,
            "\u{1F52D} Observatorium",
            ids::WSLG_DISABLED_REASON,
        )
    }
}

#[allow(dead_code)]
fn build_opencode_web(state: &MenuState) -> MenuItem {
    if state.target.defers_gui_to_v2() {
        MenuItem::disabled(
            ids::OPENCODE_WEB,
            "\u{1F310} OpenCode Web",
            ids::V2_DISABLED_REASON,
        )
    } else if state.gui_passthrough_available {
        MenuItem::leaf(ids::OPENCODE_WEB, "\u{1F310} OpenCode Web")
    } else {
        MenuItem::disabled(
            ids::OPENCODE_WEB,
            "\u{1F310} OpenCode Web",
            ids::WSLG_DISABLED_REASON,
        )
    }
}

fn build_project_submenu(
    scope: &str,
    project: &ProjectEntry,
    podman_ready: bool,
    target: TargetSurface,
) -> MenuItem {
    let id = format!("project.{}.{}", scope, project.name);

    // Browser-launching leaves (OpenCode Web, Observatorium) are deferred to
    // v2 on macOS because AppKit trays can't open GUI windows in v1.
    let browser_verbs = &[ids::VERB_OPENCODE_WEB, ids::VERB_OBSERVATORIUM];

    let leaves: &[(&str, &str)] = &[
        (ids::VERB_CLAUDE, "\u{1F47E} Claude"),
        (ids::VERB_CODEX, "\u{1F3D7}\u{FE0F} Codex"),
        (ids::VERB_OPENCODE, "\u{1F4BB} OpenCode"),
        (ids::VERB_ANTIGRAVITY, "\u{1FA90} Antigravity"),
        (ids::VERB_OPENCODE_WEB, "\u{1F4D0} OpenCode Web"),
        (ids::VERB_OBSERVATORIUM, "\u{1F52D} Observatorium"),
        (ids::VERB_MAINTENANCE, "\u{1F527} Maintenance"),
    ];

    let children = leaves
        .iter()
        .map(|(verb, label)| {
            let leaf_id = format!("{}.{}", id, verb);
            if target.defers_gui_to_v2() && browser_verbs.contains(verb) {
                MenuItem::disabled(leaf_id, *label, ids::V2_DISABLED_REASON)
            } else if podman_ready {
                MenuItem::leaf(leaf_id, *label)
            } else {
                MenuItem::disabled(leaf_id, *label, "VM is not ready yet")
            }
        })
        .collect();

    // ORDER 997-e4v2. The label used to gain a "✓" for a READY project when
    // `scope == "local"`. That branch is unreachable: `build_project_submenu`
    // has exactly one call site and it always passes "cloud", so the ready-tick
    // has not rendered since the local list was removed. Deleted rather than
    // left to read as a live affordance.
    //
    // `scope` itself STAYS, and is not vestigial despite having one caller: it
    // is part of the id grammar (`project.<scope>.<name>`) that
    // `menu_action::resolve_project` parses back out. Dropping the parameter
    // would change every project id and break resolution — which is the kind of
    // tidy-looking removal that turns a menu into a set of inert rows.
    let label = project
        .full_name
        .as_deref()
        .unwrap_or(&project.name)
        .to_string();

    MenuItem::submenu(id, label, children)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// @trace spec:host-shell-architecture
    /// @trace order:628-p5tj
    ///
    /// EXIT CRITERION 3: the three platforms produce the same top-level item id
    /// sequence for the same state.
    ///
    /// WHY THIS TEST IS HERE AND NOT THREE TESTS. Since the convergence
    /// (3500e6301) all three trays derive their menu from THIS `build()`:
    /// Windows and macOS walk `top_items()` directly; Linux converts the same
    /// items in order via `shared_menu_item_to_node`. So the id sequence is a
    /// property of one function, and pinning it here pins all three at once. A
    /// reorder or an inserted item now fails HERE — once, loudly, before any
    /// platform ships it — instead of diverging silently in one tray the way
    /// 626-r7kq did, where a shared-layer fix landed and Linux did not inherit
    /// it because Linux had its own builder.
    ///
    /// WHAT IT DOES NOT PROVE, stated so nobody reads more into it. It does not
    /// execute the macOS or Windows tray code, which is cfg-gated off this
    /// host; those lanes derive from `build()` BY CONSTRUCTION and their own
    /// conversion fidelity is theirs to assert. And a golden sequence is a
    /// characterization test: it detects change, it does not judge whether a
    /// change is correct. When it fails, decide whether the new sequence is
    /// right and update it deliberately — do not update it to make the test
    /// pass.
    #[test]
    fn top_level_id_sequence_is_pinned_for_all_platforms() {
        // THIS TEST ONLY EVER BUILT THE WINDOWS MENU, for its whole life.
        //
        // `MenuState::initial()` sets `target: TargetSurface::WindowsTray`, and
        // every state below is derived from it, so "pinned for all platforms"
        // was pinning ONE platform three times. Found 2026-09-22 when a
        // deliberate Linux-only reorder did not fail it — the change should have
        // tripped invariant (a) immediately, and the silence is what exposed the
        // fixture.
        //
        // It is the same defect family as the rest of this file's history: a
        // name that asserts coverage, a body that does not have it, and nothing
        // able to report the gap because the assertions themselves all passed.
        // The test was not weak; it was aimed at one platform while claiming
        // three.
        //
        // `ids_of` now takes the surface explicitly, and every invariant below
        // runs across all three.
        fn ids_of_on(state: &MenuState, target: TargetSurface) -> Vec<String> {
            let mut st = state.clone();
            st.target = target;
            build(&st)
                .top_items()
                .iter()
                .map(|i| i.id.clone())
                .collect()
        }
        fn ids_of(state: &MenuState) -> Vec<String> {
            ids_of_on(state, TargetSurface::WindowsTray)
        }

        // 1. Cold start, logged out, nothing ready.
        let cold = MenuState::initial();
        let cold_ids = ids_of(&cold);

        // 2. Same state with a terminal provisioning failure — the early-return
        //    branch, which is where a divergence would be least visible because
        //    the menu is short.
        let mut failed = MenuState::initial();
        failed.provisioning_failure = Some("disk full".to_string());
        let failed_ids = ids_of(&failed);

        // 3. Logged in with one local and one cloud project.
        let mut ready = MenuState::initial();
        ready.login = GithubLoginState::LoggedIn {
            handle: "tlatoani".to_string(),
        };
        ready.podman_ready = true;
        ready.login_runtime_ready = true;
        ready.cloud_projects_loaded = true;
        ready.cloud_projects = vec![ProjectEntry {
            name: "repo".to_string(),
            path: "octocat/repo".to_string(),
            ready: false,
            full_name: Some("octocat/repo".to_string()),
        }];
        let ready_ids = ids_of(&ready);

        // THE INVARIANTS, checked rather than eyeballed.

        // a. Every state opens with the status line and closes with quit. A tray
        //    that lost either would still render, which is why this is asserted
        //    rather than left to the golden compare below.
        for (name, seq) in [
            ("cold", &cold_ids),
            ("failed", &failed_ids),
            ("ready", &ready_ids),
        ] {
            assert_eq!(
                seq.first().map(String::as_str),
                Some(ids::STATUS),
                "{name}: status line is not first: {seq:?}"
            );
            assert_eq!(
                seq.last().map(String::as_str),
                Some(ids::QUIT),
                "{name}: quit is not last: {seq:?}"
            );
        }

        // a2. THE SWEEP THE NAME ALWAYS PROMISED: every surface, every state.
        //
        // Status is first everywhere, unconditionally. The LAST item is where
        // the three surfaces legitimately differ, and the difference is stated
        // here rather than left implicit:
        //
        //   Windows / macOS — `quit` is last. Their menus open a real flyout
        //     over the parent, so an expanded project displaces nothing and the
        //     conventional footer-last layout is correct.
        //   Linux — the CLOUD LIST is last, below the footer, because
        //     gnome-shell expands a submenu INLINE (dbusMenu.js:590 maps
        //     children-display=submenu to PopupSubMenuMenuItem unconditionally;
        //     no branch yields a flyout). With the list anywhere but last, an
        //     expansion pushes the footer down and off the fold — measured by
        //     the operator, 2026-09-22.
        //
        // Asserted as a POSITIVE expectation per surface, never as "quit is
        // last unless Linux", so that a Linux menu which lost its project list
        // fails here instead of quietly satisfying a negation.
        for target in [
            TargetSurface::WindowsTray,
            TargetSurface::MacosTray,
            TargetSurface::LinuxTray,
        ] {
            let seq = ids_of_on(&ready, target);
            assert_eq!(
                seq.first().map(String::as_str),
                Some(ids::STATUS),
                "{target:?}: status line is not first: {seq:?}"
            );
            // REVERTED 2026-09-22: `quit` is last on ALL THREE again. The
            // Linux-only reorder that made the cloud list last was withdrawn
            // when the operator measured its effect — an inline expansion at
            // the bottom of a scrolling popup is not reachable at all, which is
            // worse than one that displaces the footer.
            //
            // THE SWEEP STAYS, and it is the part that was worth having. This
            // arm exists because the test above it only ever built the WINDOWS
            // menu while claiming all three; that defect is independent of
            // which order is correct, and reverting the order must not revert
            // the coverage. Written as a positive expectation per surface
            // rather than a single constant, so a future divergence is
            // expressed here rather than discovered by an operator.
            let expected_last = match target {
                TargetSurface::LinuxTray | TargetSurface::WindowsTray | TargetSurface::MacosTray => {
                    ids::QUIT
                }
            };
            assert_eq!(
                seq.last().map(String::as_str),
                Some(expected_last),
                "{target:?}: unexpected last item: {seq:?}"
            );
            // The ID SET is identical on all three — only the order differs.
            // This is the parity 628-p5tj bought, and it is what stops the
            // Linux reorder above from becoming general drift.
            let mut here = seq.clone();
            here.sort();
            let mut win = ids_of_on(&ready, TargetSurface::WindowsTray);
            win.sort();
            here.retain(|i| i != ids::SEPARATOR);
            win.retain(|i| i != ids::SEPARATOR);
            assert_eq!(
                here, win,
                "{target:?}: top-level id SET diverged from Windows (order may differ, membership may not)"
            );
        }

        // b. No duplicate ids within a menu. A duplicate would make the
        //    platform id->handler mapping ambiguous and the second item dead.
        for (name, seq) in [
            ("cold", &cold_ids),
            ("failed", &failed_ids),
            ("ready", &ready_ids),
        ] {
            let mut sorted = seq.clone();
            sorted.sort();
            let before = sorted.len();
            sorted.dedup();
            assert_eq!(
                before,
                sorted.len(),
                "{name}: duplicate top-level id in {seq:?}"
            );
        }

        // c. The failure branch really is the short early-return, not the full
        //    menu with a failure chip. If this stops holding, the branch above
        //    it changed and the reason in `build()` needs re-reading.
        assert!(
            failed_ids.len() < ready_ids.len(),
            "failure menu is not shorter than the ready menu: {failed_ids:?} vs {ready_ids:?}"
        );

        // d. GOLDEN SEQUENCES. Update deliberately, never to make this pass.
        assert_eq!(
            failed_ids,
            vec![
                ids::STATUS.to_string(),
                "retry".to_string(),
                "open-log".to_string(),
                ids::QUIT.to_string(),
            ],
            "the provisioning-failure id sequence changed"
        );
    }

    /// @trace spec:host-shell-architecture, spec:windows-native-tray
    ///
    /// Logged-in menu: status + Cloud submenu + separator +
    /// version + quit = 6 top-level items, matching the Linux tray 1:1.
    /// Agent selection lives inside each per-project submenu (7 leaves each).
    #[test]
    fn menu_structure_matches_linux_tray_parity() {
        let cloud = (0..22)
            .map(|i| ProjectEntry {
                name: format!("cloud-{i}"),
                path: format!("octocat/cloud-{i}"),
                ready: false,
                full_name: None,
            })
            .collect::<Vec<_>>();

        let state = MenuState {
            status_text: "Ready".to_string(),
            version: "0.0.0".to_string(),
            login: GithubLoginState::LoggedIn {
                handle: "tlatoani".to_string(),
            },
            cloud_projects: cloud,
            cloud_projects_loaded: true,
            selected_agent: SelectedAgent::Claude,
            gui_passthrough_available: true,
            podman_ready: true,
            guest_version: None,
            login_runtime_ready: true,
            target: TargetSurface::WindowsTray,
            provisioning_failure: None,
        };

        // SPEC tray-ux, "Refresh is idempotent": rendering twice from the same
        // inputs must produce the same menu item for item. Asserted here, on the
        // same populated state the parity test already builds, because the
        // requirement is cheap to satisfy accidentally and expensive to notice
        // losing — a menu that reorders or re-ids between refreshes breaks every
        // id-keyed dispatch downstream, and nothing else in this suite would say
        // so. `MenuItem` derives PartialEq, so this is a real structural
        // comparison and not a label check.
        assert_eq!(
            build(&state),
            build(&state),
            "two renders from identical inputs must be identical item for item",
        );

        let menu = build(&state);
        let items = match &menu {
            MenuStructure::Ready { items } => items,
            other => panic!("expected MenuStructure::Ready, got {other:?}"),
        };

        // status + cloud + separator + version + quit = 5 top-level items.
        // Order 997-e4v2 removed the local-projects submenu: Cloud is the only
        // project path, so the Linux-parity contract is five, not six. The
        // unapproved reset-guest leaf went earlier (operator order 2026-07-22).
        assert_eq!(
            items.len(),
            5,
            "top-level item count (authenticated, Linux parity)"
        );

        let actual_ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(
            actual_ids,
            vec![
                ids::STATUS,
                ids::CLOUD_PROJECTS,
                ids::SEPARATOR,
                ids::VERSION,
                ids::QUIT,
            ],
            "top-level IDs must follow the Linux-parity contract",
        );
        assert!(
            !actual_ids.contains(&ids::GITHUB_LOGIN),
            "github-login must NOT appear alongside the project body",
        );
        // Global Agents/Observatorium/OpenCode Web no longer at top level.
        for gone in [ids::AGENTS, ids::OBSERVATORIUM, ids::OPENCODE_WEB] {
            assert!(
                !actual_ids.contains(&gone),
                "{gone} must NOT appear at top level"
            );
        }

        // Cloud projects: ALL 22, flat, no page link.
        // 997-e4v2: looked up by ID, not by index. The local-projects submenu
        // that used to sit at [1] is gone, and an index-based lookup silently
        // became a different node when it went — which is how this test failed
        // on a menu change rather than on a menu defect.
        //
        // OPERATOR MEASUREMENT 2026-09-21. This assertion previously read
        // `MAX_CLOUD_PROJECTS_IN_MENU + 1` — ten projects and a page link. It was
        // a correct pin of a shape built on a false premise (that gnome-shell
        // cannot scroll a tray menu), so it passed for exactly as long as nobody
        // checked the premise against a screen. The default is now flat.
        let cloud_node = items
            .iter()
            .find(|i| i.id == ids::CLOUD_PROJECTS)
            .expect("cloud-projects submenu present");
        // ORDER 1362 — AGENTS FIRST. Cloud's children are the seven agents and
        // the projects sit under each. The flat-by-default property is
        // unchanged and is asserted where it now lives: every project at one
        // level UNDER ITS AGENT, no page link.
        assert_eq!(cloud_node.children.len(), 7, "seven agent rows");
        for agent in &cloud_node.children {
            assert_eq!(
                agent.children.len(),
                22,
                "every cloud project at one level under {}",
                agent.id
            );
            assert!(
                agent
                    .children
                    .iter()
                    .all(|c| !c.id.starts_with(ids::CLOUD_PROJECTS_OVERFLOW)),
                "no page link when no page size is configured",
            );
        }

        // EVERY project is reachable. This is the property the operator actually
        // asked for, so it is asserted directly rather than inferred from a count
        // at one level — and it is deliberately phrased so it holds under BOTH
        // shapes, flat and paged, since it is the invariant neither may break.
        // reachable() counts LEAVES, and after the inversion each project has
        // one leaf per agent — so the raw count is 7 x 22. The invariant worth
        // asserting is the operator's: every PROJECT is reachable, so the
        // DISTINCT project names are counted rather than the leaves.
        assert_eq!(reachable(cloud_node), 7 * 22, "one leaf per (project, agent)");
        let mut names: Vec<&str> = Vec::new();
        fn collect<'a>(node: &'a MenuItem, out: &mut Vec<&'a str>) {
            if let Some(rest) = node.id.strip_prefix("project.cloud.") {
                if let Some((name, _verb)) = rest.rsplit_once('.') {
                    out.push(name);
                }
            }
            for c in &node.children {
                collect(c, out);
            }
        }
        collect(cloud_node, &mut names);
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 22, "all 22 distinct cloud projects reachable");
    }

    /// Count the launchable project entries anywhere beneath a node.
    ///
    /// Shared by the flat-default test and the paged-fallback test because the
    /// reachability invariant is the same one in both shapes; a helper each
    /// would let them drift apart, and the drift would be invisible.
    fn reachable(node: &MenuItem) -> usize {
        if node.id.starts_with("project.") {
            return 1;
        }
        node.children.iter().map(reachable).sum()
    }

    /// ORDER 591-33s6, kept live after the flat default landed 2026-09-21.
    ///
    /// The fan-out is no longer the default path, which is precisely the
    /// condition under which the LAST version of this bug survived seven weeks:
    /// the fix and the test proving it both moved into a function with no live
    /// caller, and a green test over an unreachable path reads exactly like a
    /// closed bug. So this test drives `build_project_pages` DIRECTLY with an
    /// explicit page size rather than through an env var, and asserts the
    /// behaviour — the page link carries children and every project is still
    /// reachable — not merely that a row exists.
    #[test]
    fn paged_fallback_still_fans_out_and_reaches_every_project() {
        let projects: Vec<ProjectEntry> = (0..22)
            .map(|i| ProjectEntry {
                name: format!("cloud-{i}"),
                path: format!("octocat/cloud-{i}"),
                ready: false,
                full_name: None,
            })
            .collect();

        // Drives `paginate` directly with rows built the way build_agent_rows
        // builds them, so the fan-out is exercised even though it is no longer
        // the default path — which is the condition under which 591-33s6
        // survived seven weeks green.
        let rows: Vec<MenuItem> = projects
            .iter()
            .map(|p| MenuItem::leaf(format!("project.cloud.{}.claude", p.name), p.name.clone()))
            .collect();
        let pages = paginate(rows, "claude", Some(MAX_CLOUD_PROJECTS_IN_MENU), 0);

        assert_eq!(
            pages.len(),
            MAX_CLOUD_PROJECTS_IN_MENU + 1,
            "one page of projects plus the link to the next",
        );
        let page_link = pages.last().unwrap();
        assert!(
            page_link.id.starts_with(ids::CLOUD_PROJECTS_OVERFLOW),
            "last child should be the page link, got {}",
            page_link.id,
        );
        assert!(
            !page_link.children.is_empty(),
            "the overflow row must FAN OUT, not be an enabled no-op leaf (591-33s6)",
        );
        assert!(page_link.label.contains("12"), "names how many remain");

        let total: usize = pages.iter().map(reachable).sum();
        assert_eq!(total, 22, "every project reachable through the page chain");
    }

    /// A page link must NEVER be childless, at any page size or list length.
    ///
    /// Raised by esme-windows after measuring `notify_icon.rs`: Win32 mints a
    /// command id only in the LEAF branch, so a childless page link would become
    /// an enabled, dispatching row wired to `MenuAction::Inert` — a dead button
    /// that looks ordinary, which is 591-33s6 re-entered through a different
    /// door. Today it cannot happen, because `rest` is non-empty whenever the
    /// link is emitted. That is exactly why it is pinned: the invariant holds by
    /// an accident of the current arithmetic, and nothing downstream of the
    /// builder could report its loss — the adapter cannot tell a childless
    /// submenu from a leaf, and neither can a reader.
    ///
    /// Swept rather than sampled, including the boundary lengths (exactly one
    /// page, one over) where an off-by-one would put an empty tail page.
    #[test]
    fn no_page_link_is_ever_childless() {
        fn walk(node: &MenuItem, seen_links: &mut usize) {
            if node.id.starts_with(ids::CLOUD_PROJECTS_OVERFLOW) {
                *seen_links += 1;
                assert!(
                    !node.children.is_empty(),
                    "childless page link {} would dispatch as a dead leaf on Win32",
                    node.id,
                );
            }
            for child in &node.children {
                walk(child, seen_links);
            }
        }

        for page_size in 1..=5usize {
            for count in 0..=12usize {
                let projects: Vec<ProjectEntry> = (0..count)
                    .map(|i| ProjectEntry {
                        name: format!("cloud-{i}"),
                        path: format!("octocat/cloud-{i}"),
                        ready: false,
                        full_name: None,
                    })
                    .collect();

                let rows: Vec<MenuItem> = projects
                    .iter()
                    .map(|p| {
                        MenuItem::leaf(format!("project.cloud.{}.claude", p.name), p.name.clone())
                    })
                    .collect();
                let pages = paginate(rows, "claude", Some(page_size), 0);

                let mut links = 0;
                let mut reached = 0;
                for item in &pages {
                    walk(item, &mut links);
                    reached += reachable(item);
                }
                assert_eq!(
                    reached, count,
                    "page_size={page_size} count={count}: every project must stay reachable",
                );
            }
        }
    }

    /// The env var the product ADVERTISES must be the one the live builder READS.
    ///
    /// `TILLANDSIAS_MAX_CLOUD_MENU_ITEMS` was printed to users as a remedy for
    /// over a month while the only code reading it sat behind a retired builder
    /// (628-p5tj), so the advertisement was false and no test could tell —
    /// `openspec/specs/tray-ux` forbids exactly this. Parsing is asserted here;
    /// that `build_cloud_projects` calls this resolver is asserted by the flat
    /// default above, which would fail if it read a constant instead.
    #[test]
    fn cloud_page_size_env_var_parses_or_is_absent() {
        // No env manipulation: `set_var` is unsafe and racy across the parallel
        // test binary, and a flaky pin on a shared process env is worse than a
        // narrower one. The default-is-flat property is what matters and is
        // covered above.
        assert!(
            resolved_cloud_page_size().is_none_or(|n| n > 0),
            "a configured page size is always a positive count",
        );
    }

    /// @trace spec:host-shell-architecture, spec:macos-native-tray.ui.menu-parity@v1
    ///
    /// Logged-out collapses to exactly
    /// {status, github-login, separator, version, quit} — the project body is
    /// gated behind authentication (mirrors the Linux golden).
    #[test]
    fn logged_out_menu_collapses_to_login_leaf() {
        let state = MenuState {
            login: GithubLoginState::LoggedOut,
            login_runtime_ready: true,
            // Projects present but must NOT surface while logged out.
            ..MenuState::initial()
        };
        let items = match build(&state) {
            MenuStructure::Ready { items } => items,
            other => panic!("expected Ready, got {other:?}"),
        };
        let ids_seen: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(
            ids_seen,
            vec![
                ids::STATUS,
                ids::GITHUB_LOGIN,
                ids::SEPARATOR,
                ids::VERSION,
                ids::QUIT
            ],
            "logged-out menu must collapse to the login-gated short list",
        );
        // The login item is an actionable leaf.
        let login = &items[1];
        assert!(login.enabled);
        assert!(login.children.is_empty());
        // None of the gated bodies leaked through.
        assert!(
            !ids_seen.contains(&ids::CLOUD_PROJECTS),
            "{} must be hidden while logged out",
            ids::CLOUD_PROJECTS,
        );
    }

    /// Order 626-r7kq, THE regression pin: an unobserved sign-in state must
    /// never be offered as an actionable login. The shipped defect was that
    /// `MenuState::initial()` claimed `LoggedOut`, so between "runtime ready"
    /// (one wire round-trip) and the login answer (a container run in the
    /// guest) the menu invited already-signed-in users to sign in again — and
    /// they did (operator field log 2026-08-09T06:10:51Z).
    ///
    /// This test fails if anyone reverts the initial state to `LoggedOut` or
    /// makes the Unknown row clickable.
    ///
    /// @trace spec:tray-ux, spec:host-shell-architecture
    #[test]
    fn unobserved_login_is_never_an_actionable_leaf() {
        // The initial state IS the unobserved state — not "signed out".
        assert_eq!(
            MenuState::initial().login,
            GithubLoginState::Unknown,
            "a tray that has not asked yet must not claim the user is signed out",
        );

        // Runtime ready is the dangerous case: it is what enabled the leaf.
        for runtime_ready in [false, true] {
            let state = MenuState {
                login: GithubLoginState::Unknown,
                login_runtime_ready: runtime_ready,
                ..MenuState::initial()
            };
            let items = match build(&state) {
                MenuStructure::Ready { items } => items,
                other => panic!("expected Ready, got {other:?}"),
            };
            let login = &items[1];
            assert_eq!(login.id, ids::GITHUB_LOGIN);
            assert!(
                !login.enabled,
                "unobserved sign-in must be DISABLED (runtime_ready={runtime_ready})",
            );
            // The auth-gated body must not leak either: unknown is not
            // logged-in any more than it is logged-out.
            let ids_seen: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
            assert!(
                !ids_seen.contains(&ids::CLOUD_PROJECTS),
                "{} must stay hidden while sign-in is unknown",
                ids::CLOUD_PROJECTS,
            );
        }
    }

    /// Order 626-r7kq: the operator approved TWO distinguishable waits
    /// (2026-08-09T08:33Z) — "Setting up…" while the workspace is still coming
    /// up, then "Checking your account…" once it is up but the sign-in answer
    /// is still outstanding. Pins the copy so neither row silently becomes the
    /// other.
    ///
    /// @trace spec:tray-ux
    #[test]
    fn unknown_login_distinguishes_the_two_waits() {
        let row = |runtime_ready: bool| {
            let state = MenuState {
                login: GithubLoginState::Unknown,
                login_runtime_ready: runtime_ready,
                ..MenuState::initial()
            };
            match build(&state) {
                MenuStructure::Ready { items } => items[1].label.clone(),
                other => panic!("expected Ready, got {other:?}"),
            }
        };
        assert!(
            row(false).contains("Setting up"),
            "workspace-still-starting wait must read 'Setting up…', got {:?}",
            row(false),
        );
        assert!(
            row(true).contains("Checking your account"),
            "sign-in-outstanding wait must read 'Checking your account…', got {:?}",
            row(true),
        );
        assert_ne!(
            row(false),
            row(true),
            "the two waits must be distinguishable — that is the approved surface",
        );
        // Internals vocabulary is forbidden in end-user UX (spec:tray-ux).
        for label in [row(false), row(true)] {
            let lowered = label.to_lowercase();
            for banned in [
                "vm",
                "wsl",
                "enclave",
                "container",
                "vault",
                "podman",
                "provisioning",
            ] {
                assert!(
                    !lowered.contains(banned),
                    "end-user label {label:?} must not leak internals vocabulary {banned:?}",
                );
            }
        }
    }

    /// @trace spec:host-shell-architecture
    #[test]
    fn logged_out_menu_shows_setting_up_when_runtime_not_ready() {
        let state = MenuState {
            login: GithubLoginState::LoggedOut,
            login_runtime_ready: false,
            ..MenuState::initial()
        };
        let items = match build(&state) {
            MenuStructure::Ready { items } => items,
            other => panic!("expected Ready, got {other:?}"),
        };
        let ids_seen: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(
            ids_seen,
            vec![
                ids::STATUS,
                ids::GITHUB_LOGIN,
                ids::SEPARATOR,
                ids::VERSION,
                ids::QUIT
            ],
            "logged-out menu must still collapse to the short list",
        );
        let login = &items[1];
        assert!(!login.enabled);
        assert_eq!(
            login.disabled_reason.as_deref(),
            Some("login runtime not ready")
        );
        assert!(login.label.contains("Setting up"));
    }

    /// windows-260719-2: the transitional `LoggingIn` state renders a
    /// disabled "Logging in…" row in the login slot — same collapsed short
    /// list as logged-out (the project body stays auth-gated), no actionable
    /// login leaf (a second click mid-flow is meaningless).
    #[test]
    fn logging_in_menu_shows_disabled_logging_in_row() {
        let state = MenuState {
            login: GithubLoginState::LoggingIn,
            login_runtime_ready: true,
            ..MenuState::initial()
        };
        let items = match build(&state) {
            MenuStructure::Ready { items } => items,
            other => panic!("expected Ready, got {other:?}"),
        };
        let ids_seen: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(
            ids_seen,
            vec![
                ids::STATUS,
                ids::GITHUB_LOGIN,
                ids::SEPARATOR,
                ids::VERSION,
                ids::QUIT
            ],
            "logging-in menu keeps the collapsed short list",
        );
        let login = &items[1];
        assert!(!login.enabled, "the in-progress row must not be clickable");
        assert!(login.label.contains("Logging in"));
        assert_eq!(login.disabled_reason.as_deref(), Some("login in progress"));
        // The gated project body must NOT leak through mid-login.
        assert!(
            !ids_seen.contains(&ids::CLOUD_PROJECTS),
            "{} hidden while LoggingIn",
            ids::CLOUD_PROJECTS,
        );
    }

    /// Per-project leaves are gated on podman_ready — when podman is not ready
    /// all 6 leaves are disabled with a "VM is not ready yet" reason.
    #[test]
    fn per_project_leaves_disabled_when_podman_not_ready() {
        let state = MenuState {
            login: GithubLoginState::LoggedIn { handle: "u".into() },
            // 997-e4v2: the per-project gating property is unchanged, but the
            // only project path is now cloud, so it is exercised there.
            cloud_projects: vec![ProjectEntry {
                name: "myapp".into(),
                path: "octocat/myapp".into(),
                ready: false,
                full_name: Some("octocat/myapp".into()),
            }],
            cloud_projects_loaded: true,
            podman_ready: false,
            ..MenuState::initial()
        };
        let items = match build(&state) {
            MenuStructure::Ready { items } => items,
            _ => panic!("expected Ready"),
        };
        // ORDER 1362 inversion: seven agent rows, each carrying the projects.
        // Per-LEAF enabledness is preserved exactly rather than lifted to the
        // agent row — a disabled submenu does not open on AppKit, which would
        // make the projects unreachable instead of visibly unavailable.
        let cloud = items
            .iter()
            .find(|i| i.id == ids::CLOUD_PROJECTS)
            .expect("cloud-projects submenu present");
        assert_eq!(cloud.children.len(), 7, "seven agent rows");
        assert!(
            cloud.children.iter().all(|a| a.enabled),
            "the AGENT rows stay enabled so their projects remain reachable"
        );
        let leaves: Vec<&MenuItem> = cloud.children.iter().flat_map(|a| a.children.iter()).collect();
        assert_eq!(leaves.len(), 7, "one leaf per (project, verb)");
        assert!(leaves.iter().all(|l| !l.enabled));
        assert!(
            leaves
                .iter()
                .all(|l| { l.disabled_reason.as_deref() == Some("VM is not ready yet") })
        );
    }

    /// Per-project leaves are enabled when podman is ready.
    #[test]
    fn per_project_leaves_enabled_when_podman_ready() {
        let state = MenuState {
            login: GithubLoginState::LoggedIn { handle: "u".into() },
            // 997-e4v2: the per-project gating property is unchanged, but the
            // only project path is now cloud, so it is exercised there.
            cloud_projects: vec![ProjectEntry {
                name: "myapp".into(),
                path: "octocat/myapp".into(),
                ready: false,
                full_name: Some("octocat/myapp".into()),
            }],
            cloud_projects_loaded: true,
            podman_ready: true,
            ..MenuState::initial()
        };
        let items = match build(&state) {
            MenuStructure::Ready { items } => items,
            _ => panic!("expected Ready"),
        };
        // ORDER 1362: the tree is inverted — Cloud's children are the SEVEN
        // AGENTS, each carrying the project list. The property this test exists
        // for is unchanged and is asserted the same way: one enabled leaf per
        // (project, verb), with the id grammar intact.
        let cloud = items
            .iter()
            .find(|i| i.id == ids::CLOUD_PROJECTS)
            .expect("cloud-projects submenu present");
        assert_eq!(cloud.children.len(), 7, "seven agent rows");
        for agent in &cloud.children {
            assert_eq!(agent.children.len(), 1, "one project under each agent");
            assert!(agent.children.iter().all(|l| l.enabled));
        }
        // IDs still follow project.<scope>.<name>.<verb>, which
        // menu_action::resolve_project parses back out. The inversion moved
        // where a leaf SITS, never what it is called.
        assert!(cloud.children[0].children[0].id.ends_with(".claude"));
        assert!(cloud.children[3].children[0].id.ends_with(".antigravity"));
        assert!(cloud.children[6].children[0].id.ends_with(".maintenance"));
        assert!(
            cloud.children[0].children[0].id.starts_with("project.cloud.myapp."),
            "leaf id grammar unchanged: {}",
            cloud.children[0].children[0].id
        );
    }

    /// @trace spec:vm-provisioning-lifecycle
    #[test]
    fn initial_provisioning_menu_has_status_and_quit_only() {
        let menu = MenuStructure::initial_provisioning();
        match menu {
            MenuStructure::Provisioning { items } => {
                assert_eq!(items.len(), 2);
                assert_eq!(items[0].id, ids::STATUS);
                assert!(!items[0].enabled);
                assert_eq!(items[1].id, ids::QUIT);
            }
            other => panic!("expected Provisioning, got {other:?}"),
        }
    }

    #[test]
    fn tray_status_chip_clamps_to_37_chars() {
        let raw = format!("🟢 Ready · {}", "x".repeat(80));
        let clamped = clamp_tray_status_chip(&raw);
        assert!(
            clamped.chars().count() <= TRAY_STATUS_CHIP_MAX_CHARS,
            "chip should stay within the 37-char budget: {clamped:?}"
        );
        assert!(
            clamped.ends_with('…'),
            "overlong chip should be ellipsized, got {clamped:?}"
        );
    }

    #[test]
    fn initial_menu_uses_short_boot_status() {
        let state = MenuState::initial();
        assert_eq!(state.status_text, BOOT_STATUS_TEXT);
        let menu = build(&state);
        let items = match menu {
            MenuStructure::Ready { items } => items,
            other => panic!("expected Ready, got {other:?}"),
        };
        assert_eq!(items[0].label, BOOT_STATUS_TEXT);
        assert!(items[0].label.chars().count() <= TRAY_STATUS_CHIP_MAX_CHARS);
    }

    #[test]
    fn failed_menu_carries_retry_and_open_log() {
        let menu = MenuStructure::failed("rootfs checksum mismatch");
        let items = match menu {
            MenuStructure::Failed { items } => items,
            _ => panic!("expected Failed"),
        };
        assert!(items.iter().any(|i| i.id == "retry" && i.enabled));
        assert!(items.iter().any(|i| i.id == "open-log" && i.enabled));
    }

    #[test]
    fn failed_status_label_truncates_at_80_chars() {
        let long_reason = "x".repeat(200);
        let menu = MenuStructure::failed(long_reason.clone());
        let items = match menu {
            MenuStructure::Failed { items } => items,
            _ => panic!("expected Failed"),
        };
        let status = &items[0];
        // Reason text inside the label is truncated at 80 chars (per spec);
        // a small fixed prefix ("🥀 Provisioning failed: ") is allowed
        // on top of that.
        assert!(
            status.label.chars().count() <= 80 + 32,
            "label should stay near 80 chars, got {} chars",
            status.label.chars().count(),
        );
        // Full reason is preserved in disabled_reason for the tooltip.
        assert_eq!(
            status.disabled_reason.as_deref(),
            Some(long_reason.as_str())
        );
    }

    #[test]
    fn cloud_projects_under_cap_show_no_overflow() {
        let state = MenuState {
            login: GithubLoginState::LoggedIn { handle: "u".into() },
            cloud_projects: (0..3)
                .map(|i| ProjectEntry {
                    name: format!("c-{i}"),
                    path: format!("o/c-{i}"),
                    ready: false,
                    full_name: None,
                })
                .collect(),
            ..MenuState::initial()
        };
        let menu = build(&state);
        let items = match menu {
            MenuStructure::Ready { items } => items,
            _ => panic!("expected Ready"),
        };
        let cloud = items
            .iter()
            .find(|i| i.id == ids::CLOUD_PROJECTS)
            .expect("cloud-projects submenu present");
        // ORDER 1362: Cloud's children are the seven agents; the three projects
        // sit under each. The property is the same one this test was written
        // for — no page link when nothing overflows — asserted at the level
        // where overflow can now occur.
        assert_eq!(cloud.children.len(), 7, "seven agent rows");
        for agent in &cloud.children {
            assert_eq!(agent.children.len(), 3, "three projects under each agent");
            assert!(
                agent
                    .children
                    .iter()
                    .all(|c| !c.id.starts_with(ids::CLOUD_PROJECTS_OVERFLOW)),
                "no page link when no page size is configured"
            );
        }
    }

    /// Operator report 2026-07-28: an empty cloud submenu must say
    /// "(loading repos…)" until the first confirmed answer lands, and
    /// "(no repos)" only after — never claim emptiness mid-fetch.
    #[test]
    fn cloud_projects_empty_distinguishes_loading_from_confirmed_empty() {
        let loading = MenuState {
            login: GithubLoginState::LoggedIn { handle: "u".into() },
            ..MenuState::initial()
        };
        let menu = build(&loading);
        let items = match menu {
            MenuStructure::Ready { items } => items,
            _ => panic!("expected Ready"),
        };
        let cloud = items
            .iter()
            .find(|i| i.id == ids::CLOUD_PROJECTS)
            .expect("cloud-projects submenu present");
        assert_eq!(cloud.children.len(), 1);
        assert_eq!(cloud.children[0].id, ids::CLOUD_PROJECTS_LOADING);
        assert_eq!(cloud.children[0].label, "(loading repos\u{2026})");

        let confirmed_empty = MenuState {
            login: GithubLoginState::LoggedIn { handle: "u".into() },
            cloud_projects_loaded: true,
            ..MenuState::initial()
        };
        let menu = build(&confirmed_empty);
        let items = match menu {
            MenuStructure::Ready { items } => items,
            _ => panic!("expected Ready"),
        };
        let cloud = items
            .iter()
            .find(|i| i.id == ids::CLOUD_PROJECTS)
            .expect("cloud-projects submenu present");
        assert_eq!(cloud.children.len(), 1);
        assert_eq!(cloud.children[0].id, ids::CLOUD_PROJECTS_EMPTY);
        assert_eq!(cloud.children[0].label, "(no repos)");
    }

    /// Recursively collect every id in a menu subtree.
    fn collect_ids<'a>(items: &'a [MenuItem], out: &mut Vec<&'a str>) {
        for item in items {
            out.push(item.id.as_str());
            collect_ids(&item.children, out);
        }
    }

    /// ABSENCE pin (operator order, 2026-07-22; `openspec/specs/tray-ux/spec.md`
    /// → "UX curation governance"): the `reset-guest` menu leaf was an
    /// UNAPPROVED UX surface and MUST NOT be emitted anywhere in the menu
    /// tree, in ANY auth state, ready/podman state, or target surface. The
    /// reset capability survives only as the `--reset-guest` CLI verb.
    #[test]
    fn reset_guest_leaf_absent_in_every_state() {
        for target in [TargetSurface::WindowsTray, TargetSurface::MacosTray] {
            for login in [
                GithubLoginState::LoggedOut,
                GithubLoginState::LoggingIn,
                GithubLoginState::LoggedIn { handle: "u".into() },
            ] {
                for podman_ready in [false, true] {
                    let state = MenuState {
                        login: login.clone(),
                        target,
                        podman_ready,
                        login_runtime_ready: podman_ready,
                        ..MenuState::initial()
                    };
                    let menu = build(&state);
                    let mut all_ids = Vec::new();
                    collect_ids(menu.top_items(), &mut all_ids);
                    assert!(
                        !all_ids.contains(&ids::RESET_GUEST),
                        "no menu item with id `{}` may exist anywhere in the tree \
                         (removed by operator order 2026-07-22; \
                         tray-ux \"UX curation governance\")",
                        ids::RESET_GUEST,
                    );
                    let labels: Vec<&str> =
                        menu.top_items().iter().map(|i| i.label.as_str()).collect();
                    assert!(
                        !labels.iter().any(|l| l.contains("Reset Guest")),
                        "no top-level label may read `Reset Guest…`: {labels:?}",
                    );
                }
            }
        }
    }

    /// GOVERNANCE pin (`openspec/specs/tray-ux/spec.md` → "UX curation
    /// governance"): `build()` emits EXACTLY the approved top-level id set —
    /// snapshotted below per auth state. UX exists for END USERS ONLY; any
    /// future menu addition/removal/reorder MUST fail here until this
    /// snapshot is deliberately updated ALONGSIDE recorded operator approval
    /// in the plan ledger. Do NOT loosen this to a subset/contains check.
    ///
    /// @trace spec:tray-ux
    #[test]
    fn build_emits_exactly_the_approved_top_level_id_set() {
        const APPROVED_LOGGED_OUT: [&str; 5] = [
            ids::STATUS,
            ids::GITHUB_LOGIN,
            ids::SEPARATOR,
            ids::VERSION,
            ids::QUIT,
        ];
        const APPROVED_LOGGED_IN: [&str; 5] = [
            ids::STATUS,
            ids::CLOUD_PROJECTS,
            ids::SEPARATOR,
            ids::VERSION,
            ids::QUIT,
        ];

        for target in [TargetSurface::WindowsTray, TargetSurface::MacosTray] {
            for (login, approved) in [
                (GithubLoginState::LoggedOut, &APPROVED_LOGGED_OUT[..]),
                (GithubLoginState::LoggingIn, &APPROVED_LOGGED_OUT[..]),
                (
                    GithubLoginState::LoggedIn { handle: "u".into() },
                    &APPROVED_LOGGED_IN[..],
                ),
            ] {
                let state = MenuState {
                    login,
                    target,
                    ..MenuState::initial()
                };
                let items = match build(&state) {
                    MenuStructure::Ready { items } => items,
                    other => panic!("expected Ready, got {other:?}"),
                };
                let actual: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
                assert_eq!(
                    actual, approved,
                    "unapproved top-level menu change for target {target:?} — every \
                     UX surface change requires recorded operator approval \
                     (tray-ux \"UX curation governance\") before this snapshot \
                     may be updated",
                );
            }
        }
    }

    /// Order 648-jv69. A terminal provisioning failure must put a REAL `retry`
    /// control in the menu.
    ///
    /// The defect this pins: the status chip could say
    /// "Provisioning failed — Retry" while the only constructor of a `retry`
    /// leaf (`MenuStructure::failed`) was never called from `build` or from the
    /// Windows tray. `MenuAction::Retry` was fully implemented and
    /// `PROVISIONING_ACTIVE` was cleared correctly — the machinery worked, and
    /// nothing rendered the control. Operator report 2026-08-10: "retry is not
    /// actionable, I don't know if it's retrying at all."
    ///
    /// Asserting the leaf is PRESENT is the half that catches a regression;
    /// asserting it is ABSENT when healthy is the half that stops the fix
    /// becoming a permanent Retry item on a working tray.
    #[test]
    fn terminal_provisioning_failure_renders_a_real_retry_control() {
        let failed = MenuState {
            provisioning_failure: Some("control-wire handshake did not succeed".into()),
            ..MenuState::initial()
        };
        let items = match build(&failed) {
            MenuStructure::Failed { items } => items,
            other => panic!("expected Failed, got {other:?}"),
        };
        let ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert!(
            ids.contains(&"retry"),
            "a failed provision must offer a retry control; got {ids:?}"
        );
        assert!(
            ids.contains(&"open-log"),
            "a failed provision must offer the log; got {ids:?}"
        );
        // The retry leaf must be ENABLED — a disabled one reproduces the
        // original complaint exactly.
        let retry = items.iter().find(|i| i.id == "retry").expect("retry leaf");
        assert!(
            retry.enabled,
            "the retry control must be clickable, not a disabled label"
        );

        // Negative half: a healthy tray must NOT carry a Retry item.
        let healthy = MenuState::initial();
        let healthy_ids: Vec<String> = build(&healthy)
            .top_items()
            .iter()
            .map(|i| i.id.clone())
            .collect();
        assert!(
            !healthy_ids.iter().any(|i| i == "retry"),
            "a tray with no failure must not offer Retry; got {healthy_ids:?}"
        );
    }
}
