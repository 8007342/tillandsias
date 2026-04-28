//! Pre-built tray menu — no disabled placeholders, dynamic top region.
//!
//! Implements the menu shape defined by `tray-app`. The bottom row
//! (Language ▸, signature, Quit) is built once at app start and never
//! touched again — keeping it stable defeats libappindicator's
//! blank-label cache bug. Everything above the divider — contextual
//! status line, sign-in action, running-stack submenus, Projects ▸,
//! Remote Projects ▸ — is appended and removed via `Menu::insert` /
//! `Menu::remove` driven by `apply_state`.
//!
//! ```text
//! Authed (with one running forge):
//!   my-project 🌺 ▸          ┐
//!   Projects ▸               │ dynamic region
//!   Remote Projects ▸        ┘
//!   ──────── separator ─────────
//!   Language ▸               ┐
//!   v0.1.169.225 — by Tlatoāni │ static row (built once)
//!   Quit Tillandsias         ┘
//! ```
//!
//! @trace spec:tray-app

use std::path::PathBuf;
use std::sync::Mutex;

use tauri::menu::{
    IsMenuItem, Menu, MenuBuilder, MenuItem, MenuItemBuilder, MenuItemKind,
    PredefinedMenuItem, Submenu, SubmenuBuilder,
};
use tauri::{AppHandle, Runtime};
use tracing::{debug, warn};

use tillandsias_core::config::load_global_config;
use tillandsias_core::project::Project;
use tillandsias_core::state::{BuildStatus, ContainerType, RemoteRepoInfo, TrayState};

use crate::github_health::CredentialHealth;
use crate::i18n;

// ─── Menu IDs ────────────────────────────────────────────────────────────────

/// Stable IDs used by the tray menu.
pub mod ids {
    pub const QUIT: &str = "tm.quit";
    pub const SIGN_IN: &str = "tm.sign-in";
    pub const STATUS_LINE: &str = "tm.status";
    pub const SIGNATURE: &str = "tm.signature";
    pub const PROJECTS: &str = "tm.projects";
    pub const REMOTE_PROJECTS: &str = "tm.remote-projects";
    pub const LANGUAGE: &str = "tm.language";

    /// Build "tm.launch:<project_path>" — full project_path encoded.
    pub fn launch(project_path: &std::path::Path) -> String {
        format!("tm.launch:{}", project_path.display())
    }

    /// Build "tm.maint:<project_path>".
    pub fn maint(project_path: &std::path::Path) -> String {
        format!("tm.maint:{}", project_path.display())
    }

    /// Build "tm.clone:<full_name>\t<name>".
    pub fn clone_repo(full_name: &str, name: &str) -> String {
        format!("tm.clone:{full_name}\t{name}")
    }

    /// Build "tm.lang:<code>" — language selector.
    pub fn select_lang(code: &str) -> String {
        format!("tm.lang:{code}")
    }

    /// Parse a tray-menu ID into (action, payload) if recognised.
    pub fn parse(id: &str) -> Option<(&str, &str)> {
        let stripped = id.strip_prefix("tm.")?;
        Some(stripped.split_once(':').unwrap_or((stripped, "")))
    }
}

// ─── Stage state machine ─────────────────────────────────────────────────────

/// One of the five lifecycle stages. The dynamic region's composition
/// is derived from `(stage, state)` together — see
/// `docs/cheatsheets/tray-state-machine.md` for the projection.
///
/// @trace spec:tray-app, spec:tray-progress-and-icon-states
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Stage {
    Booting,
    Ready,
    NoAuth,
    Authed,
    NetIssue,
    /// One or more infrastructure components failed in a way that
    /// prevents normal operation. Menu collapses to a single
    /// `🥀 Unhealthy environment` item plus signature + Quit. Detail of
    /// what failed lives in the log, not the menu.
    /// @trace spec:tray-progress-and-icon-states
    Unhealthy,
}

/// Map a `CredentialHealth` probe result to a `Stage`. The mapping
/// matches the table in `docs/cheatsheets/tray-state-machine.md`.
///
/// @trace spec:tray-app
pub fn stage_from_health(health: &CredentialHealth) -> Stage {
    match health {
        CredentialHealth::Authenticated => Stage::Authed,
        CredentialHealth::CredentialMissing | CredentialHealth::CredentialInvalid => Stage::NoAuth,
        CredentialHealth::GithubUnreachable { .. } => Stage::NetIssue,
    }
}

// ─── Maximum tool emojis in the running-stack label ──────────────────────────

/// Cap the number of `Maintenance` tool emojis displayed next to a
/// running stack's label. Beyond this, additional emojis are dropped
/// (no overflow indicator) per the spec — tray labels are width-
/// constrained on Linux indicators and macOS menu bars.
///
/// @trace spec:tray-app
const MAX_TOOL_EMOJIS_IN_LABEL: usize = 5;

// ─── TrayMenu ────────────────────────────────────────────────────────────────

/// Cache key for the dynamic region's rebuild gate. Equality means
/// nothing observable changed — the rebuild is skipped.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct DynamicCacheKey {
    status_text: Option<String>,
    sign_in_visible: bool,
    /// `(label, project_name)` for each running stack, in render order.
    running_stacks: Vec<(String, String)>,
    /// Local project names + a per-project running-state flag (so the
    /// "no Maintenance child when forge is down" rule invalidates the
    /// cache when a forge starts/stops).
    local_projects: Vec<(String, bool)>,
    /// Remote project names available to clone (those not present locally).
    remote_only_projects: Vec<String>,
}

/// Owner of every tray menu handle. Static items (signature row,
/// Language ▸, Quit) are built once at setup. Dynamic items above
/// the divider are owned by `apply_state` — they are appended on
/// demand via `Menu::insert(0, …)`.
///
/// @trace spec:tray-app
pub struct TrayMenu<R: Runtime> {
    pub root: Menu<R>,

