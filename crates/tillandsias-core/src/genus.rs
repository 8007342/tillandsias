/// Curated pool of tillandsia genera used as visual namespaces for environments.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub enum TillandsiaGenus {
    Aeranthos,
    Ionantha,
    Xerographica,
    CaputMedusae,
    Bulbosa,
    Tectorum,
    Stricta,
    Usneoides,
    // --- 16 new genera (v0.1.39) ---
    Cyanea,
    Funckiana,
    Magnusiana,
    Bergeri,
    Brachycaulos,
    Harrisii,
    Duratii,
    Gardneri,
    Seleriana,
    Fasciculata,
    Leiboldiana,
    Flabellata,
    Paleacea,
    Recurvata,
    Kolbii,
    Pruinosa,
}

impl TillandsiaGenus {
    /// All genera in pool order.
    pub const ALL: &[TillandsiaGenus] = &[
        Self::Aeranthos,
        Self::Ionantha,
        Self::Xerographica,
        Self::CaputMedusae,
        Self::Bulbosa,
        Self::Tectorum,
        Self::Stricta,
        Self::Usneoides,
        Self::Cyanea,
        Self::Funckiana,
        Self::Magnusiana,
        Self::Bergeri,
        Self::Brachycaulos,
        Self::Harrisii,
        Self::Duratii,
        Self::Gardneri,
        Self::Seleriana,
        Self::Fasciculata,
        Self::Leiboldiana,
        Self::Flabellata,
        Self::Paleacea,
        Self::Recurvata,
        Self::Kolbii,
        Self::Pruinosa,
    ];

    /// The original 8 genera that have dedicated SVG icon assets.
    const GENERA_WITH_ICONS: &[TillandsiaGenus] = &[
        Self::Aeranthos,
        Self::Ionantha,
        Self::Xerographica,
        Self::CaputMedusae,
        Self::Bulbosa,
        Self::Tectorum,
        Self::Stricta,
        Self::Usneoides,
    ];

    /// Whether this genus has dedicated SVG/PNG icon assets.
    pub fn has_dedicated_icons(&self) -> bool {
        Self::GENERA_WITH_ICONS.contains(self)
    }

