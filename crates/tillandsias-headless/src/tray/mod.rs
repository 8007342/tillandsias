// @trace spec:tray-app, spec:tray-ux, spec:tray-progress-and-icon-states, spec:tray-icon-lifecycle, spec:opencode-web-session, spec:runtime-logging, spec:logging-levels
//! Native Linux tray service backed by StatusNotifierItem and DBusMenu.
//!
//! The tray owns the Linux menu/icon surface. Menu actions launch the repo's
//! existing container entrypoints so the tray stays thin.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;

use image::GenericImageView;
use tracing::{info, warn};
use zbus::object_server::SignalContext;
use zbus::{Connection, ConnectionBuilder, fdo, interface};
use zvariant::{OwnedObjectPath, OwnedValue, Value};

use tillandsias_core::config::{self, SelectedAgent};
use tillandsias_core::genus::TrayIconState;

const ITEM_PATH: &str = "/StatusNotifierItem";
const MENU_PATH: &str = "/Menu";
const WATCHER_PATH: &str = "/StatusNotifierWatcher";
const WATCHER_NAME: &str = "org.kde.StatusNotifierWatcher";

#[derive(Debug, Clone)]
struct ProjectEntry {
    name: String,
    path: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LaunchKind {
    OpenCode,
    OpenCodeWeb,
    Claude,
    Maintenance,
}

#[derive(Debug, Clone)]
struct TrayUiState {
    root: PathBuf,
    version: String,
    status_text: String,
    tray_icon_state: TrayIconState,
    projects: Vec<ProjectEntry>,
    selected_agent: SelectedAgent,
    forge_available: bool,
    podman_available: bool,
    revision: u32,
}

type IconPixmap = (i32, i32, Vec<u8>);

type MenuNode = (i32, HashMap<String, OwnedValue>, Vec<OwnedValue>);
type GroupProperties = Vec<(i32, HashMap<String, OwnedValue>)>;

#[derive(Debug)]
struct TrayService {
    state: Mutex<TrayUiState>,
    connection: OnceLock<Connection>,
    item_path: String,
    menu_path: String,
    service_name: String,
}

#[derive(Clone)]
struct StatusNotifierItemIface(Arc<TrayService>);

#[derive(Clone)]
struct DbusMenuIface(Arc<TrayService>);

impl TrayUiState {
    fn new(root: PathBuf, version: String, projects: Vec<ProjectEntry>) -> Self {
        let podman_available = podman_available();
        let selected_agent = config::load_global_config().agent.selected;
        let forge_image = format!("tillandsias-forge:v{version}");
        let forge_available = podman_available && image_exists(&forge_image);

        let (status_text, tray_icon_state) = if !podman_available {
            ("🥀 Podman unavailable".to_string(), TrayIconState::Dried)
        } else if forge_available {
            ("✅ Ready".to_string(), TrayIconState::Mature)
        } else {
            ("🌱 Setting up...".to_string(), TrayIconState::Pup)
        };

        Self {
            root,
            version,
            status_text,
            tray_icon_state,
            projects,
            selected_agent,
            forge_available,
            podman_available,
            revision: 1,
        }
    }

    fn bump_revision(&mut self) -> u32 {
        self.revision = self.revision.saturating_add(1);
        self.revision
    }
}

impl TrayService {
    fn new(state: TrayUiState) -> Self {
        let pid = std::process::id();
        Self {
            state: Mutex::new(state),
            connection: OnceLock::new(),
            item_path: ITEM_PATH.to_string(),
            menu_path: MENU_PATH.to_string(),
            service_name: format!("org.freedesktop.StatusNotifierItem-{pid}-1"),
        }
    }

    fn attach_connection(&self, connection: Connection) {
        let _ = self.connection.set(connection);
    }

    fn connection(&self) -> &Connection {
        self.connection
            .get()
            .expect("tray connection should be attached before use")
    }

    fn snapshot(&self) -> TrayUiState {
        self.state.lock().expect("tray state lock poisoned").clone()
    }

    fn with_state<T>(&self, f: impl FnOnce(&mut TrayUiState) -> T) -> T {
        let mut state = self.state.lock().expect("tray state lock poisoned");
        f(&mut state)
    }

    fn refresh_snapshot(&self) -> TrayUiState {
        self.snapshot()
    }

    async fn emit_refresh(&self, include_menu: bool) -> zbus::Result<()> {
        let item_ctxt = SignalContext::new(self.connection(), self.item_path.as_str())?;
        StatusNotifierItemIface::new_icon(&item_ctxt).await?;
        StatusNotifierItemIface::new_status(&item_ctxt).await?;
        StatusNotifierItemIface::new_tool_tip(&item_ctxt).await?;

        if include_menu {
            let revision = self.refresh_snapshot().revision;
            let menu_ctxt = SignalContext::new(self.connection(), self.menu_path.as_str())?;
            DbusMenuIface::layout_updated(&menu_ctxt, revision, 0).await?;
        }

        Ok(())
    }