    // Static row — never rebuilt after setup.
    separator_top: PredefinedMenuItem<R>,
    language: Submenu<R>,
    signature: MenuItem<R>,
    quit: MenuItem<R>,

    // Dynamic-region cache key.
    cache: Mutex<DynamicCacheKey>,
}

impl<R: Runtime> TrayMenu<R> {
    /// Pre-build the static row and return the assembled `Menu`. The
    /// dynamic region above the separator is empty at this point —
    /// the first `apply_state` call will populate it.
    ///
    /// @trace spec:tray-app, spec:tray-projects-rename
    pub fn new(app: &AppHandle<R>) -> tauri::Result<Self> {
        // The Language ▸ submenu is BUILT but NOT appended to the menu —
        // i18n is hard-defaulted to "en" until the translation pipeline
        // is fixed. Keeping the handle alive means re-enabling later is
        // a one-line change (re-add `.item(&language)` below).
        // @tombstone superseded:tray-projects-rename — kept for three
        // releases (until 0.1.169.230). When re-enabling, also flip the
        // hard-coded "en" in i18n::detect_locale back to OS detection.
        let language = build_language_submenu(app)?;

        let signature = MenuItemBuilder::with_id(ids::SIGNATURE, signature_label())
            .enabled(false)
            .build(app)?;

        let quit = MenuItemBuilder::with_id(ids::QUIT, i18n::t("menu.quit")).build(app)?;

        let separator_top = PredefinedMenuItem::separator(app)?;

        let root = MenuBuilder::new(app)
            .item(&separator_top)
            // @tombstone superseded:tray-projects-rename — Language ▸
            // surfaced 17 locales but only en/de/es had translations,
            // confusing users. Re-enable when i18n catches up:
            // .item(&language)
            .item(&signature)
            .item(&quit)
            .build()?;

        Ok(Self {
            root,
            separator_top,
            language,
            signature,
            quit,
            cache: Mutex::new(DynamicCacheKey::default()),
        })
    }

    /// Apply the latest `(stage, state)` projection to the dynamic
    /// region. Skips the rebuild if the cache key is unchanged.
    ///
    /// The dynamic region's composition (top → bottom):
    ///
    /// 1. optional contextual status line (disabled, single MenuItem)
    /// 2. optional `🔑 Sign in to GitHub` (enabled action)
    /// 3. running-stack submenus, sorted by project name
    /// 4. optional `Projects ▸` (only if `state.projects` non-empty)
    /// 5. optional `Remote Projects ▸` (only if `remote_only` non-empty)
    ///
    /// All of (1)–(5) are appended above `separator_top`. The static
    /// row at and below the separator is untouched.
    ///
    /// @trace spec:tray-app
    pub fn apply_state(
        &self,
        app: &AppHandle<R>,
        stage: Stage,
        state: &TrayState,
    ) -> tauri::Result<()> {
        let status = status_text(state, stage);
        let sign_in_visible = matches!(stage, Stage::NoAuth | Stage::NetIssue);
        let stacks = running_stacks(state);
        let stacks_key: Vec<(String, String)> = stacks
            .iter()
            .map(|s| (s.label(), s.project_name.clone()))
            .collect();
        let local: Vec<(String, bool)> = {
            let mut v: Vec<(String, bool)> = state
                .projects
                .iter()
                .map(|p| {
                    let running = state.running.iter().any(|c| {
                        c.project_name == p.name
                            && matches!(c.container_type, ContainerType::OpenCodeWeb)
                    });
                    (p.name.clone(), running)
                })
                .collect();
            v.sort_by(|a, b| a.0.to_lowercase().cmp(&b.0.to_lowercase()));
            v
        };
        let remote_only_names = remote_only_project_names(state);

        let key = DynamicCacheKey {
            status_text: status.clone(),
            sign_in_visible,
            running_stacks: stacks_key,
            local_projects: local.clone(),
            remote_only_projects: remote_only_names.clone(),
        };

        {
            let cache = self.cache.lock().unwrap();
            if *cache == key {
                return Ok(());
            }
        }

        // Wipe everything above `separator_top`. The static row at and
        // below the separator stays put.
        let existing = self.root.items()?;
        for kind in existing {
            // Stop at the static separator — it's the boundary between
            // dynamic (above) and static (at/below).
            if kind_id(&kind).as_deref() == Some(self.separator_top.id().as_ref()) {
                break;
            }
            let _ = remove_kind(&self.root, &kind);
        }

        // Build the dynamic items in render order (top → bottom).
        // We insert at position 0 each time, so we must build in
        // REVERSE so the final order is correct.
        let mut idx = 0usize;

        // @trace spec:tray-progress-and-icon-states
        // Unhealthy stage collapses the entire dynamic region to a single
        // disabled `🥀 Unhealthy environment` row. The detail of which
        // subsystem failed lives in the log, not the menu — single-line
        // surface per the user's "single line, detail in logs" preference.
        if matches!(stage, Stage::Unhealthy) {
            let item = MenuItemBuilder::with_id(
                ids::STATUS_LINE,
                i18n::t("menu.unhealthy_environment"),
            )
            .enabled(false)
            .build(app)?;
            self.root.insert(&item as &dyn IsMenuItem<R>, idx)?;

            // Commit the cache key and return — Unhealthy hides
            // sign-in, running stacks, and project submenus.
            let mut cache = self.cache.lock().unwrap();
            *cache = key;
            debug!(spec = "tray-progress-and-icon-states", "Dynamic region applied (Unhealthy)");
            return Ok(());
        }

        if let Some(text) = status.as_deref() {
            let item = MenuItemBuilder::with_id(ids::STATUS_LINE, text)
                .enabled(false)
                .build(app)?;
            self.root.insert(&item as &dyn IsMenuItem<R>, idx)?;
            idx += 1;
        }

        if sign_in_visible {
            let item =
                MenuItemBuilder::with_id(ids::SIGN_IN, i18n::t("menu.sign_in_github")).build(app)?;
            self.root.insert(&item as &dyn IsMenuItem<R>, idx)?;
            idx += 1;
        }

        for stack in &stacks {
            let sub = build_running_stack_submenu(app, stack)?;
            self.root.insert(&sub as &dyn IsMenuItem<R>, idx)?;
            idx += 1;
        }

        // Local Projects ▸ — only if at least one local project exists.
        if !local.is_empty() {
            let projects = SubmenuBuilder::with_id(app, ids::PROJECTS, i18n::t("menu.projects"));
            let mut projects = projects;
            for (name, running) in &local {
                if let Some(project) = state.projects.iter().find(|p| &p.name == name) {
                    let sub = build_local_project_submenu(app, project, *running)?;
                    projects = projects.item(&sub);
                }
            }
            let projects = projects.build()?;
            self.root.insert(&projects as &dyn IsMenuItem<R>, idx)?;
            idx += 1;
        }

        // Remote Projects ▸ — only if at least one uncloned remote.
        if !remote_only_names.is_empty() {
            let remote = SubmenuBuilder::with_id(
                app,
                ids::REMOTE_PROJECTS,
                // @trace spec:tray-projects-rename
                i18n::t("menu.cloud_projects"),
            );
            let mut remote = remote;
            for repo_name in &remote_only_names {
                if let Some(repo) = state.remote_repos.iter().find(|r| &r.name == repo_name) {
                    let sub = build_remote_project_submenu(app, repo)?;
                    remote = remote.item(&sub);
                }
            }
            let remote = remote.build()?;
            self.root.insert(&remote as &dyn IsMenuItem<R>, idx)?;
        }

        let _ = idx; // last write may not increment; silence future drift

        // Commit the cache key only after the rebuild succeeds.
        let mut cache = self.cache.lock().unwrap();
        *cache = key;
        debug!(spec = "tray-app", "Dynamic region applied");
        Ok(())
    }

