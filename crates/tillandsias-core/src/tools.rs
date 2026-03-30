/// Curated pool of tool/craft emojis for Maintenance container visual identity.
///
/// Each Maintenance terminal gets a unique tool emoji from this pool.
/// Tools are strictly separated from flower emojis (used by Forge/AI containers).
///
/// # Reserved emojis (NOT in this pool)
///
/// - `🛠️` (U+1F6E0+FE0F) — reserved exclusively for the global Root terminal
///   menu item. It MUST NOT be added here.
pub const TOOL_EMOJIS: &[&str] = &[
    "\u{1F527}",        // 🔧
    "\u{1FA9B}",        // 🪛
    "\u{1F529}",        // 🔩
    "\u{2699}\u{FE0F}", // ⚙️
    "\u{1FA9A}",        // 🪚
    "\u{1F528}",        // 🔨
    "\u{1FA9C}",        // 🪜
    "\u{1F9F2}",        // 🧲
    "\u{1FA63}",        // 🪣
    "\u{1F9F0}",        // 🧰
    "\u{1FA9D}",        // 🪝
    "\u{1F517}",        // 🔗
    "\u{1F4D0}",        // 📐
    "\u{1FAA4}",        // 🪤
    "\u{1F9F1}",        // 🧱
    "\u{1FAB5}",        // 🪵
];

/// Look up a tool emoji by index (wrapping).
pub fn tool_emoji(index: usize) -> &'static str {
    TOOL_EMOJIS[index % TOOL_EMOJIS.len()]
}

/// Allocates tool emojis from the pool, avoiding duplicates per project.
///
/// Mirrors the `GenusAllocator` pattern: track (project, index) pairs,
/// allocate next available, release on stop.
pub struct ToolAllocator {
    /// Next index in the round-robin pool.
    next_index: usize,
    /// Currently allocated tool emoji indices per project name.
    allocated: std::collections::HashMap<String, Vec<usize>>,
}

impl ToolAllocator {
    pub fn new() -> Self {
        Self {
            next_index: 0,
            allocated: std::collections::HashMap::new(),
        }
    }

    /// Allocate a tool emoji for a project. Returns a different tool if the
    /// project already has one or more maintenance terminals running.
    pub fn allocate(&mut self, project: &str) -> Option<&'static str> {
        let in_use = self.allocated.entry(project.to_string()).or_default();
        let pool_len = TOOL_EMOJIS.len();

        // Find next available tool not already used by this project
        for _ in 0..pool_len {
            let candidate_idx = self.next_index % pool_len;
            self.next_index += 1;
            if !in_use.contains(&candidate_idx) {
                in_use.push(candidate_idx);
                return Some(TOOL_EMOJIS[candidate_idx]);
            }
        }

        // Pool exhausted for this project
        None
    }

    /// Release a tool emoji when a maintenance container stops.
    pub fn release(&mut self, project: &str, emoji: &str) {
        if let Some(in_use) = self.allocated.get_mut(project) {
            if let Some(idx) = TOOL_EMOJIS.iter().position(|&e| e == emoji) {
                in_use.retain(|&i| i != idx);
                if in_use.is_empty() {
                    self.allocated.remove(project);
                }
            }
        }
    }

    /// Seed the allocator from a list of already-running containers.
    ///
    /// Called once at event loop startup when `state.running` has been
    /// pre-populated from `podman ps` (graceful restart). Marks every
    /// Maintenance container's tool emoji as in-use so that subsequent
    /// `allocate()` calls do not collide with restored environments.
    pub fn seed_from_running(&mut self, running: &[crate::state::ContainerInfo]) {
        for container in running {
            if container.container_type != crate::state::ContainerType::Maintenance {
                continue;
            }
            if container.display_emoji.is_empty() {
                continue;
            }
            if let Some(idx) = TOOL_EMOJIS
                .iter()
                .position(|&e| e == container.display_emoji)
            {
                let in_use = self
                    .allocated
                    .entry(container.project_name.clone())
                    .or_default();
                if !in_use.contains(&idx) {
                    in_use.push(idx);
                }
            }
        }
    }
}

impl Default for ToolAllocator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pool_size_is_16() {
        assert_eq!(TOOL_EMOJIS.len(), 16);
    }

    #[test]
    fn tool_emojis_are_unique() {
        let mut seen = std::collections::HashSet::new();
        for emoji in TOOL_EMOJIS {
            assert!(seen.insert(*emoji), "Duplicate tool emoji: {emoji}");
        }
    }

    #[test]
    fn tool_emoji_wraps() {
        assert_eq!(tool_emoji(0), TOOL_EMOJIS[0]);
        assert_eq!(tool_emoji(16), TOOL_EMOJIS[0]);
        assert_eq!(tool_emoji(17), TOOL_EMOJIS[1]);
    }

    #[test]
    fn allocator_round_robin() {
        let mut alloc = ToolAllocator::new();
        let t1 = alloc.allocate("project-a").unwrap();
        let t2 = alloc.allocate("project-b").unwrap();
        assert_ne!(t1, t2);
    }

    #[test]
    fn allocator_no_duplicate_for_same_project() {
        let mut alloc = ToolAllocator::new();
        let t1 = alloc.allocate("project-a").unwrap();
        let t2 = alloc.allocate("project-a").unwrap();
        assert_ne!(t1, t2);
    }

    #[test]
    fn allocator_pool_exhaustion() {
        let mut alloc = ToolAllocator::new();
        for _ in 0..16 {
            assert!(alloc.allocate("project-a").is_some());
        }
        // 17th allocation should fail — pool exhausted
        assert!(alloc.allocate("project-a").is_none());
    }

    #[test]
    fn allocator_release_and_reuse() {
        let mut alloc = ToolAllocator::new();
        let t1 = alloc.allocate("project-a").unwrap();
        alloc.release("project-a", t1);
        let t2 = alloc.allocate("project-a").unwrap();
        assert!(TOOL_EMOJIS.contains(&t2));
    }
}
