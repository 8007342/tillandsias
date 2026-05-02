use std::path::PathBuf;

use crate::genus::TillandsiaGenus;
use crate::project::ProjectChange;

/// Build progress events sent from async build tasks back to the event loop.
#[derive(Debug, Clone)]
pub enum BuildProgressEvent {
    /// A build (image or maintenance) has started.
    Started {
        /// Short name shown in the menu chip.
        image_name: String,
    },
    /// A build completed successfully.
    Completed { image_name: String },
    /// A build failed.
    Failed { image_name: String, reason: String },
}

/// All events flow through this enum into the main `tokio::select!` loop.
#[derive(Debug, Clone)]
pub enum AppEvent {
    /// A project directory was created, modified, or removed.
    FilesystemChange(ProjectChange),

    /// A container changed state.
    ContainerStateChange {
        container_name: String,
        new_state: ContainerState,
    },

    /// User clicked a menu item.
    MenuAction(MenuCommand),

    /// Graceful shutdown requested.
    Shutdown,
}

/// Container lifecycle states mapped to plant lifecycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum ContainerState {
    /// Container is being created/starting (icon: bud)
    Creating,
    /// Container is running and healthy (icon: bloom)
    Running,
    /// Container is shutting down (icon: dried)
    Stopping,
    /// Container has stopped
    Stopped,
    /// Container is being rebuilt (icon: pup)
    Rebuilding,
    /// Container is absent / not found
    Absent,
}

/// Commands dispatched from tray menu interactions.
#[derive(Debug, Clone)]
pub enum MenuCommand {
    /// "Attach Here" on a project
    AttachHere { project_path: PathBuf },

    /// Start a project's runtime
    Start { project_path: PathBuf },

    /// Stop a running environment
    Stop {
        container_name: String,
        genus: TillandsiaGenus,
    },

    /// Stop a per-project OpenCode Web container (and close all its webviews).
    /// @trace spec:opencode-web-session, spec:tray-app
    StopProject { project_path: PathBuf },

    /// Destroy an environment (requires 5s hold confirmation)
    Destroy {
        container_name: String,
        genus: TillandsiaGenus,
    },

    /// Open a bash terminal in the project's forge container
    Terminal { project_path: PathBuf },

    /// Launch a web server container for the project (Serve Here)
    ServeHere { project_path: PathBuf },

    /// Open a bash terminal in the forge container at the root src/ directory
    RootTerminal,

    /// GitHub Login — run gh auth login in a container
    GitHubLogin,

    /// Clone a remote GitHub repository into ~/src/<name>
    CloneProject { full_name: String, name: String },

    /// Trigger a background refresh of the remote repos list
    RefreshRemoteProjects,

    /// Select an AI coding agent (OpenCode or Claude)
    SelectAgent { agent: String },

    /// Select a language for the UI and container LANG propagation.
    /// @trace spec:tray-app
    SelectLanguage { language: String },

    /// Claude Reset Credentials — clear ~/.claude/ so next launch re-authenticates
    ClaudeResetCredentials,

    /// Open settings
    Settings,

    /// Open a browser window (from MCP server in forge container)
    /// @trace spec:browser-mcp-server
    OpenBrowserWindow {
        project: String,
        url: String,
        window_type: String, // "open_safe_window" or "open_debug_window"
    },

    /// Open OpenCode terminal-based IDE for a project.
    /// @trace spec:tray-minimal-ux
    OpenCodeProject { project_path: PathBuf },

    /// Open OpenCode Web for a project (web-based IDE).
    /// @trace spec:browser-isolation-tray-integration
    OpenCodeWebProject { project_path: PathBuf },

    /// Open Claude assistant for a project.
    /// @trace spec:tray-minimal-ux
    ClaudeProject { project_path: PathBuf },

    /// Open maintenance terminal for a project.
    /// @trace spec:tray-minimal-ux
    MaintenanceProject { project_path: PathBuf },

    /// Quit the application
    Quit,
}