    /// Refresh static labels — called after a language change so the
    /// new locale takes effect without rebuilding the tree. The dynamic
    /// region's labels are recomputed on every `apply_state` pass, so
    /// they pick up the new locale on the next event-loop tick.
    ///
    /// @trace spec:tray-app
    pub fn refresh_static_labels(&self) {
        let _ = self.signature.set_text(signature_label());
        let _ = self.language.set_text(i18n::t("menu.language"));
        let _ = self.quit.set_text(i18n::t("menu.quit"));
    }
}

// ─── Status text — pure function ─────────────────────────────────────────────

/// Map a build chip's image_name to its subsystem emoji + sort order.
/// Returns `None` for unrecognised names — graceful degradation when a
/// future chip is added without updating this table.
///
/// Sort order is the deterministic accumulation order in the chip:
/// browser runtime → enclave → proxy → inference → router → git mirror → forge.
/// Lower order = appears earlier in the chip prefix.
///
/// Match is substring-based against the localized chip name. The localized
/// English keys live in `locales/en.toml` `[menu.build]`. Other locales
/// will return `None` (no emoji prefix) until they're translated; the chip
/// still works, just without the emoji decoration.
///
/// @trace spec:tray-progress-and-icon-states, spec:tray-app
/// @cheatsheet runtime/forge-container.md
fn subsystem_emoji_and_order(image_name: &str) -> Option<(u8, &'static str)> {
    // Match longest substrings first to avoid e.g. "Code Mirror" matching
    // both "Code" and "Mirror" candidates. Returns (sort_order, emoji).
    if image_name.contains("Browser runtime") {
        Some((1, "\u{1F9ED}")) // 🧭 compass
    } else if image_name.contains("Enclave") {
        Some((2, "\u{1F578}\u{FE0F}")) // 🕸️ spider web
    } else if image_name.contains("Proxy") {
        Some((3, "\u{1F6E1}\u{FE0F}")) // 🛡️ shield
    } else if image_name.contains("Inference") {
        Some((4, "\u{1F9E0}")) // 🧠 brain
    } else if image_name.contains("Router") {
        Some((5, "\u{1F500}")) // 🔀 shuffle (routing)
    } else if image_name.contains("Code Mirror") || image_name.contains("Git Service") {
        Some((6, "\u{1FA9E}")) // 🪞 mirror
    } else if image_name.contains("Development Environment")
        || image_name.contains("Forge")
        || image_name.contains("Updated Forge")
    {
        Some((7, "\u{1F528}")) // 🔨 hammer
    } else {
        None
    }
}

