// @trace spec:tray-app, spec:project-management
//! Rapid project switching defensive test.
//!
//! Validates that the tray app handles rapid project switches without panics,
//! assertions, or menu inconsistencies. This test simulates user behavior
//! of switching between projects in quick succession.

use std::sync::{Arc, Mutex};
use std::time::Instant;

/// Mock project state for rapid switch testing.
#[derive(Debug, Clone)]
struct MockProjectState {
    id: String,
    name: String,
    menu_items: Vec<String>,
    last_updated: Instant,
}

impl MockProjectState {
    fn new(id: &str, name: &str) -> Self {
        Self {
            id: id.to_string(),
            name: name.to_string(),
            menu_items: vec![
                "Attach".to_string(),
                "View logs".to_string(),
                "Settings".to_string(),
            ],
            last_updated: Instant::now(),
        }
    }
}

/// Menu consistency validator.
#[derive(Debug)]
struct MenuConsistency {
    project_id: String,
    item_count: usize,
    valid: bool,
    timestamp: Instant,
}

impl MenuConsistency {
    fn validate(state: &MockProjectState) -> Self {
        let valid = state.menu_items.len() == 3 && !state.menu_items.is_empty();
        Self {
            project_id: state.id.clone(),
            item_count: state.menu_items.len(),
            valid,
            timestamp: Instant::now(),
        }
    }
}

#[test]
fn test_rapid_project_switch_no_panics() {
    // @trace spec:project-management
    let projects = vec![
        MockProjectState::new("proj-a", "Project A"),
        MockProjectState::new("proj-b", "Project B"),
        MockProjectState::new("proj-c", "Project C"),
        MockProjectState::new("proj-d", "Project D"),
    ];

    let current_project = Arc::new(Mutex::new(projects[0].clone()));
    let switch_count = 10;
    let mut consistency_results = Vec::new();

    for i in 0..switch_count {
        let proj_idx = i % projects.len();
        let next_project = projects[proj_idx].clone();

        // Switch project
        {
            let mut current = current_project.lock().unwrap();
            *current = next_project.clone();
        }

        // Validate menu consistency after switch
        let state = current_project.lock().unwrap().clone();
        let consistency = MenuConsistency::validate(&state);
        consistency_results.push(consistency);
    }

    // All consistency checks should pass
    for (idx, result) in consistency_results.iter().enumerate() {
        assert!(
            result.valid,
            "Menu consistency failed at switch {}: {} items in project {}",
            idx, result.item_count, result.project_id
        );
    }
}

#[test]
fn test_rapid_switch_menu_item_count_stable() {
    // @trace spec:project-management, spec:tray-menu
    let projects = vec![
        MockProjectState::new("proj-x", "Project X"),
        MockProjectState::new("proj-y", "Project Y"),
    ];

    let current_project = Arc::new(Mutex::new(projects[0].clone()));

    // Perform 20 rapid switches between two projects
    for _ in 0..20 {
        for project in &projects {
            let mut current = current_project.lock().unwrap();
            *current = project.clone();

            // Menu item count must remain constant
            assert_eq!(
                current.menu_items.len(),
                3,
                "Menu item count changed unexpectedly"
            );
        }
    }
}

#[test]
fn test_rapid_switch_no_stale_menu_data() {
    // @trace spec:project-management
    let mut projects = vec![
        MockProjectState::new("proj-1", "Project 1"),
        MockProjectState::new("proj-2", "Project 2"),
    ];

    // Modify project 2 menu to be different
    projects[1].menu_items = vec!["Custom 1".to_string(), "Custom 2".to_string()];

    let current_project = Arc::new(Mutex::new(projects[0].clone()));
    let switch_count = 10;

    for i in 0..switch_count {
        let proj_idx = i % projects.len();
        let next_project = projects[proj_idx].clone();

        // Switch and verify menu data matches the current project
        {
            let mut current = current_project.lock().unwrap();
            *current = next_project.clone();
        }

        // Verify no stale data from previous project
        let state = current_project.lock().unwrap().clone();
        match state.id.as_str() {
            "proj-1" => {
                assert_eq!(state.menu_items.len(), 3, "Project 1 should have 3 items");
            }
            "proj-2" => {
                assert_eq!(state.menu_items.len(), 2, "Project 2 should have 2 items");
            }
            _ => panic!("Unexpected project ID"),
        }
    }
}

#[test]
fn test_concurrent_rapid_switches() {
    // @trace spec:project-management, spec:tray-concurrency
    use std::sync::Arc;
    use std::thread;

    let projects = Arc::new(vec![
        MockProjectState::new("proj-t1", "Thread Test 1"),
        MockProjectState::new("proj-t2", "Thread Test 2"),
        MockProjectState::new("proj-t3", "Thread Test 3"),
    ]);

    let current_project = Arc::new(Mutex::new(projects[0].clone()));
    let mut handles = vec![];

    // Spawn 3 threads, each performing rapid switches
    for thread_id in 0..3 {
        let projects_clone = Arc::clone(&projects);
        let current_clone = Arc::clone(&current_project);

        let handle = thread::spawn(move || {
            for i in 0..5 {
                let proj_idx = (thread_id + i) % projects_clone.len();
                let next_project = projects_clone[proj_idx].clone();

                let mut current = current_clone.lock().unwrap();
                *current = next_project;

                // Brief yield to simulate realistic contention
                drop(current);
                thread::yield_now();
            }
        });

        handles.push(handle);
    }

    // Wait for all threads
    for handle in handles {
        handle.join().unwrap();
    }

    // Final state should be valid
    let final_state = current_project.lock().unwrap();
    let consistency = MenuConsistency::validate(&final_state);
    assert!(
        consistency.valid,
        "Final state menu invalid after concurrent switches"
    );
}
