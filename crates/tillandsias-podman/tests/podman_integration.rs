//! Integration tests for podman container lifecycle.
//!
//! These tests require a running podman daemon and are marked `#[ignore]`
//! so they don't run in CI by default. Run with:
//!
//! ```sh
//! cargo test --package tillandsias-podman -- --ignored
//! ```

use tillandsias_podman::PodmanClient;

/// Full start/inspect/stop cycle with a minimal alpine container.
///
/// Requires podman to be available and able to pull images.
#[tokio::test]
#[ignore]
async fn podman_start_inspect_stop_cycle() {
    let client = PodmanClient::new();

    // Skip if podman is not available
    if !client.is_available().await {
        eprintln!("podman not available, skipping integration test");
        return;
    }

    let container_name = "tillandsias-integration-test";

    // Clean up any leftover container from a previous failed run
    let _ = client.stop_container(container_name, 5).await;
    let _ = client.remove_container(container_name).await;

    // Start a minimal alpine container that sleeps
    let args = vec![
        "-d".to_string(),
        "--name".to_string(),
        container_name.to_string(),
        "--rm".to_string(),
        "--cap-drop=ALL".to_string(),
        "--security-opt=no-new-privileges".to_string(),
        "--userns=keep-id".to_string(),
        "docker.io/library/alpine:latest".to_string(),
        "sleep".to_string(),
        "300".to_string(),
    ];

    let result = client.run_container(&args).await;
    assert!(
        result.is_ok(),
        "Failed to start container: {:?}",
        result.err()
    );

    // Wait briefly for container to start
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;

    // Inspect the container
    let inspect = client.inspect_container(container_name).await;
    assert!(inspect.is_ok(), "Failed to inspect container");
    let inspect = inspect.unwrap();
    assert_eq!(inspect.name, container_name);
    assert!(
        inspect.state == "running" || inspect.state == "Running",
        "Expected running state, got: {}",
        inspect.state
    );

    // List containers with our prefix
    let list = client.list_containers("tillandsias-integration").await;
    assert!(list.is_ok(), "Failed to list containers");
    let list = list.unwrap();
    assert!(
        list.iter().any(|c| c.name == container_name),
        "Container not found in list"
    );

    // Stop the container gracefully
    let stop_result = client.stop_container(container_name, 10).await;
    assert!(stop_result.is_ok(), "Failed to stop container");

    // Verify container is gone (--rm flag should auto-remove)
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let inspect_after = client.inspect_container(container_name).await;
    assert!(
        inspect_after.is_err(),
        "Container should be removed after stop with --rm"
    );
}