/// Compose the additive status chip. Returns `None` when nothing is
/// in-flight, no recent completion is in the 2-second flash window, and
/// the stage is healthy (Authed without infra failure).
///
/// Chip shape (in order):
/// 1. `📋` (clipboard / checklist) constant prefix — "this is a checklist
///    in flight". Reserved emoji `✅` is for terminal "all complete" state
///    only; it must never appear at the front of the chip.
/// 2. Per-completed-subsystem emoji, in stable order (compass → web →
///    shield → brain → shuffle → mirror → hammer).
/// 3. The latest action text: `Building <name> …` while building,
///    `<name> OK` for the 2-second flash after completion of an
///    individual subsystem.
/// 4. When ALL infrastructure subsystems for the current attach have
///    completed, a final `✅ Environment ready` flash appears
///    (`📋🧭🕸️🛡️🧠🔀 ✅ Environment ready`) for 2 seconds, then the
///    chip is removed.
/// 5. `· GitHub unreachable — using cached list` appended on `Stage::NetIssue`.
///
/// Failure transitions the menu to `Stage::Unhealthy` whose label
/// (`🥀 Unhealthy environment`) is rendered as a different menu item, NOT
/// in the chip — so this function returns `None` for Unhealthy and the
/// caller renders the alternative.
///
/// @trace spec:tray-progress-and-icon-states, spec:tray-app
/// @cheatsheet runtime/forge-container.md
///
/// @tombstone superseded:tray-progress-and-icon-states — kept for three
/// releases (until 0.1.169.232). Prior shapes were:
///   1. Comma-joined fragment list (`Building Forge… · GitHub unreachable …`)
///      replaced by the additive emoji chip.
///   2. `✅` as the constant prefix — wrong: ✅ is reserved for the
///      terminal "Environment ready" state. Replaced by `📋` (clipboard)
///      to make in-flight vs complete visually distinct.
pub fn status_text(state: &TrayState, stage: Stage) -> Option<String> {
    use std::time::Duration;
    const READY_FLASH: Duration = Duration::from_secs(2);

    // Unhealthy stage doesn't use the chip — caller renders the
    // 🥀 menu item separately.
    if matches!(stage, Stage::Unhealthy) {
        return None;
    }

    // Collect completed subsystems (any Completed build, regardless of
    // age — once a subsystem is up its emoji stays in the chip prefix).
    let mut completed_emojis: Vec<(u8, &'static str)> = state
        .active_builds
        .iter()
        .filter(|b| matches!(b.status, BuildStatus::Completed))
        .filter_map(|b| subsystem_emoji_and_order(&b.image_name))
        .collect();
    completed_emojis.sort_by_key(|(order, _)| *order);
    completed_emojis.dedup_by_key(|(order, _)| *order);

    // Build the constant prefix: 📋 then accumulated subsystem emojis.
    // 📋 (clipboard) signals "checklist in flight". ✅ is reserved for
    // the terminal "Environment ready" flash only.
    let mut prefix = String::from("\u{1F4CB}"); // 📋
    for (_, emoji) in &completed_emojis {
        prefix.push_str(emoji);
    }

    // Find the current action: latest in-progress build, OR latest
    // completion within the 2-second flash window. Both tail the prefix.
    let in_progress: Vec<&str> = state
        .active_builds
        .iter()
        .filter(|b| matches!(b.status, BuildStatus::InProgress))
        .map(|b| b.image_name.as_str())
        .collect();

    // The "Environment ready" terminal flash fires when the LAST piece
    // of infrastructure (the router — sort_order 5) has completed and
    // every other infrastructure subsystem also completed AND nothing is
    // in flight. This produces the canonical `📋🧭🕸️🛡️🧠🔀 ✅ Environment
    // ready` flash for 2s before the chip clears.
    //
    // We detect "all infrastructure ready" by: in_progress is empty AND
    // completed_emojis contains the router emoji (sort_order 5). The
    // forge + git-mirror are PER-attach not per-launch so they're
    // intentionally NOT in this gate (they appear in their own per-attach
    // chip cycle).
    let infra_all_done_recent = in_progress.is_empty()
        && completed_emojis.iter().any(|(o, _)| *o == 5)
        && state
            .active_builds
            .iter()
            .filter(|b| matches!(b.status, BuildStatus::Completed))
            .filter(|b| subsystem_emoji_and_order(&b.image_name).map(|(o, _)| o == 5).unwrap_or(false))
            .any(|b| {
                b.completed_at
                    .map(|t| t.elapsed() < READY_FLASH)
                    .unwrap_or(false)
            });

    let action: Option<String> = if in_progress.len() == 1 {
        Some(i18n::tf(
            "menu.status.building_one",
            &[("image", in_progress[0])],
        ))
    } else if in_progress.len() > 1 {
        Some(i18n::tf(
            "menu.status.building_many",
            &[("images", &in_progress.join(", "))],
        ))
    } else if infra_all_done_recent {
        // Terminal flash: replace per-subsystem "X OK" with the
        // canonical "✅ Environment ready" for 2s before chip clears.
        Some(i18n::t("menu.status.environment_ready").to_string())
    } else {
        // No in-flight builds — check for a completion within the flash
        // window so the user sees `… <X> OK` for ~2 seconds before the
        // chip clears.
        state
            .active_builds
            .iter()
            .filter(|b| matches!(b.status, BuildStatus::Completed))
            .filter(|b| {
                b.completed_at
                    .map(|t| t.elapsed() < READY_FLASH)
                    .unwrap_or(false)
            })
            .last()
            .map(|b| i18n::tf("menu.status.ready_one", &[("image", &b.image_name)]))
    };

    // Decide whether to render the chip at all.
    // - Always render while a build is in progress.
    // - Render during the 2 s flash window after the last completion.
    // - Render the verifying-environment baseline if we have no completed
    //   subsystems yet AND the stage is Booting (early init).
    // - On NetIssue, render at minimum the GitHub-unreachable suffix.
    let netissue = matches!(stage, Stage::NetIssue);

    let mut text = match (action.as_deref(), completed_emojis.is_empty(), stage) {
        (Some(act), _, _) => {
            // Always show 📋 + completed-emojis + action text
            format!("{prefix} {act}")
        }
        (None, true, Stage::Booting) => {
            // Cold start, nothing built yet
            format!("{prefix} {}", i18n::t("menu.status.verifying_environment"))
        }
        (None, _, _) if netissue => {
            // Authed with cached list; only network message
            String::new() // filled below
        }
        (None, true, _) => {
            // Idle and never built anything — no chip
            return None;
        }
        (None, false, _) if !netissue => {
            // Idle and the flash window has expired — drop the chip
            return None;
        }
        (None, _, _) => String::new(), // unreachable but keeps match exhaustive
    };

    if netissue {
        let sep = i18n::t("menu.status.separator").to_string();
        let net_msg = i18n::t("menu.status.github_unreachable").to_string();
        if text.is_empty() {
            text = format!("{prefix} {net_msg}");
        } else {
            text.push_str(&sep);
            text.push_str(&net_msg);
        }
    }

    if text.is_empty() { None } else { Some(text) }
}

// ─── Running stacks — pure function ──────────────────────────────────────────

/// One running per-project stack — the data needed to render a
/// top-level submenu for it.
///
/// @trace spec:tray-app
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningStack {
    pub project_name: String,
    pub project_path: PathBuf,
    /// `🌺` (or whatever the OpenCodeWeb container's `display_emoji` is)
    /// when a `OpenCodeWeb` container is running for this project; else
    /// `None`. We don't fall back to the genus flower — bloom
    /// communicates "live web session", not "forge alive".
    pub bloom: Option<String>,
    /// Up to `MAX_TOOL_EMOJIS_IN_LABEL` emojis from running
    /// `Maintenance` containers, in `state.running` insertion order.
    pub tool_emojis: Vec<String>,
}

impl RunningStack {
    /// Render the submenu label: `<project>[ <bloom>][ <tools>]`.
    pub fn label(&self) -> String {
        let mut out = self.project_name.clone();
        if let Some(b) = &self.bloom {
            out.push(' ');
            out.push_str(b);
        }
        if !self.tool_emojis.is_empty() {
            out.push(' ');
            out.push_str(&self.tool_emojis.join(""));
        }
        out
    }
}

/// Compute the running stacks from `state.running`. A project appears
/// here when it has at least one container of type `Forge`,
/// `OpenCodeWeb`, or `Maintenance`. Sorted by lowercase project name.
///
/// @trace spec:tray-app
pub fn running_stacks(state: &TrayState) -> Vec<RunningStack> {
    use std::collections::BTreeMap;

    // Group by project_name so we hit each project exactly once.
    let mut by_project: BTreeMap<String, RunningStack> = BTreeMap::new();

    for c in &state.running {
        if !matches!(
            c.container_type,
            ContainerType::Forge | ContainerType::OpenCodeWeb | ContainerType::Maintenance
        ) {
            continue;
        }

        let key = c.project_name.to_lowercase();
        let entry = by_project.entry(key).or_insert_with(|| RunningStack {
            project_name: c.project_name.clone(),
            project_path: PathBuf::new(), // filled below from state.projects
            bloom: None,
            tool_emojis: Vec::new(),
        });

        match c.container_type {
            ContainerType::OpenCodeWeb if !c.display_emoji.is_empty() => {
                entry.bloom = Some(c.display_emoji.clone());
            }
            ContainerType::Maintenance if !c.display_emoji.is_empty() => {
                if entry.tool_emojis.len() < MAX_TOOL_EMOJIS_IN_LABEL {
                    entry.tool_emojis.push(c.display_emoji.clone());
                }
            }
            _ => {}
        }
    }

    // Resolve project_path from state.projects. If the project is no
    // longer on disk (deleted while a container is still running),
    // fall back to a watch_path-relative guess so the menu still
    // dispatches something coherent.
    let watch_root = first_watch_path();
    for stack in by_project.values_mut() {
        if let Some(p) = state.projects.iter().find(|p| p.name == stack.project_name) {
            stack.project_path = p.path.clone();
        } else {
            stack.project_path = watch_root.join(&stack.project_name);
        }
    }

    by_project.into_values().collect()
}

/// Names of remote repos that are not present locally and not on disk
/// under any watch path. Sorted ASCII.
fn remote_only_project_names(state: &TrayState) -> Vec<String> {
    let watch_path = first_watch_path();
    let local: Vec<String> = state.projects.iter().map(|p| p.name.clone()).collect();
    let mut out: Vec<String> = state
        .remote_repos
        .iter()
        .filter(|r| !local.contains(&r.name) && !watch_path.join(&r.name).exists())
        .map(|r| r.name.clone())
        .collect();
    out.sort();
    out
}

// ─── Submenu builders ────────────────────────────────────────────────────────

/// Configured first watch path (defaults to `~/src`).
fn first_watch_path() -> PathBuf {
    let global_config = load_global_config();
    global_config
        .scanner
        .watch_paths
        .first()
        .cloned()
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/root".to_string()))
                .join("src")
        })
}