    /// Lowercase slug for container naming and filesystem paths.
    pub fn slug(&self) -> &'static str {
        match self {
            Self::Aeranthos => "aeranthos",
            Self::Ionantha => "ionantha",
            Self::Xerographica => "xerographica",
            Self::CaputMedusae => "caput-medusae",
            Self::Bulbosa => "bulbosa",
            Self::Tectorum => "tectorum",
            Self::Stricta => "stricta",
            Self::Usneoides => "usneoides",
            Self::Cyanea => "cyanea",
            Self::Funckiana => "funckiana",
            Self::Magnusiana => "magnusiana",
            Self::Bergeri => "bergeri",
            Self::Brachycaulos => "brachycaulos",
            Self::Harrisii => "harrisii",
            Self::Duratii => "duratii",
            Self::Gardneri => "gardneri",
            Self::Seleriana => "seleriana",
            Self::Fasciculata => "fasciculata",
            Self::Leiboldiana => "leiboldiana",
            Self::Flabellata => "flabellata",
            Self::Paleacea => "paleacea",
            Self::Recurvata => "recurvata",
            Self::Kolbii => "kolbii",
            Self::Pruinosa => "pruinosa",
        }
    }

    /// Parse from a slug string.
    pub fn from_slug(s: &str) -> Option<Self> {
        match s {
            "aeranthos" => Some(Self::Aeranthos),
            "ionantha" => Some(Self::Ionantha),
            "xerographica" => Some(Self::Xerographica),
            "caput-medusae" => Some(Self::CaputMedusae),
            "bulbosa" => Some(Self::Bulbosa),
            "tectorum" => Some(Self::Tectorum),
            "stricta" => Some(Self::Stricta),
            "usneoides" => Some(Self::Usneoides),
            "cyanea" => Some(Self::Cyanea),
            "funckiana" => Some(Self::Funckiana),
            "magnusiana" => Some(Self::Magnusiana),
            "bergeri" => Some(Self::Bergeri),
            "brachycaulos" => Some(Self::Brachycaulos),
            "harrisii" => Some(Self::Harrisii),
            "duratii" => Some(Self::Duratii),
            "gardneri" => Some(Self::Gardneri),
            "seleriana" => Some(Self::Seleriana),
            "fasciculata" => Some(Self::Fasciculata),
            "leiboldiana" => Some(Self::Leiboldiana),
            "flabellata" => Some(Self::Flabellata),
            "paleacea" => Some(Self::Paleacea),
            "recurvata" => Some(Self::Recurvata),
            "kolbii" => Some(Self::Kolbii),
            "pruinosa" => Some(Self::Pruinosa),
            _ => None,
        }
    }

    /// Display name for tray menus.
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Aeranthos => "Aeranthos",
            Self::Ionantha => "Ionantha",
            Self::Xerographica => "Xerographica",
            Self::CaputMedusae => "Caput-Medusae",
            Self::Bulbosa => "Bulbosa",
            Self::Tectorum => "Tectorum",
            Self::Stricta => "Stricta",
            Self::Usneoides => "Usneoides",
            Self::Cyanea => "Cyanea",
            Self::Funckiana => "Funckiana",
            Self::Magnusiana => "Magnusiana",
            Self::Bergeri => "Bergeri",
            Self::Brachycaulos => "Brachycaulos",
            Self::Harrisii => "Harrisii",
            Self::Duratii => "Duratii",
            Self::Gardneri => "Gardneri",
            Self::Seleriana => "Seleriana",
            Self::Fasciculata => "Fasciculata",
            Self::Leiboldiana => "Leiboldiana",
            Self::Flabellata => "Flabellata",
            Self::Paleacea => "Paleacea",
            Self::Recurvata => "Recurvata",
            Self::Kolbii => "Kolbii",
            Self::Pruinosa => "Pruinosa",
        }
    }

    /// Unique flower emoji for this genus — used in terminal window titles and menu labels.
    pub fn flower(&self) -> &'static str {
        match self {
            Self::Aeranthos => "\u{1F338}",       // 🌸
            Self::Ionantha => "\u{1F33A}",        // 🌺
            Self::Xerographica => "\u{1F33B}",    // 🌻
            Self::CaputMedusae => "\u{1F33C}",    // 🌼
            Self::Bulbosa => "\u{1F337}",         // 🌷
            Self::Tectorum => "\u{1F339}",        // 🌹
            Self::Stricta => "\u{1F3F5}\u{FE0F}", // 🏵️
            Self::Usneoides => "\u{1F4AE}",       // 💮
            Self::Cyanea => "\u{1FABB}",          // 🪻
            Self::Funckiana => "\u{1F33E}",       // 🌾
            Self::Magnusiana => "\u{1FAB7}",      // 🪷
            Self::Bergeri => "\u{1F490}",         // 💐
            Self::Brachycaulos => "\u{1F38B}",    // 🎋
            Self::Harrisii => "\u{1F340}",        // 🍀
            Self::Duratii => "\u{1F334}",         // 🌴
            Self::Gardneri => "\u{1F38D}",        // 🎍
            Self::Seleriana => "\u{1F335}",       // 🌵
            Self::Fasciculata => "\u{1F384}",     // 🎄
            Self::Leiboldiana => "\u{1F343}",     // 🍃
            Self::Flabellata => "\u{1F341}",      // 🍁
            Self::Paleacea => "\u{1F332}",        // 🌲
            Self::Recurvata => "\u{1F333}",       // 🌳
            Self::Kolbii => "\u{2618}\u{FE0F}",   // ☘️
            Self::Pruinosa => "\u{1F391}",        // 🎑
        }
    }
}

/// Plant lifecycle states mapped to container lifecycle for iconography.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum PlantLifecycle {
    /// Container creating/booting — small green plant, no bloom
    Bud,
    /// Container running and healthy — colorful flower in bloom
    Bloom,
    /// Container stopping/stopped — faded/brown flower
    Dried,
    /// Container rebuilding/spawning — small plant growing from parent
    Pup,
}

impl PlantLifecycle {
    /// Map from container state to plant lifecycle.
    pub fn from_container_state(state: &crate::event::ContainerState) -> Self {
        match state {
            crate::event::ContainerState::Creating => Self::Bud,
            crate::event::ContainerState::Running => Self::Bloom,
            crate::event::ContainerState::Stopping => Self::Dried,
            crate::event::ContainerState::Stopped => Self::Dried,
            crate::event::ContainerState::Rebuilding => Self::Pup,
            crate::event::ContainerState::Absent => Self::Dried,
        }
    }
}

