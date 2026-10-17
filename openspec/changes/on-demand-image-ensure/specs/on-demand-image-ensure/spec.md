## ADDED Requirements

### Requirement: Every container launch ensures its image through one seam

Any code path that starts a Tillandsias-built container (`tillandsias-<name>:v<version>`) outside `tillandsias --init` SHALL first call the one image-ensure seam (`ensure_image_exists`) for that image. The seam SHALL resolve the image's declared base image first, under its own lock. A launch site SHALL NOT start a container whose image it has neither listed in the launch-images table for its site nor ensured inline, and a guard SHALL refuse the build when a versioned image literal appears in a module that does neither. The guard SHALL refuse when it finds zero image literals.

#### Scenario: a forge asks for its first browser window on a host that never ran --init

- **WHEN** the chromium-framework image is absent and the forge's MCP `browser.open` reaches the tray
- **THEN** the tray builds chromium-core and chromium-framework once, reports the build's progress to the caller, and opens the window; the reply carries a first-use notice
- **AND** a second `browser.open` opens without a build

#### Scenario: a launch site is added without listing its image

- **WHEN** a module gains `ContainerSpec::new("tillandsias-x:v…")` and neither the launch-images table nor an inline ensure names `x`
- **THEN** the launch-images guard fails and names the module and the image

### Requirement: A failed on-demand build is remembered and not retried blindly

When an on-demand build fails, the seam SHALL record a failure marker keyed on the image name and the identity's source digest, carrying the attempt count, the failure's cause, the log path and the next time an automatic retry is allowed (10 minutes after the first failure, 1 hour after the second, never after the third). While a marker matches the current identity and the retry time has not passed, every ensure for that image SHALL refuse within seconds, without spawning a build, with `refused:image-ensure:<image>:build-failed-previously`, the cause, the log and the remedy. The marker SHALL be removed when the image's source digest changes, when a build succeeds, or when the operator retries explicitly. A dependent image SHALL refuse with its base's marker and SHALL NOT record a marker of its own for a base failure. No remedy text SHALL say the build is retried on each launch.

#### Scenario: the same broken input is launched twice

- **WHEN** an image's Containerfile fails to build and a second launch needs the same image within 10 minutes
- **THEN** the second launch refuses within 5 seconds naming the first failure, and `podman build` is not run

#### Scenario: the input is fixed

- **WHEN** a file in the image's build context changes after a recorded failure
- **THEN** the next ensure ignores the marker, removes it, and builds

#### Scenario: the operator retries

- **WHEN** the operator runs `tillandsias --retry-image <name>` or picks the tray's "Retry build" item
- **THEN** the marker is removed and the image is force-rebuilt in the foreground with progress; a failure records a fresh marker with attempts=1

#### Scenario: a successful build leaves no marker

- **WHEN** an image builds successfully on first use
- **THEN** no marker exists for it and the next ensure decides Skip

### Requirement: An on-demand build is bounded in disk and host resources

Before building, the seam SHALL compare free space on the podman graph root with the image's declared need plus 1 GiB and SHALL refuse `refused:image-ensure:<image>:disk:<free>/<need>` without building and without recording a failure marker when space is short. The build child SHALL run under a resource scope (systemd-run --user with CPUWeight, IOWeight and MemoryHigh when available, else nice) unless the operator opts out by environment. The seam SHALL keep the per-image lock so two processes never build one image concurrently, and a lock waiter SHALL re-read the marker and the image under the lock before deciding.

#### Scenario: a floor-tier host is short on disk

- **WHEN** free space on the graph root is below the forge-base need
- **THEN** the forge launch refuses with the disk verdict and the two sizes, no build starts, and the next launch after space is freed builds

#### Scenario: two launches race on one missing image

- **WHEN** two processes ensure the same absent image at once
- **THEN** one builds, the other waits on the lock and then decides Skip (or refuses on the winner's marker); the image is built once

### Requirement: Every ensure decision is visible

Every ensure SHALL print one verdict line naming the image, the decision (Skip, Retag, Build, ForceRebuild or Refused), the identity's source digest, the digest of the image currently under the canonical tag (or none), the reason and the marker state. A running on-demand build SHALL report `Preparing <label> (first use)` and `step n/m` to the tray status and to the requesting caller (CLI stderr, MCP reply).

#### Scenario: two installs under one version string

- **WHEN** a binary rebuilt from a different tree with the same version string launches the forge
- **THEN** the verdict line shows a source digest different from the one the present image carries, and the decision is Build