/// Build a top-level running-stack submenu — `<label> ▸` with two
/// children: `🌱 Attach Another` and `🔧 Maintenance`.
///
/// @trace spec:tray-app
fn build_running_stack_submenu<R: Runtime>(
    app: &AppHandle<R>,
    stack: &RunningStack,
) -> tauri::Result<Submenu<R>> {
    let attach = MenuItemBuilder::with_id(
        ids::launch(&stack.project_path),
        i18n::t("menu.attach_another_with_emoji"),
    )
    .build(app)?;

    let maint = MenuItemBuilder::with_id(
        ids::maint(&stack.project_path),
        i18n::t("menu.maintenance"),
    )
    .build(app)?;

    SubmenuBuilder::new(app, stack.label())
        .item(&attach)
        .item(&maint)
        .build()
}

/// Build a per-local-project submenu inside `Projects ▸`. Always shows
/// `🌱 Attach Here`. `🔧 Maintenance` is only present when the project's
/// forge is currently running — never disabled.
///
/// @trace spec:tray-app
fn build_local_project_submenu<R: Runtime>(
    app: &AppHandle<R>,
    project: &Project,
    forge_running: bool,
) -> tauri::Result<Submenu<R>> {
    let attach_here = MenuItemBuilder::with_id(
        ids::launch(&project.path),
        i18n::t("menu.attach_here_with_emoji"),
    )
    .build(app)?;

    let mut sub = SubmenuBuilder::new(app, &project.name).item(&attach_here);

    if forge_running {
        let maint = MenuItemBuilder::with_id(
            ids::maint(&project.path),
            i18n::t("menu.maintenance"),
        )
        .build(app)?;
        sub = sub.item(&maint);
    }

    sub.build()
}

