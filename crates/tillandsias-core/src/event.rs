use std::path::PathBuf;

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
///
/// Pruned by `simplified-tray-ux`: the tray surfaces a near-flat menu with
/// only Launch / Maintenance terminal / Sign in / Quit / Language. CLI mode
/// keeps `AttachHere` because `tillandsias <path>` still drives that path.
///
/// @trace spec:simplified-tray-ux
#[derive(Debug, Clone)]
pub enum MenuCommand {
    /// "Attach Here" — kept for CLI mode (`tillandsias <path>`); the tray
    /// no longer offers it directly.
    AttachHere { project_path: PathBuf },

    /// GitHub Login — run gh auth login in a container.
    GitHubLogin,

    /// Clone a remote GitHub repository into ~/src/<name>.
    CloneProject { full_name: String, name: String },

    /// Trigger a background refresh of the remote repos list.
    RefreshRemoteProjects,

    /// Select a language for the UI and container LANG propagation.
    /// @trace spec:tray-app
    SelectLanguage { language: String },

    /// @trace spec:simplified-tray-ux
    /// Launch the project's forge in opencode-web mode (the only tray-driven
    /// launch option). Reuses an existing forge container if one is running;
    /// otherwise spawns a fresh one. Subsequent clicks reopen another browser
    /// window pointing at the same container — opencode-web supports
    /// concurrent sessions in a single process.
    Launch { project_path: PathBuf },

    /// @trace spec:tray-app
    /// Open a host terminal running `podman exec -it` inside the project's
    /// running forge container. Multiple maintenance terminals can be open
    /// against the same forge.
    MaintenanceTerminal { project_path: PathBuf },

    /// Quit the application.
    Quit,
}