/// Tray icon state — maps overall system state to a specific tray icon variant.
/// Independent of the per-environment `TillandsiaGenus` and `PlantLifecycle` types.
///
/// All tray icon variants are derived from the Ionantha genus:
/// - `Base` → Ionantha bud (idle, no environments running)
/// - `Building` → Ionantha bloom (at least one environment active)
/// - `Decay` → Ionantha dried (all environments stopped)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub enum TrayIconState {
    /// Idle or projects detected, none running — Ionantha bud
    Base,
    /// At least one environment starting or running — Ionantha bloom
    Building,
    /// Environments present but all stopped or stopping — Ionantha dried
    Decay,
}

/// Allocates genera from the pool, avoiding duplicates per project.
pub struct GenusAllocator {
    /// Next index in the round-robin pool
    next_index: usize,
    /// Currently allocated genera per project name
    allocated: std::collections::HashMap<String, Vec<TillandsiaGenus>>,
}

impl GenusAllocator {
    pub fn new() -> Self {
        Self {
            next_index: 0,
            allocated: std::collections::HashMap::new(),
        }
    }

    /// Allocate a genus for a project. Returns a different genus if the project
    /// already has one or more environments running.
    pub fn allocate(&mut self, project_name: &str) -> Option<TillandsiaGenus> {
        let in_use = self.allocated.entry(project_name.to_string()).or_default();
        let pool = TillandsiaGenus::ALL;

        // Find next available genus not already used by this project
        for _ in 0..pool.len() {
            let candidate = pool[self.next_index % pool.len()];
            self.next_index += 1;
            if !in_use.contains(&candidate) {
                in_use.push(candidate);
                return Some(candidate);
            }
        }

        // Pool exhausted for this project
        None
    }

    /// Release a genus when an environment stops.
    pub fn release(&mut self, project_name: &str, genus: TillandsiaGenus) {
        if let Some(in_use) = self.allocated.get_mut(project_name) {
            in_use.retain(|g| *g != genus);
            if in_use.is_empty() {
                self.allocated.remove(project_name);
            }
        }
    }

    /// Seed the allocator from a list of already-running containers.
    ///
    /// Called once at event loop startup when `state.running` has been
    /// pre-populated from `podman ps` (graceful restart).  Marks every
    /// `(project_name, genus)` pair as in-use so that subsequent
    /// `allocate()` calls do not collide with restored environments.
    pub fn seed_from_running(&mut self, running: &[crate::state::ContainerInfo]) {
        for container in running {
            let in_use = self
                .allocated
                .entry(container.project_name.clone())
                .or_default();
            if !in_use.contains(&container.genus) {
                in_use.push(container.genus);
            }
        }
    }
}

impl Default for GenusAllocator {
    fn default() -> Self {
        Self::new()
    }
}

/// Compile-time embedded SVG icons for each genus + lifecycle combination.
/// Uses `include_bytes!` to embed all SVGs into the binary.
///
/// The original 8 genera have dedicated SVG assets. The 16 new genera
/// fall back to Ionantha icons (same visual, distinct flower emoji in menus).
pub mod icons {
    use super::{PlantLifecycle, TillandsiaGenus};

    // Aeranthos
    const AERANTHOS_BUD: &[u8] = include_bytes!("../../../assets/icons/aeranthos/bud.svg");
    const AERANTHOS_BLOOM: &[u8] = include_bytes!("../../../assets/icons/aeranthos/bloom.svg");
    const AERANTHOS_DRIED: &[u8] = include_bytes!("../../../assets/icons/aeranthos/dried.svg");
    const AERANTHOS_PUP: &[u8] = include_bytes!("../../../assets/icons/aeranthos/pup.svg");

    // Ionantha
    const IONANTHA_BUD: &[u8] = include_bytes!("../../../assets/icons/ionantha/bud.svg");
    const IONANTHA_BLOOM: &[u8] = include_bytes!("../../../assets/icons/ionantha/bloom.svg");
    const IONANTHA_DRIED: &[u8] = include_bytes!("../../../assets/icons/ionantha/dried.svg");
    const IONANTHA_PUP: &[u8] = include_bytes!("../../../assets/icons/ionantha/pup.svg");