/// Build a per-remote-project submenu — single `Clone & Launch` child.
///
/// @trace spec:tray-app
fn build_remote_project_submenu<R: Runtime>(
    app: &AppHandle<R>,
    repo: &RemoteRepoInfo,
) -> tauri::Result<Submenu<R>> {
    let clone_item = MenuItemBuilder::with_id(
        ids::clone_repo(&repo.full_name, &repo.name),
        i18n::t("menu.clone_and_launch"),
    )
    .build(app)?;

    SubmenuBuilder::new(app, &repo.name)
        .item(&clone_item)
        .build()
}

/// Build the language selector submenu — pin emoji marks the active locale.
///
/// @trace spec:tray-app
fn build_language_submenu<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<Submenu<R>> {
    let global_config = load_global_config();
    let selected = global_config.i18n.language.clone();

    let mut submenu = SubmenuBuilder::with_id(app, ids::LANGUAGE, i18n::t("menu.language"));

    let languages: &[(&str, &str)] = &[
        ("en", "English"),
        ("es", "Espa\u{00F1}ol"),
        ("ja", "\u{65E5}\u{672C}\u{8A9E}"),
        ("zh-Hant", "\u{7E41}\u{9AD4}\u{4E2D}\u{6587}"),
        ("zh-Hans", "\u{7B80}\u{4F53}\u{4E2D}\u{6587}"),
        ("ar", "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}"),
        ("ko", "\u{D55C}\u{AD6D}\u{C5B4}"),
        ("hi", "\u{0939}\u{093F}\u{0928}\u{094D}\u{0926}\u{0940}"),
        ("ta", "\u{0BA4}\u{0BAE}\u{0BBF}\u{0BB4}\u{0BCD}"),
        ("te", "\u{0C24}\u{0C46}\u{0C32}\u{0C41}\u{0C17}\u{0C41}"),
        ("fr", "Fran\u{00E7}ais"),
        ("pt", "Portugu\u{00EA}s"),
        ("it", "Italiano"),
        ("ro", "Rom\u{00E2}n\u{0103}"),
        ("ru", "\u{0420}\u{0443}\u{0441}\u{0441}\u{043A}\u{0438}\u{0439}"),
        ("nah", "N\u{0101}huatl"),
        ("de", "Deutsch"),
    ];

    for &(code, name) in languages {
        let label = if code == selected {
            format!("\u{1F4CC} {name}")
        } else {
            name.to_string()
        };
        let item = MenuItemBuilder::with_id(ids::select_lang(code), &label).build(app)?;
        submenu = submenu.item(&item);
    }

    submenu.build()
}