    async fn rebuild_after_state_change(&self) -> zbus::Result<()> {
        self.emit_refresh(true).await
    }

    async fn set_status(
        &self,
        text: impl Into<String>,
        icon: TrayIconState,
        forge_available: Option<bool>,
    ) -> zbus::Result<()> {
        self.with_state(|state| {
            state.status_text = text.into();
            state.tray_icon_state = icon;
            if let Some(value) = forge_available {
                state.forge_available = value;
            }
            state.bump_revision();
        });
        self.rebuild_after_state_change().await
    }

    fn selected_agent(&self) -> SelectedAgent {
        self.snapshot().selected_agent
    }

    fn update_selected_agent(&self, agent: SelectedAgent) {
        self.with_state(|state| {
            state.selected_agent = agent;
            state.bump_revision();
        });
    }

    fn project_by_name(&self, name: &str) -> Option<ProjectEntry> {
        self.snapshot()
            .projects
            .into_iter()
            .find(|project| project.name == name)
    }

    fn launch_selected_agent_for_project(&self, _project: &ProjectEntry) -> LaunchKind {
        match self.selected_agent() {
            SelectedAgent::OpenCode => LaunchKind::OpenCode,
            SelectedAgent::Claude => LaunchKind::Claude,
            SelectedAgent::OpenCodeWeb => LaunchKind::OpenCodeWeb,
        }
    }
}

fn podman_available() -> bool {
    Command::new("podman")
        .arg("--version")
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn image_exists(image_tag: &str) -> bool {
    Command::new("podman")
        .args(["image", "exists", image_tag])
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn discover_projects() -> Vec<ProjectEntry> {
    let home = match std::env::var("HOME") {
        Ok(home) => PathBuf::from(home),
        Err(_) => return Vec::new(),
    };
    let src = home.join("src");
    let mut projects = Vec::new();
    let entries = match std::fs::read_dir(&src) {
        Ok(entries) => entries,
        Err(_) => return Vec::new(),
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let Some(name) = path
            .file_name()
            .and_then(|n| n.to_str())
            .map(|s| s.to_string())
        else {
            continue;
        };
        projects.push(ProjectEntry { name, path });
    }

    projects.sort_by(|a, b| a.name.cmp(&b.name));
    projects
}

fn shell_quote(value: impl Into<String>) -> String {
    let value = value.into();
    if value.is_empty() {
        return "''".to_string();
    }
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn action_slug(kind: LaunchKind) -> &'static str {
    match kind {
        LaunchKind::OpenCode => "opencode",
        LaunchKind::OpenCodeWeb => "opencode-web",
        LaunchKind::Claude => "claude",
        LaunchKind::Maintenance => "terminal",
    }
}

fn ov(value: Value<'_>) -> OwnedValue {
    OwnedValue::try_from(value).expect("value should serialize")
}

fn ov_str(value: impl Into<String>) -> OwnedValue {
    ov(Value::from(value.into()))
}

fn props(pairs: Vec<(String, OwnedValue)>) -> HashMap<String, OwnedValue> {
    pairs.into_iter().collect()
}

fn node(id: i32, props: HashMap<String, OwnedValue>, children: Vec<OwnedValue>) -> MenuNode {
    (id, props, children)
}

fn child(node: MenuNode) -> OwnedValue {
    OwnedValue::try_from(Value::from(node)).expect("dbusmenu child should serialize")
}

fn icon_pixmaps(state: TrayIconState) -> Vec<IconPixmap> {
    let png = tillandsias_core::icons::tray_icon_png(state);
    let image = image::load_from_memory_with_format(png, image::ImageFormat::Png)
        .expect("tray PNG should decode");
    let (width, height) = image.dimensions();
    let rgba = image.into_rgba8();
    let mut argb = Vec::with_capacity(rgba.len());
    for pixel in rgba.as_raw().chunks_exact(4) {
        argb.extend_from_slice(&[pixel[3], pixel[0], pixel[1], pixel[2]]);
    }
    vec![(width as i32, height as i32, argb)]
}

fn tray_icon_status(state: TrayIconState) -> &'static str {
    match state {
        TrayIconState::Dried => "NeedsAttention",
        _ => "Active",
    }
}

fn tray_icon_tooltip(snapshot: &TrayUiState) -> (String, Vec<IconPixmap>, String, String) {
    (
        "Tillandsias".to_string(),
        icon_pixmaps(snapshot.tray_icon_state),
        snapshot.status_text.clone(),
        "Tillandsias".to_string(),
    )
}

fn build_launch_command(
    project: &ProjectEntry,
    image: &str,
    kind: LaunchKind,
    root: &Path,
) -> String {
    let project_name = &project.name;
    let project_path = project
        .path
        .canonicalize()
        .unwrap_or_else(|_| project.path.clone());
    let ca_cert = PathBuf::from("/tmp/tillandsias-ca/intermediate.crt");

    let mut cmd = format!(
        "podman run --rm --name {} --hostname {} --cap-drop=ALL --security-opt=no-new-privileges --security-opt=label=disable --userns=keep-id --pids-limit=512 --env HOME=/home/forge --env USER=forge --env PROJECT={} --env http_proxy=http://proxy:3128 --env https_proxy=http://proxy:3128 --env HTTP_PROXY=http://proxy:3128 --env HTTPS_PROXY=http://proxy:3128 --env no_proxy=localhost,127.0.0.1,10.0.42.0/24 --env PATH=/usr/local/bin:/usr/bin --network tillandsias-enclave -v {}:/home/forge/src/{}:rw",
        shell_quote(format!(
            "tillandsias-{}-{}",
            project_name,
            action_slug(kind)
        )),
        shell_quote(format!("forge-{}", project_name)),
        shell_quote(project_name),
        shell_quote(project_path.display().to_string()),
        shell_quote(project_name),
    );

    if ca_cert.exists() {
        cmd.push_str(&format!(
            " --mount type=bind,source={},target=/etc/tillandsias/ca.crt,readonly=true",
            shell_quote(ca_cert.display().to_string())
        ));
    }

    match kind {
        LaunchKind::OpenCode => cmd.push_str(
            " --interactive --tty --entrypoint /usr/local/bin/entrypoint-forge-opencode.sh",
        ),
        LaunchKind::OpenCodeWeb => {
            cmd.push_str(" --entrypoint /usr/local/bin/entrypoint-forge-opencode-web.sh -d")
        }
        LaunchKind::Claude => cmd.push_str(
            " --interactive --tty --entrypoint /usr/local/bin/entrypoint-forge-claude.sh",
        ),
        LaunchKind::Maintenance => {
            cmd.push_str(" --interactive --tty --entrypoint /usr/local/bin/entrypoint-terminal.sh")
        }
    }

    cmd.push(' ');
    cmd.push_str(&shell_quote(image.to_string()));
    let _ = root;
    cmd
}

fn launch_in_terminal(title: &str, command: &str) -> Result<(), String> {
    let shell_command = format!("{}; exec bash", command);
    for candidate in ["gnome-terminal", "konsole", "xterm"] {
        if terminal_present(candidate) {
            let mut child = Command::new(candidate);
            match candidate {
                "gnome-terminal" => {
                    child.args(["--title", title, "--", "bash", "-lc", &shell_command]);
                }
                "konsole" => {
                    child.args([
                        "--new-tab",
                        "-p",
                        &format!("tabtitle={title}"),
                        "-e",
                        "bash",
                        "-lc",
                        &shell_command,
                    ]);
                }
                "xterm" => {
                    child.args(["-T", title, "-e", "bash", "-lc", &shell_command]);
                }
                _ => {}
            }
            child
                .spawn()
                .map_err(|e| format!("failed to launch terminal: {e}"))?;
            return Ok(());
        }
    }

    let status = Command::new("sh")
        .args(["-lc", command])
        .status()
        .map_err(|e| format!("failed to run shell command: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("shell command exited with {status}"))
    }
}

fn terminal_present(candidate: &str) -> bool {
    Command::new("sh")
        .args(["-lc", &format!("command -v {candidate} >/dev/null 2>&1")])
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn launch_project_action(
    project: ProjectEntry,
    kind: LaunchKind,
    root: PathBuf,
    version: String,
) -> Result<(), String> {
    let image = format!("tillandsias-forge:v{}", version);
    let command = build_launch_command(&project, &image, kind, &root);
    match kind {
        LaunchKind::OpenCodeWeb => Command::new("sh")
            .args(["-lc", &command])
            .status()
            .map_err(|e| e.to_string())
            .and_then(|status| {
                if status.success() {
                    Ok(())
                } else {
                    Err(format!("shell command exited with {status}"))
                }
            }),
        _ => launch_in_terminal(
            &format!("Tillandsias - {} - {}", project.name, action_slug(kind)),
            &command,
        ),
    }
}

fn run_init_action() -> Result<(), String> {
    super::run_init(false)
}

fn run_github_login_action() -> Result<(), String> {
    super::run_github_login(false)
}

fn run_root_terminal(root: &Path, version: &str) -> Result<(), String> {
    let image = format!("tillandsias-forge:v{}", version);
    let project = ProjectEntry {
        name: root
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("tillandsias")
            .to_string(),
        path: root.to_path_buf(),
    };
    let command = build_launch_command(&project, &image, LaunchKind::Maintenance, root);
    launch_in_terminal("Tillandsias - Root", &command)
}

fn handle_select_agent(service: Arc<TrayService>, agent: SelectedAgent) {
    service.update_selected_agent(agent);
    config::save_selected_agent(agent);
    let service_for_emit = service.clone();
    thread::spawn(move || {
        let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
    });
}

fn handle_launch_project(service: Arc<TrayService>, project: ProjectEntry, kind: LaunchKind) {
    let root = service.snapshot().root.clone();
    let version = service.snapshot().version.clone();
    let service_for_emit = service.clone();
    thread::spawn(move || {
        let result = launch_project_action(project, kind, root, version);
        if let Err(err) = result {
            warn!("project launch failed: {err}");
        }
        let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
    });
}

fn handle_init(service: Arc<TrayService>) {
    let service_for_emit = service.clone();
    thread::spawn(move || {
        let _ = futures::executor::block_on(service_for_emit.set_status(
            "⏳ Building images ...",
            TrayIconState::Building,
            None,
        ));
        let result = run_init_action();
        let (text, icon, forge_available) = if result.is_ok() {
            ("✅ Ready", TrayIconState::Mature, Some(true))
        } else {
            ("🥀 Setup failed", TrayIconState::Dried, Some(false))
        };
        if let Err(err) = result {
            warn!("initialization failed: {err}");
        }
        let _ =
            futures::executor::block_on(service_for_emit.set_status(text, icon, forge_available));
    });
}

fn handle_github_login(service: Arc<TrayService>) {
    let service_for_emit = service.clone();
    thread::spawn(move || {
        if let Err(err) = run_github_login_action() {
            warn!("GitHub login failed: {err}");
        }
        let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
    });
}

fn build_seedlings_submenu(state: &TrayUiState) -> MenuNode {
    let mut children = Vec::new();
    for agent in [
        SelectedAgent::OpenCodeWeb,
        SelectedAgent::OpenCode,
        SelectedAgent::Claude,
    ] {
        let item_props = props(vec![
            ("label".to_string(), ov_str(agent.display_name())),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
            ("toggle-type".to_string(), ov_str("checkmark")),
            (
                "toggle-state".to_string(),
                ov(Value::from(if state.selected_agent == agent {
                    1i32
                } else {
                    0i32
                })),
            ),
        ]);
        children.push(child(node(
            match agent {
                SelectedAgent::OpenCodeWeb => 1001,
                SelectedAgent::OpenCode => 1002,
                SelectedAgent::Claude => 1003,
            },
            item_props,
            Vec::new(),
        )));
    }

    node(
        10,
        props(vec![
            ("label".to_string(), ov_str("Seedlings")),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
            ("children-display".to_string(), ov_str("submenu")),
        ]),
        children,
    )
}

fn build_project_submenu(state: &TrayUiState, project: &ProjectEntry) -> MenuNode {
    build_project_submenu_with_running(state, project, podman_running_web_container(&project.name))
}

fn build_project_submenu_with_running(
    state: &TrayUiState,
    project: &ProjectEntry,
    running_web: bool,
) -> MenuNode {
    let mut children = Vec::new();
    let attach_enabled = state.forge_available && state.podman_available;
    let maintenance_enabled = state.forge_available && state.podman_available;

    children.push(child(node(
        stable_project_item_id(&project.name, "attach-here"),
        props(vec![
            ("label".to_string(), ov_str("Attach Here")),
            ("enabled".to_string(), ov(Value::from(attach_enabled))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    children.push(child(node(
        stable_project_item_id(&project.name, "maintenance"),
        props(vec![
            ("label".to_string(), ov_str("Maintenance")),
            ("enabled".to_string(), ov(Value::from(maintenance_enabled))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    if running_web {
        children.push(child(node(
            stable_project_item_id(&project.name, "stop"),
            props(vec![
                ("label".to_string(), ov_str("Stop")),
                ("enabled".to_string(), ov(Value::from(true))),
                ("visible".to_string(), ov(Value::from(true))),
            ]),
            Vec::new(),
        )));
    }

    node(
        stable_project_item_id(&project.name, "submenu"),
        props(vec![
            ("label".to_string(), ov_str(project.name.clone())),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
            ("children-display".to_string(), ov_str("submenu")),
        ]),
        children,
    )
}

fn podman_running_web_container(project_name: &str) -> bool {
    let output = Command::new("podman")
        .args(["ps", "--format", "{{.Names}}"])
        .output();
    let Ok(output) = output else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    let prefix = format!("tillandsias-{project_name}-forge");
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .any(|line| line.trim() == prefix)
}

fn stable_project_item_id(project: &str, suffix: &str) -> i32 {
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    use std::hash::Hash;
    use std::hash::Hasher;
    project.hash(&mut hash);
    suffix.hash(&mut hash);
    let value = (hash.finish() & 0x7fff_ffff) as i32;
    if value == 0 { 1 } else { value }
}

fn build_menu(state: &TrayUiState) -> MenuNode {
    let mut children = Vec::new();

    children.push(child(node(
        1,
        props(vec![
            ("label".to_string(), ov_str(state.status_text.clone())),
            ("enabled".to_string(), ov(Value::from(false))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    children.push(child(build_seedlings_submenu(state)));

    for project in &state.projects {
        children.push(child(build_project_submenu(state, project)));
    }

    children.push(child(node(
        20,
        props(vec![
            ("label".to_string(), ov_str("Initialize images")),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    children.push(child(node(
        21,
        props(vec![
            ("label".to_string(), ov_str("Root Terminal")),
            (
                "enabled".to_string(),
                ov(Value::from(state.forge_available && state.podman_available)),
            ),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    children.push(child(node(
        22,
        props(vec![
            ("label".to_string(), ov_str("GitHub Login")),
            (
                "enabled".to_string(),
                ov(Value::from(state.podman_available)),
            ),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    children.push(child(node(
        30,
        props(vec![
            (
                "label".to_string(),
                ov_str(format!("Tillandsias v{}", state.version)),
            ),
            ("enabled".to_string(), ov(Value::from(false))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    children.push(child(node(
        31,
        props(vec![
            ("label".to_string(), ov_str("Quit Tillandsias")),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    node(
        0,
        props(vec![
            ("label".to_string(), ov_str("Tillandsias")),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        children,
    )
}

#[interface(name = "org.kde.StatusNotifierItem")]
impl StatusNotifierItemIface {
    #[zbus(property)]
    fn category(&self) -> String {
        "ApplicationStatus".to_string()
    }

    #[zbus(property)]
    fn id(&self) -> String {
        "tillandsias".to_string()
    }

    #[zbus(property)]
    fn title(&self) -> String {
        "Tillandsias".to_string()
    }

    #[zbus(property)]
    fn status(&self) -> String {
        tray_icon_status(self.0.snapshot().tray_icon_state).to_string()
    }

    #[zbus(property)]
    fn window_id(&self) -> u32 {
        0
    }

    #[zbus(property)]
    fn icon_theme_path(&self) -> String {
        String::new()
    }

    #[zbus(property)]
    fn icon_name(&self) -> String {
        String::new()
    }

    #[zbus(property)]
    fn icon_pixmap(&self) -> Vec<IconPixmap> {
        icon_pixmaps(self.0.snapshot().tray_icon_state)
    }

    #[zbus(property)]
    fn attention_icon_name(&self) -> String {
        String::new()
    }

    #[zbus(property)]
    fn attention_icon_pixmap(&self) -> Vec<IconPixmap> {
        Vec::new()
    }

    #[zbus(property)]
    fn attention_movie_name(&self) -> String {
        String::new()
    }

    #[zbus(property)]
    fn menu(&self) -> OwnedObjectPath {
        OwnedObjectPath::try_from(self.0.menu_path.as_str()).expect("menu object path")
    }

    #[zbus(property)]
    fn item_is_menu(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn menu_icon_name(&self) -> String {
        String::new()
    }

    #[zbus(property)]
    fn menu_overlay_icon_name(&self) -> String {
        String::new()
    }

    #[zbus(property)]
    fn tooltip(&self) -> (String, Vec<IconPixmap>, String, String) {
        tray_icon_tooltip(&self.0.snapshot())
    }

    #[zbus(property)]
    fn protocol_version(&self) -> u32 {
        0
    }

    async fn activate(
        &self,
        _x: i32,
        _y: i32,
        #[zbus(signal_context)] ctxt: SignalContext<'_>,
    ) -> fdo::Result<()> {
        if self.0.snapshot().tray_icon_state == TrayIconState::Blooming {
            self.0.with_state(|state| {
                state.tray_icon_state = TrayIconState::Mature;
                state.bump_revision();
            });
            StatusNotifierItemIface::new_icon(&ctxt)
                .await
                .map_err(|e| fdo::Error::Failed(e.to_string()))?;
        }
        Ok(())
    }

    async fn context_menu(
        &self,
        _x: i32,
        _y: i32,
        #[zbus(signal_context)] ctxt: SignalContext<'_>,
    ) -> fdo::Result<()> {
        if self.0.snapshot().tray_icon_state == TrayIconState::Blooming {
            self.0.with_state(|state| {
                state.tray_icon_state = TrayIconState::Mature;
                state.bump_revision();
            });
            StatusNotifierItemIface::new_icon(&ctxt)
                .await
                .map_err(|e| fdo::Error::Failed(e.to_string()))?;
        }
        Ok(())
    }

    async fn secondary_activate(
        &self,
        _x: i32,
        _y: i32,
        #[zbus(signal_context)] ctxt: SignalContext<'_>,
    ) -> fdo::Result<()> {
        self.context_menu(_x, _y, ctxt).await
    }

    async fn scroll(&self, _delta: i32, _orientation: &str, _x: i32, _y: i32) -> fdo::Result<()> {
        Ok(())
    }

    #[zbus(signal)]
    async fn new_icon(ctxt: &SignalContext<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn new_status(ctxt: &SignalContext<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn new_tool_tip(ctxt: &SignalContext<'_>) -> zbus::Result<()>;
}

#[interface(name = "com.canonical.dbusmenu")]
impl DbusMenuIface {
    #[zbus(property)]
    fn version(&self) -> u32 {
        3
    }

    #[zbus(property)]
    fn text_direction(&self) -> String {
        "none".to_string()
    }

    #[zbus(property)]
    fn status(&self) -> String {
        "normal".to_string()
    }

    async fn get_layout(
        &self,
        _parent_id: i32,
        _recursion_depth: i32,
        _property_names: Vec<String>,
    ) -> fdo::Result<(u32, MenuNode)> {
        let state = self.0.snapshot();
        Ok((state.revision, build_menu(&state)))
    }

    async fn get_group_properties(
        &self,
        ids: Vec<i32>,
        property_names: Vec<String>,
    ) -> fdo::Result<GroupProperties> {
        let state = self.0.snapshot();
        let menu = build_menu(&state);
        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);

        let requested: Option<std::collections::HashSet<String>> = if property_names.is_empty() {
            None
        } else {
            Some(property_names.into_iter().collect())
        };

        let mut out = Vec::new();
        for id in ids {
            if let Some((_, props)) = flat.iter().find(|(item_id, _)| *item_id == id) {
                let selected = props
                    .iter()
                    .filter(|(name, _)| {
                        requested
                            .as_ref()
                            .map(|wanted| wanted.contains(*name))
                            .unwrap_or(true)
                    })
                    .map(|(name, value)| {
                        (
                            name.clone(),
                            value.try_clone().expect("dbusmenu property should clone"),
                        )
                    })
                    .collect();
                out.push((id, selected));
            }
        }
        Ok(out)
    }

    async fn get_property(&self, id: i32, property_name: &str) -> fdo::Result<OwnedValue> {
        let state = self.0.snapshot();
        let menu = build_menu(&state);
        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);
        if let Some((_, props)) = flat.iter().find(|(item_id, _)| *item_id == id) {
            props.get(property_name).map_or_else(
                || Err(fdo::Error::UnknownProperty(property_name.to_string())),
                |value| {
                    value
                        .try_clone()
                        .map_err(|e| fdo::Error::Failed(e.to_string()))
                },
            )
        } else {
            Err(fdo::Error::UnknownObject(format!("unknown menu item {id}")))
        }
    }

    async fn about_to_show(&self, _id: i32) -> fdo::Result<(bool, bool)> {
        Ok((true, false))
    }

    async fn event(
        &self,
        id: i32,
        event_id: &str,
        _data: OwnedValue,
        _timestamp: u32,
    ) -> fdo::Result<(i32, bool)> {
        if event_id != "clicked" && event_id != "opened" && event_id != "activate" {
            return Ok((0, false));
        }

        let state = self.0.snapshot();
        let mut flat = Vec::new();
        flatten_layout(&build_menu(&state), &mut flat);

        if let Some((_, props)) = flat.iter().find(|(item_id, _)| *item_id == id) {
            if let Some(label) = props.get("label") {
                let label = String::try_from(
                    label
                        .try_clone()
                        .map_err(|e| fdo::Error::Failed(e.to_string()))?,
                )
                .unwrap_or_default();
                match label.as_str() {
                    "Initialize images" => handle_init(self.0.clone()),
                    "GitHub Login" => handle_github_login(self.0.clone()),
                    "Root Terminal" => {
                        let snapshot = self.0.snapshot();
                        if snapshot.forge_available && snapshot.podman_available {
                            let service = self.0.clone();
                            thread::spawn(move || {
                                if let Err(err) =
                                    run_root_terminal(&snapshot.root, &snapshot.version)
                                {
                                    warn!("root terminal launch failed: {err}");
                                }
                                let _ = futures::executor::block_on(
                                    service.rebuild_after_state_change(),
                                );
                            });
                        }
                    }
                    "Quit Tillandsias" => {
                        std::process::exit(0);
                    }
                    "Attach Here" => {
                        if let Some((project, _)) = project_from_id(&state, id) {
                            if let Some(project_entry) = self.0.project_by_name(&project) {
                                let kind = self.0.launch_selected_agent_for_project(&project_entry);
                                handle_launch_project(self.0.clone(), project_entry, kind);
                            }
                        }
                    }
                    "Maintenance" => {
                        if let Some((project, _)) = project_from_id(&state, id) {
                            if let Some(project_entry) = self.0.project_by_name(&project) {
                                handle_launch_project(
                                    self.0.clone(),
                                    project_entry,
                                    LaunchKind::Maintenance,
                                );
                            }
                        }
                    }
                    "Stop" => {
                        if let Some((project, _)) = project_from_id(&state, id) {
                            let service = self.0.clone();
                            thread::spawn(move || {
                                let _ = Command::new("podman")
                                    .args(["stop", &format!("tillandsias-{}-forge", project)])
                                    .status();
                                let _ = futures::executor::block_on(
                                    service.rebuild_after_state_change(),
                                );
                            });
                        }
                    }
                    "OpenCode Web" | "OpenCode" | "Claude" => {
                        if let Some(agent) = parse_seedling_label(&label) {
                            handle_select_agent(self.0.clone(), agent);
                        }
                    }
                    _ => {}
                }
            }
        }

        Ok((0, true))
    }

    async fn event_group(
        &self,
        ids: Vec<i32>,
        event_id: &str,
        _data: OwnedValue,
        timestamp: u32,
    ) -> fdo::Result<Vec<(i32, i32, bool)>> {
        let mut out = Vec::new();
        for id in ids {
            let (result, handled) = self
                .event(id, event_id, ov(Value::from(0u32)), timestamp)
                .await?;
            out.push((id, result, handled));
        }
        Ok(out)
    }

    #[zbus(signal)]
    async fn layout_updated(
        ctxt: &SignalContext<'_>,
        revision: u32,
        parent: i32,
    ) -> zbus::Result<()>;
}

fn flatten_layout(node: &MenuNode, out: &mut Vec<(i32, HashMap<String, OwnedValue>)>) {
    let props = node
        .1
        .iter()
        .map(|(key, value)| {
            (
                key.clone(),
                value.try_clone().expect("dbusmenu property should clone"),
            )
        })
        .collect();
    out.push((node.0, props));
    for child in &node.2 {
        if let Ok(Value::Structure(structure)) = Value::try_from(child) {
            let fields = structure.fields();
            if fields.len() == 3 {
                let id = i32::try_from(
                    Value::try_from(&fields[0]).unwrap_or_else(|_| Value::from(0i32)),
                )
                .unwrap_or_default();
                let props = HashMap::<String, OwnedValue>::try_from(
                    fields[1]
                        .try_clone()
                        .unwrap_or_else(|_| Value::from(HashMap::<String, OwnedValue>::new())),
                )
                .unwrap_or_default();
                let children = Vec::<OwnedValue>::try_from(
                    fields[2]
                        .try_clone()
                        .unwrap_or_else(|_| Value::from(Vec::<OwnedValue>::new())),
                )
                .unwrap_or_default();
                let child_node = (id, props, children);
                flatten_layout(&child_node, out);
            }
        }
    }
}

fn project_from_id(state: &TrayUiState, id: i32) -> Option<(String, String)> {
    for project in &state.projects {
        let attach = stable_project_item_id(&project.name, "attach-here");
        let maintenance = stable_project_item_id(&project.name, "maintenance");
        let stop = stable_project_item_id(&project.name, "stop");
        if id == attach {
            return Some((project.name.clone(), "attach-here".to_string()));
        }
        if id == maintenance {
            return Some((project.name.clone(), "maintenance".to_string()));
        }
        if id == stop {
            return Some((project.name.clone(), "stop".to_string()));
        }
    }
    None
}

fn parse_seedling_label(label: &str) -> Option<SelectedAgent> {
    match label {
        "OpenCode Web" => Some(SelectedAgent::OpenCodeWeb),
        "OpenCode" => Some(SelectedAgent::OpenCode),
        "Claude" => Some(SelectedAgent::Claude),
        _ => None,
    }
}

fn build_connection(service: Arc<TrayService>) -> Result<Connection, String> {
    let connection = futures::executor::block_on(async {
        let conn = ConnectionBuilder::session()
            .map_err(|e| e.to_string())?
            .name(service.service_name.as_str())
            .map_err(|e| e.to_string())?
            .serve_at(ITEM_PATH, StatusNotifierItemIface(service.clone()))
            .map_err(|e| e.to_string())?
            .serve_at(MENU_PATH, DbusMenuIface(service.clone()))
            .map_err(|e| e.to_string())?
            .build()
            .await
            .map_err(|e| e.to_string())?;
        Ok::<Connection, String>(conn)
    })?;
    Ok(connection)
}

fn register_with_watcher(connection: &Connection, service_name: &str) {
    let name = service_name.to_string();
    let result = futures::executor::block_on(async {
        let proxy = zbus::Proxy::new(
            connection,
            WATCHER_NAME,
            WATCHER_PATH,
            "org.kde.StatusNotifierWatcher",
        )
        .await
        .map_err(|e| e.to_string())?;
        proxy
            .call_method("RegisterStatusNotifierItem", &name)
            .await
            .map_err(|e| e.to_string())?;
        Ok::<(), String>(())
    });
    if let Err(err) = result {
        warn!("StatusNotifierWatcher registration skipped: {err}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_state(selected_agent: SelectedAgent, forge_available: bool) -> TrayUiState {
        TrayUiState {
            root: PathBuf::from("/tmp/tillandsias-test-root"),
            version: "0.1.260506.6".to_string(),
            status_text: if forge_available {
                "✅ Ready".to_string()
            } else {
                "🌱 Setting up...".to_string()
            },
            tray_icon_state: if forge_available {
                TrayIconState::Mature
            } else {
                TrayIconState::Pup
            },
            projects: vec![ProjectEntry {
                name: "alpha".to_string(),
                path: PathBuf::from("/tmp/alpha"),
            }],
            selected_agent,
            forge_available,
            podman_available: true,
            revision: 1,
        }
    }

    fn labels(node: &MenuNode) -> Vec<String> {
        let mut flat = Vec::new();
        flatten_layout(node, &mut flat);
        flat.into_iter()
            .filter_map(|(_, props)| {
                props
                    .get("label")
                    .and_then(|value| value.try_clone().ok())
                    .and_then(|value| String::try_from(value).ok())
            })
            .collect()
    }

    #[test]
    fn seedlings_menu_keeps_default_order_and_active_choice() {
        let state = test_state(SelectedAgent::OpenCodeWeb, true);
        let menu = build_seedlings_submenu(&state);
        let item_labels = labels(&menu);

        assert_eq!(item_labels[0], "Seedlings");
        assert!(item_labels.contains(&"OpenCode Web".to_string()));
        assert!(item_labels.contains(&"OpenCode".to_string()));
        assert!(item_labels.contains(&"Claude".to_string()));

        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);
        let active = flat
            .into_iter()
            .find(|(_, props)| {
                props
                    .get("label")
                    .and_then(|value| value.try_clone().ok())
                    .and_then(|value| String::try_from(value).ok())
                    .as_deref()
                    == Some("OpenCode Web")
            })
            .and_then(|(_, props)| {
                props
                    .get("toggle-state")
                    .and_then(|value| value.try_clone().ok())
            })
            .and_then(|value| i32::try_from(value).ok())
            .unwrap_or_default();
        assert_eq!(active, 1);
    }

    #[test]
    fn project_menu_only_shows_stop_when_web_is_running() {
        let state = test_state(SelectedAgent::OpenCodeWeb, true);
        let project = state.projects[0].clone();

        let running = build_project_submenu_with_running(&state, &project, true);
        let stopped = build_project_submenu_with_running(&state, &project, false);

        assert!(labels(&running).contains(&"Stop".to_string()));
        assert!(!labels(&stopped).contains(&"Stop".to_string()));
    }

    #[test]
    fn launch_command_targets_the_forge_image_and_project_mount() {
        let root = PathBuf::from("/tmp/tillandsias-test-root");
        let project = ProjectEntry {
            name: "alpha".to_string(),
            path: PathBuf::from("/tmp/alpha"),
        };
        let command = build_launch_command(
            &project,
            "tillandsias-forge:v0.1.260506.6",
            LaunchKind::Claude,
            &root,
        );

        assert!(command.contains("podman run --rm"));
        assert!(command.contains("tillandsias-alpha-claude"));
        assert!(command.contains("forge-alpha"));
        assert!(command.contains("entrypoint-forge-claude.sh"));
        assert!(
            command.contains("PROJECT=alpha") || command.contains("PROJECT='alpha'"),
            "{command}"
        );
    }
}

/// Run native tray mode using a pure D-Bus StatusNotifierItem path.
///
/// @trace spec:tray-app, spec:tray-ux, spec:tray-progress-and-icon-states, spec:tray-icon-lifecycle
pub fn run_tray_mode(config_path: Option<String>) -> Result<(), String> {
    let root = super::find_repo_root()?;
    let version = super::VERSION.trim().to_string();
    let state = TrayUiState::new(root.clone(), version.clone(), discover_projects());
    let service = Arc::new(TrayService::new(state));

    if let Some(path) = config_path {
        info!("Tray started with config path: {path}");
    }

    let connection = build_connection(service.clone())?;
    service.attach_connection(connection.clone());
    register_with_watcher(&connection, &service.service_name);

    let runtime =
        tokio::runtime::Runtime::new().map_err(|e| format!("failed to create runtime: {e}"))?;
    runtime.block_on(async move {
        let item_ctxt = SignalContext::new(service.connection(), service.item_path.as_str())
            .map_err(|e| e.to_string())?;
        let menu_ctxt = SignalContext::new(service.connection(), service.menu_path.as_str())
            .map_err(|e| e.to_string())?;
        let _ = StatusNotifierItemIface::new_icon(&item_ctxt).await;
        let _ = StatusNotifierItemIface::new_status(&item_ctxt).await;
        let _ = StatusNotifierItemIface::new_tool_tip(&item_ctxt).await;
        let _ = DbusMenuIface::layout_updated(&menu_ctxt, service.snapshot().revision, 0).await;

        futures::future::pending::<()>().await;
        #[allow(unreachable_code)]
        Ok::<(), String>(())
    })?;

    Ok(())
}
