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
    Completed {
        image_name: String,
    },
    /// A build failed.
    Failed {
        image_name: String,
        reason: String,
    },
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

    /// Destroy an environment (requires 5s hold confirmation)
    Destroy {
        container_name: String,
        genus: TillandsiaGenus,
    },

    /// Open a bash terminal in the project's forge container
    Terminal { project_path: PathBuf },

    /// GitHub Login — run gh auth login in a container
    GitHubLogin,

    /// Clone a remote GitHub repository into ~/src/<name>
    CloneProject { full_name: String, name: String },

    /// Trigger a background refresh of the remote repos list
    RefreshRemoteProjects,

    /// Open settings
    Settings,

    /// Quit the application
    Quit,
}