/// Static signature label, interpolating the version at runtime.
fn signature_label() -> String {
    i18n::tf(
        "menu.signature_with_version",
        &[("version", env!("TILLANDSIAS_FULL_VERSION"))],
    )
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Read the ID off a `MenuItemKind` regardless of variant.
fn kind_id<R: Runtime>(kind: &MenuItemKind<R>) -> Option<String> {
    match kind {
        MenuItemKind::MenuItem(m) => Some(m.id().as_ref().to_string()),
        MenuItemKind::Submenu(s) => Some(s.id().as_ref().to_string()),
        MenuItemKind::Predefined(p) => Some(p.id().as_ref().to_string()),
        MenuItemKind::Check(c) => Some(c.id().as_ref().to_string()),
        MenuItemKind::Icon(i) => Some(i.id().as_ref().to_string()),
    }
}

/// Remove a `MenuItemKind` from a menu. `Menu::remove` takes a
/// `&dyn IsMenuItem<R>`, not a `MenuItemKind`, so we dispatch on the
/// variant.
fn remove_kind<R: Runtime>(root: &Menu<R>, kind: &MenuItemKind<R>) -> tauri::Result<()> {
    match kind {
        MenuItemKind::MenuItem(m) => root.remove(m as &dyn IsMenuItem<R>),
        MenuItemKind::Submenu(s) => root.remove(s as &dyn IsMenuItem<R>),
        MenuItemKind::Predefined(p) => root.remove(p as &dyn IsMenuItem<R>),
        MenuItemKind::Check(c) => root.remove(c as &dyn IsMenuItem<R>),
        MenuItemKind::Icon(i) => root.remove(i as &dyn IsMenuItem<R>),
    }
}

// ─── Click dispatch ──────────────────────────────────────────────────────────

/// Cleanly dispatch a tray-menu click ID to a `MenuCommand`. Unknown
/// IDs (including any legacy `tm.include-remote` from an old menu
/// snapshot) fall through to `None`. Caller logs and ignores `None`.
///
/// @trace spec:tray-app
pub fn dispatch_click(id: &str) -> Option<tillandsias_core::event::MenuCommand> {
    use tillandsias_core::event::MenuCommand;

    match id {
        ids::QUIT => Some(MenuCommand::Quit),
        ids::SIGN_IN => Some(MenuCommand::GitHubLogin),
        _ => {
            let (action, payload) = ids::parse(id)?;
            match action {
                "launch" => Some(MenuCommand::Launch {
                    project_path: payload.into(),
                }),
                "maint" => Some(MenuCommand::MaintenanceTerminal {
                    project_path: payload.into(),
                }),
                "clone" => {
                    let (full_name, name) = payload.split_once('\t')?;
                    Some(MenuCommand::CloneProject {
                        full_name: full_name.to_string(),
                        name: name.to_string(),
                    })
                }
                "lang" => Some(MenuCommand::SelectLanguage {
                    language: payload.to_string(),
                }),
                other => {
                    warn!(spec = "tray-app", action = other, "Unknown tray-menu action");
                    None
                }
            }
        }
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};
    use tillandsias_core::event::ContainerState;
    use tillandsias_core::genus::TillandsiaGenus;
    use tillandsias_core::state::{BuildProgress, ContainerInfo, PlatformInfo, Os};

    fn empty_state() -> TrayState {
        TrayState::new(PlatformInfo {
            os: Os::detect(),
            has_podman: true,
            has_podman_machine: false,
            gpu_devices: vec![],
        })
    }

    fn forge_container(project: &str, kind: ContainerType, emoji: &str) -> ContainerInfo {
        ContainerInfo {
            name: format!("tillandsias-{project}-forge"),
            project_name: project.to_string(),
            genus: TillandsiaGenus::ALL[0],
            state: ContainerState::Running,
            port_range: (0, 0),
            container_type: kind,
            display_emoji: emoji.to_string(),
        }
    }

    /// CredentialHealth → Stage mapping must match the cheatsheet table.
    /// @trace spec:tray-app
    #[test]
    fn credential_health_to_stage_mapping() {
        assert_eq!(
            stage_from_health(&CredentialHealth::Authenticated),
            Stage::Authed
        );
        assert_eq!(
            stage_from_health(&CredentialHealth::CredentialMissing),
            Stage::NoAuth
        );
        assert_eq!(
            stage_from_health(&CredentialHealth::CredentialInvalid),
            Stage::NoAuth
        );
        assert_eq!(
            stage_from_health(&CredentialHealth::GithubUnreachable {
                reason: "DNS failure".to_string()
            }),
            Stage::NetIssue
        );
    }

    /// Idle + authed produces no status text — the menu omits the row.
    /// @trace spec:tray-app
    #[test]
    fn status_text_idle_authed_is_none() {
        let state = empty_state();
        assert_eq!(status_text(&state, Stage::Authed), None);
    }

    /// In-flight build surfaces a single `Building {image}…` fragment.
    /// @trace spec:tray-app
    #[test]
    fn status_text_in_progress_build_surfaces() {
        let mut state = empty_state();
        state.active_builds.push(BuildProgress {
            image_name: "Forge".to_string(),
            status: BuildStatus::InProgress,
            started_at: Instant::now(),
            completed_at: None,
        });
        let s = status_text(&state, Stage::Booting).expect("expected Some");
        assert!(s.contains("Forge"), "got {s}");
        assert!(s.contains("Building"), "got {s}");
    }

    /// NetIssue stage adds the GitHub-unreachable fragment, joined to
    /// any other active condition.
    /// @trace spec:tray-app
    #[test]
    fn status_text_netissue_adds_github_unreachable() {
        let state = empty_state();
        let s = status_text(&state, Stage::NetIssue).expect("expected Some");
        assert!(s.contains("GitHub unreachable"), "got {s}");
    }

    /// `running_stacks` orders by lowercase project name regardless of
    /// `state.running` insertion order.
    /// @trace spec:tray-app
    #[test]
    fn running_stacks_orders_by_lowercase_name() {
        let mut state = empty_state();
        state
            .running
            .push(forge_container("Zeta", ContainerType::OpenCodeWeb, "🌺"));
        state
            .running
            .push(forge_container("alpha", ContainerType::OpenCodeWeb, "🌺"));
        state
            .running
            .push(forge_container("Mango", ContainerType::OpenCodeWeb, "🌺"));
        let names: Vec<String> = running_stacks(&state)
            .into_iter()
            .map(|s| s.project_name)
            .collect();
        assert_eq!(names, vec!["alpha", "Mango", "Zeta"]);
    }

    /// Tool emojis appear in `state.running` insertion order, capped at
    /// `MAX_TOOL_EMOJIS_IN_LABEL`.
    /// @trace spec:tray-app
    #[test]
    fn running_stacks_caps_tool_emojis() {
        let mut state = empty_state();
        state.running.push(forge_container(
            "demo",
            ContainerType::OpenCodeWeb,
            "🌺",
        ));
        for emoji in ["🔧", "🪛", "🔨", "🪚", "⚙️", "🔩", "🧰"] {
            state
                .running
                .push(forge_container("demo", ContainerType::Maintenance, emoji));
        }

        let stacks = running_stacks(&state);
        assert_eq!(stacks.len(), 1);
        assert_eq!(stacks[0].project_name, "demo");
        assert_eq!(stacks[0].bloom.as_deref(), Some("🌺"));
        assert_eq!(stacks[0].tool_emojis.len(), MAX_TOOL_EMOJIS_IN_LABEL);
        assert_eq!(
            stacks[0].tool_emojis,
            vec!["🔧", "🪛", "🔨", "🪚", "⚙️"]
        );
    }

    /// Bloom is `None` for a project with only a `Forge` container —
    /// bloom communicates "live web session", not "forge alive".
    /// @trace spec:tray-app
    #[test]
    fn running_stacks_no_bloom_when_only_forge() {
        let mut state = empty_state();
        state
            .running
            .push(forge_container("hot", ContainerType::Forge, "🌷"));
        let stacks = running_stacks(&state);
        assert_eq!(stacks.len(), 1);
        assert_eq!(stacks[0].bloom, None);
    }

    /// Running-stack label format: `<project>[ <bloom>][ <tools>]`.
    /// @trace spec:tray-app
    #[test]
    fn running_stack_label_order_is_name_bloom_tools() {
        let stack = RunningStack {
            project_name: "demo".to_string(),
            project_path: PathBuf::from("/tmp/demo"),
            bloom: Some("🌺".to_string()),
            tool_emojis: vec!["🔧".to_string(), "🪛".to_string()],
        };
        assert_eq!(stack.label(), "demo 🌺 🔧🪛");

        let no_tools = RunningStack {
            project_name: "demo".to_string(),
            project_path: PathBuf::from("/tmp/demo"),
            bloom: Some("🌺".to_string()),
            tool_emojis: vec![],
        };
        assert_eq!(no_tools.label(), "demo 🌺");

        let no_bloom = RunningStack {
            project_name: "demo".to_string(),
            project_path: PathBuf::from("/tmp/demo"),
            bloom: None,
            tool_emojis: vec!["🔧".to_string()],
        };
        assert_eq!(no_bloom.label(), "demo 🔧");
    }

    /// Click dispatch maps the kept action prefixes correctly. The
    /// removed `tm.include-remote` ID falls through to None — a
    /// defensive check against stale menu state from a previous version.
    /// @trace spec:tray-app
    #[test]
    fn dispatch_click_known_actions() {
        use tillandsias_core::event::MenuCommand;

        assert!(matches!(
            dispatch_click(ids::QUIT),
            Some(MenuCommand::Quit)
        ));
        assert!(matches!(
            dispatch_click(ids::SIGN_IN),
            Some(MenuCommand::GitHubLogin)
        ));

        let id = ids::launch(std::path::Path::new("/tmp/foo"));
        match dispatch_click(&id) {
            Some(MenuCommand::Launch { project_path }) => {
                assert_eq!(project_path, std::path::PathBuf::from("/tmp/foo"));
            }
            other => panic!("expected Launch, got {other:?}"),
        }

        let id = ids::maint(std::path::Path::new("/tmp/bar"));
        match dispatch_click(&id) {
            Some(MenuCommand::MaintenanceTerminal { project_path }) => {
                assert_eq!(project_path, std::path::PathBuf::from("/tmp/bar"));
            }
            other => panic!("expected MaintenanceTerminal, got {other:?}"),
        }

        let id = ids::clone_repo("octocat/foo", "foo");
        match dispatch_click(&id) {
            Some(MenuCommand::CloneProject { full_name, name }) => {
                assert_eq!(full_name, "octocat/foo");
                assert_eq!(name, "foo");
            }
            other => panic!("expected CloneProject, got {other:?}"),
        }

        // SelectLanguage variant is dormant until i18n is re-enabled.
        // The Language ▸ menu item is no longer appended, but the dispatch variant
        // remains in the enum for future re-enablement.
        // @trace spec:tray-projects-rename
        let id = ids::select_lang("ja");
        match dispatch_click(&id) {
            Some(MenuCommand::SelectLanguage { language }) => assert_eq!(language, "ja"),
            other => panic!("expected SelectLanguage, got {other:?}"),
        }

        // Stale legacy ID — should not crash, returns None.
        assert!(dispatch_click("tm.include-remote").is_none());
        assert!(dispatch_click("tm.bogus:foo").is_none());
    }

    /// Stale builds outside the 2 s flash window are not surfaced.
    /// @trace spec:tray-app
    #[test]
    fn status_text_completed_builds_fade_after_2s() {
        let mut state = empty_state();
        let stale_completed = Instant::now()
            .checked_sub(Duration::from_secs(5))
            .expect("can subtract 5 s from now");
        state.active_builds.push(BuildProgress {
            image_name: "Forge".to_string(),
            status: BuildStatus::Completed,
            started_at: stale_completed,
            completed_at: Some(stale_completed),
        });
        assert_eq!(status_text(&state, Stage::Authed), None);
    }

    /// Regression: placeholder container pushed to `state.running` immediately
    /// after user clicks Attach is visible in `running_stacks` before the
    /// forge-build pipeline completes.
    ///
    /// This verifies the fix for task #49 — the event loop now calls
    /// `notify(state)` right after pushing the placeholder, so the chip
    /// flips to the running-stack label without waiting for the full handler
    /// to return.
    ///
    /// @trace spec:tray-app
    #[test]
    fn placeholder_container_in_creating_state_appears_in_running_stacks() {
        let mut state = empty_state();

        // Simulate what handle_attach_here/handle_attach_web do before notify():
        // push a placeholder container in Creating state.
        let genus = tillandsias_core::genus::TillandsiaGenus::ALL[1];
        state.running.push(ContainerInfo {
            name: format!("tillandsias-myproject-{}", genus.display_name()),
            project_name: "myproject".to_string(),
            genus,
            state: ContainerState::Creating,
            port_range: (3000, 3019),
            container_type: ContainerType::Forge,
            display_emoji: genus.flower().to_string(),
        });

        // At the moment notify(state) is called the running_stacks function
        // must surface the project — this is what drives the chip update.
        let stacks = running_stacks(&state);
        assert_eq!(stacks.len(), 1, "placeholder must appear immediately");
        assert_eq!(stacks[0].project_name, "myproject");

        // No build progress events have fired yet — chip has no action text.
        // The running-stack submenu entry itself is the visual confirmation.
        assert_eq!(status_text(&state, Stage::Authed), None,
            "no build chip yet — the running-stack entry is the immediate feedback");
    }

    /// Regression: build chip fires immediately when BuildProgressEvent::Started
    /// is received. Verifies the chip text appears as soon as the handler
    /// sends the event, not only after the full pipeline completes.
    ///
    /// @trace spec:tray-app
    #[test]
    fn build_chip_appears_when_started_event_arrives() {
        let mut state = empty_state();

        // Simulate BuildProgressEvent::Started being processed by the event
        // loop (handle_build_progress_event pushes an InProgress entry).
        state.active_builds.push(BuildProgress {
            image_name: "Development Environment".to_string(),
            status: BuildStatus::InProgress,
            started_at: Instant::now(),
            completed_at: None,
        });

        let text = status_text(&state, Stage::Authed)
            .expect("chip must be visible while build is in progress");
        assert!(text.contains("Building"), "chip must say Building: {text}");
        assert!(text.contains("Development Environment"), "chip must name the subsystem: {text}");
    }
}