    // Xerographica
    const XEROGRAPHICA_BUD: &[u8] = include_bytes!("../../../assets/icons/xerographica/bud.svg");
    const XEROGRAPHICA_BLOOM: &[u8] =
        include_bytes!("../../../assets/icons/xerographica/bloom.svg");
    const XEROGRAPHICA_DRIED: &[u8] =
        include_bytes!("../../../assets/icons/xerographica/dried.svg");
    const XEROGRAPHICA_PUP: &[u8] = include_bytes!("../../../assets/icons/xerographica/pup.svg");

    // CaputMedusae
    const CAPUT_MEDUSAE_BUD: &[u8] = include_bytes!("../../../assets/icons/caput-medusae/bud.svg");
    const CAPUT_MEDUSAE_BLOOM: &[u8] =
        include_bytes!("../../../assets/icons/caput-medusae/bloom.svg");
    const CAPUT_MEDUSAE_DRIED: &[u8] =
        include_bytes!("../../../assets/icons/caput-medusae/dried.svg");
    const CAPUT_MEDUSAE_PUP: &[u8] = include_bytes!("../../../assets/icons/caput-medusae/pup.svg");

    // Bulbosa
    const BULBOSA_BUD: &[u8] = include_bytes!("../../../assets/icons/bulbosa/bud.svg");
    const BULBOSA_BLOOM: &[u8] = include_bytes!("../../../assets/icons/bulbosa/bloom.svg");
    const BULBOSA_DRIED: &[u8] = include_bytes!("../../../assets/icons/bulbosa/dried.svg");
    const BULBOSA_PUP: &[u8] = include_bytes!("../../../assets/icons/bulbosa/pup.svg");

    // Tectorum
    const TECTORUM_BUD: &[u8] = include_bytes!("../../../assets/icons/tectorum/bud.svg");
    const TECTORUM_BLOOM: &[u8] = include_bytes!("../../../assets/icons/tectorum/bloom.svg");
    const TECTORUM_DRIED: &[u8] = include_bytes!("../../../assets/icons/tectorum/dried.svg");
    const TECTORUM_PUP: &[u8] = include_bytes!("../../../assets/icons/tectorum/pup.svg");

    // Stricta
    const STRICTA_BUD: &[u8] = include_bytes!("../../../assets/icons/stricta/bud.svg");
    const STRICTA_BLOOM: &[u8] = include_bytes!("../../../assets/icons/stricta/bloom.svg");
    const STRICTA_DRIED: &[u8] = include_bytes!("../../../assets/icons/stricta/dried.svg");
    const STRICTA_PUP: &[u8] = include_bytes!("../../../assets/icons/stricta/pup.svg");

    // Usneoides
    const USNEOIDES_BUD: &[u8] = include_bytes!("../../../assets/icons/usneoides/bud.svg");
    const USNEOIDES_BLOOM: &[u8] = include_bytes!("../../../assets/icons/usneoides/bloom.svg");
    const USNEOIDES_DRIED: &[u8] = include_bytes!("../../../assets/icons/usneoides/dried.svg");
    const USNEOIDES_PUP: &[u8] = include_bytes!("../../../assets/icons/usneoides/pup.svg");

    // New genera (16) — no dedicated SVGs, fall back to Ionantha at runtime.

    /// Look up the embedded SVG bytes for a given genus and lifecycle state.
    ///
    /// Genera without dedicated SVG assets fall back to Ionantha icons.
    pub fn icon_svg(genus: TillandsiaGenus, lifecycle: PlantLifecycle) -> &'static [u8] {
        match (genus, lifecycle) {
            (TillandsiaGenus::Aeranthos, PlantLifecycle::Bud) => AERANTHOS_BUD,
            (TillandsiaGenus::Aeranthos, PlantLifecycle::Bloom) => AERANTHOS_BLOOM,
            (TillandsiaGenus::Aeranthos, PlantLifecycle::Dried) => AERANTHOS_DRIED,
            (TillandsiaGenus::Aeranthos, PlantLifecycle::Pup) => AERANTHOS_PUP,

            (TillandsiaGenus::Ionantha, PlantLifecycle::Bud) => IONANTHA_BUD,
            (TillandsiaGenus::Ionantha, PlantLifecycle::Bloom) => IONANTHA_BLOOM,
            (TillandsiaGenus::Ionantha, PlantLifecycle::Dried) => IONANTHA_DRIED,
            (TillandsiaGenus::Ionantha, PlantLifecycle::Pup) => IONANTHA_PUP,

            (TillandsiaGenus::Xerographica, PlantLifecycle::Bud) => XEROGRAPHICA_BUD,
            (TillandsiaGenus::Xerographica, PlantLifecycle::Bloom) => XEROGRAPHICA_BLOOM,
            (TillandsiaGenus::Xerographica, PlantLifecycle::Dried) => XEROGRAPHICA_DRIED,
            (TillandsiaGenus::Xerographica, PlantLifecycle::Pup) => XEROGRAPHICA_PUP,

            (TillandsiaGenus::CaputMedusae, PlantLifecycle::Bud) => CAPUT_MEDUSAE_BUD,
            (TillandsiaGenus::CaputMedusae, PlantLifecycle::Bloom) => CAPUT_MEDUSAE_BLOOM,
            (TillandsiaGenus::CaputMedusae, PlantLifecycle::Dried) => CAPUT_MEDUSAE_DRIED,
            (TillandsiaGenus::CaputMedusae, PlantLifecycle::Pup) => CAPUT_MEDUSAE_PUP,

            (TillandsiaGenus::Bulbosa, PlantLifecycle::Bud) => BULBOSA_BUD,
            (TillandsiaGenus::Bulbosa, PlantLifecycle::Bloom) => BULBOSA_BLOOM,
            (TillandsiaGenus::Bulbosa, PlantLifecycle::Dried) => BULBOSA_DRIED,
            (TillandsiaGenus::Bulbosa, PlantLifecycle::Pup) => BULBOSA_PUP,

            (TillandsiaGenus::Tectorum, PlantLifecycle::Bud) => TECTORUM_BUD,
            (TillandsiaGenus::Tectorum, PlantLifecycle::Bloom) => TECTORUM_BLOOM,
            (TillandsiaGenus::Tectorum, PlantLifecycle::Dried) => TECTORUM_DRIED,
            (TillandsiaGenus::Tectorum, PlantLifecycle::Pup) => TECTORUM_PUP,

            (TillandsiaGenus::Stricta, PlantLifecycle::Bud) => STRICTA_BUD,
            (TillandsiaGenus::Stricta, PlantLifecycle::Bloom) => STRICTA_BLOOM,
            (TillandsiaGenus::Stricta, PlantLifecycle::Dried) => STRICTA_DRIED,
            (TillandsiaGenus::Stricta, PlantLifecycle::Pup) => STRICTA_PUP,

            (TillandsiaGenus::Usneoides, PlantLifecycle::Bud) => USNEOIDES_BUD,
            (TillandsiaGenus::Usneoides, PlantLifecycle::Bloom) => USNEOIDES_BLOOM,
            (TillandsiaGenus::Usneoides, PlantLifecycle::Dried) => USNEOIDES_DRIED,
            (TillandsiaGenus::Usneoides, PlantLifecycle::Pup) => USNEOIDES_PUP,

            // All new genera without dedicated SVGs fall back to Ionantha
            (_, PlantLifecycle::Bud) => IONANTHA_BUD,
            (_, PlantLifecycle::Bloom) => IONANTHA_BLOOM,
            (_, PlantLifecycle::Dried) => IONANTHA_DRIED,
            (_, PlantLifecycle::Pup) => IONANTHA_PUP,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pool_size_is_24() {
        assert_eq!(TillandsiaGenus::ALL.len(), 24);
    }

    #[test]
    fn flower_unique_per_genus() {
        let mut seen = std::collections::HashSet::new();
        for genus in TillandsiaGenus::ALL {
            let flower = genus.flower();
            assert!(
                seen.insert(flower),
                "Duplicate flower '{flower}' for genus {:?}",
                genus
            );
        }
        assert_eq!(
            seen.len(),
            TillandsiaGenus::ALL.len(),
            "All genera must have distinct flowers"
        );
    }

    #[test]
    fn flower_no_gaps() {
        // Every genus must return a non-empty flower string
        for genus in TillandsiaGenus::ALL {
            assert!(
                !genus.flower().is_empty(),
                "flower() is empty for {:?}",
                genus
            );
        }
    }

    #[test]
    fn slug_roundtrip() {
        for genus in TillandsiaGenus::ALL {
            assert_eq!(TillandsiaGenus::from_slug(genus.slug()), Some(*genus));
        }
    }

    #[test]
    fn slug_unique_per_genus() {
        let mut seen = std::collections::HashSet::new();
        for genus in TillandsiaGenus::ALL {
            let slug = genus.slug();
            assert!(
                seen.insert(slug),
                "Duplicate slug '{slug}' for genus {:?}",
                genus
            );
        }
    }

    #[test]
    fn allocator_round_robin() {
        let mut alloc = GenusAllocator::new();
        let g1 = alloc.allocate("project-a").unwrap();
        let g2 = alloc.allocate("project-b").unwrap();
        assert_ne!(g1, g2);
    }

    #[test]
    fn allocator_no_duplicate_for_same_project() {
        let mut alloc = GenusAllocator::new();
        let g1 = alloc.allocate("project-a").unwrap();
        let g2 = alloc.allocate("project-a").unwrap();
        assert_ne!(g1, g2);
    }

    #[test]
    fn allocator_pool_exhaustion() {
        let mut alloc = GenusAllocator::new();
        for _ in 0..24 {
            assert!(alloc.allocate("project-a").is_some());
        }
        // 25th allocation should fail — pool exhausted
        assert!(alloc.allocate("project-a").is_none());
    }

    #[test]
    fn allocator_release_and_reuse() {
        let mut alloc = GenusAllocator::new();
        let g1 = alloc.allocate("project-a").unwrap();
        alloc.release("project-a", g1);
        let g2 = alloc.allocate("project-a").unwrap();
        // After release, should be able to get a genus again
        assert!(TillandsiaGenus::ALL.contains(&g2));
    }

    #[test]
    fn icon_loader_all_combinations() {
        // Verify all icon combinations load and contain valid SVG data
        for genus in TillandsiaGenus::ALL {
            for lifecycle in &[
                PlantLifecycle::Bud,
                PlantLifecycle::Bloom,
                PlantLifecycle::Dried,
                PlantLifecycle::Pup,
            ] {
                let svg = icons::icon_svg(*genus, *lifecycle);
                assert!(
                    !svg.is_empty(),
                    "Icon for {:?}/{:?} is empty",
                    genus,
                    lifecycle
                );
                let svg_str = std::str::from_utf8(svg).expect("SVG should be valid UTF-8");
                assert!(
                    svg_str.contains("<svg"),
                    "Icon for {:?}/{:?} missing <svg tag",
                    genus,
                    lifecycle
                );
            }
        }
    }

    #[test]
    fn new_genera_fall_back_to_ionantha_svg() {
        // New genera without dedicated SVGs should return Ionantha icons
        let ionantha_bud = icons::icon_svg(TillandsiaGenus::Ionantha, PlantLifecycle::Bud);
        let cyanea_bud = icons::icon_svg(TillandsiaGenus::Cyanea, PlantLifecycle::Bud);
        assert!(
            std::ptr::eq(ionantha_bud, cyanea_bud),
            "Cyanea bud should be same bytes as Ionantha bud"
        );
    }

    #[test]
    fn original_genera_have_dedicated_icons() {
        // Original 8 genera should NOT fall back to Ionantha (except Ionantha itself)
        let aeranthos_bud = icons::icon_svg(TillandsiaGenus::Aeranthos, PlantLifecycle::Bud);
        let ionantha_bud = icons::icon_svg(TillandsiaGenus::Ionantha, PlantLifecycle::Bud);
        assert!(
            !std::ptr::eq(aeranthos_bud, ionantha_bud),
            "Aeranthos should have its own icon"
        );
    }

    #[test]
    fn has_dedicated_icons_correct() {
        assert!(TillandsiaGenus::Aeranthos.has_dedicated_icons());
        assert!(TillandsiaGenus::Ionantha.has_dedicated_icons());
        assert!(!TillandsiaGenus::Cyanea.has_dedicated_icons());
        assert!(!TillandsiaGenus::Pruinosa.has_dedicated_icons());
    }

    #[test]
    fn lifecycle_mapping() {
        use crate::event::ContainerState;
        assert_eq!(
            PlantLifecycle::from_container_state(&ContainerState::Creating),
            PlantLifecycle::Bud
        );
        assert_eq!(
            PlantLifecycle::from_container_state(&ContainerState::Running),
            PlantLifecycle::Bloom
        );
        assert_eq!(
            PlantLifecycle::from_container_state(&ContainerState::Stopping),
            PlantLifecycle::Dried
        );
        assert_eq!(
            PlantLifecycle::from_container_state(&ContainerState::Rebuilding),
            PlantLifecycle::Pup
        );
    }
}
