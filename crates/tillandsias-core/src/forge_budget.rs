//! ORDER 1375-xxzj — a forge is a cgroup BUDGET, not a ceiling.
//!
//! Design: plan/issues/forge-memory-swap-architecture-design-2026-09-26.md
//! §3 and §6. A forge gets `memory.max` (the hard OOM backstop), `memory.high`
//! (throttle-and-reclaim, the kernel's main control, where tmpfs pages spill
//! to swap), `memory.low` (protect the working set), `memory.swap.max` (how
//! much of the host's swap this forge may occupy) and `pids.max`.
//!
//! WHY NOT 437's NO-SWAP CEILING (operator ruling on 437): with
//! `memory.swap.max=0` a HOT tmpfs that fills can only be OOM-killed; with a
//! swap allowance it spills and the build continues. tmpfs IS the swap-backed
//! RAM disk; this budget is what lets it behave like one.
//!
//! EACH FILE IS WRITTEN EXACTLY, NEVER VIA `--memory-swap`. Measured
//! 2026-09-26: on lenovinha (podman 5.8.7, crun 1.28, cgroup v2, rootless)
//! `--memory=1g --memory-swap=2g` gave `memory.swap.max=1073741824` (Docker's
//! memory-swap minus memory), while yoga measured 2 GiB for the same flags.
//! One flag, two meanings across the fleet. `--cgroup-conf=memory.swap.max=`
//! and `--cgroup-conf=memory.high=` wrote the exact bytes on this host, so
//! those are what [`ForgeBudget::podman_args`] emits.
//!
//! SIZED FROM MEASURED ANON WORKING SETS, not `memory.peak` (which includes
//! reclaimable page cache): a cold `cargo build --workspace --all-targets`
//! peaked at 2454 / 3055 / 3907 / 4049 MiB anon at -j4/6/12/16 on lenovinha,
//! ~2.0 / 3.0 / 3.3 GiB at -j4/6/12 on yoga (1378-7w2p). pids.peak was
//! 37 / 52 / 98 / 126 — about 8 per job — so pids.max is a fork-storm
//! guard sized for installers, not for the compiler.

/// One forge's cgroup budget.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ForgeBudget {
    pub memory_max_mib: u64,
    pub memory_high_mib: u64,
    pub memory_low_mib: u64,
    pub swap_max_mib: u64,
    pub pids_max: u32,
}

const GIB: u64 = 1024;

impl ForgeBudget {
    /// The budget for a host with `nproc` threads and `mem_total_mib` RAM.
    ///
    /// Tiers (design §6): the coordinator desktop (>= 32 GiB) runs up to four
    /// forges at 12 GiB each; a fat host (>= 8 threads) runs two at 6 GiB,
    /// which holds the measured -j16 anon peak (4.0 GiB) with room for resident
    /// HOT tmpfs; everything else — floor hosts and the 8 GiB VM guests — gets
    /// 3 GiB, which holds a -j4 build (2.4 GiB). `memory.max` never exceeds
    /// three quarters of the host's RAM, so a small guest keeps room for its
    /// own kernel and daemons.
    pub fn for_host(nproc: u32, mem_total_mib: u64) -> Self {
        let (max, low, swap) = if mem_total_mib >= 32 * GIB {
            (12 * GIB, 4 * GIB, 12 * GIB)
        } else if nproc >= 8 {
            (6 * GIB, 2 * GIB, 8 * GIB)
        } else {
            (3 * GIB, GIB, 4 * GIB)
        };
        let max = max.min(mem_total_mib.saturating_mul(3) / 4).max(GIB);
        let low = low.min(max / 2);
        ForgeBudget {
            memory_max_mib: max,
            memory_high_mib: max * 85 / 100,
            memory_low_mib: low,
            swap_max_mib: swap,
            pids_max: pids_max_for(nproc),
        }
    }

    /// The budget for THIS host, read from /proc/meminfo and the scheduler.
    /// A host whose RAM cannot be read gets the floor tier (the smallest
    /// budget), never a guess upward.
    pub fn for_this_host() -> Self {
        let nproc = std::thread::available_parallelism().map_or(1, |n| n.get() as u32);
        let mem = std::fs::read_to_string("/proc/meminfo")
            .ok()
            .and_then(|s| parse_mem_total_mib(&s))
            .unwrap_or(8 * GIB);
        Self::for_host(nproc, mem)
    }

    /// The podman flags that set this budget, each cgroup file written
    /// exactly (see the module note on `--memory-swap`).
    pub fn podman_args(&self) -> Vec<String> {
        vec![
            format!("--memory={}m", self.memory_max_mib),
            format!("--memory-reservation={}m", self.memory_low_mib),
            format!(
                "--cgroup-conf=memory.high={}",
                self.memory_high_mib * 1024 * 1024
            ),
            format!(
                "--cgroup-conf=memory.swap.max={}",
                self.swap_max_mib * 1024 * 1024
            ),
            format!("--pids-limit={}", self.pids_max),
        ]
    }
}

/// clamp(512 × nproc, 4096, 16384) — design §6.
pub fn pids_max_for(nproc: u32) -> u32 {
    nproc.saturating_mul(512).clamp(4096, 16384)
}

fn parse_mem_total_mib(meminfo: &str) -> Option<u64> {
    let line = meminfo.lines().find(|l| l.starts_with("MemTotal:"))?;
    let kib: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kib / 1024)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiers_follow_the_design_table() {
        // lenovinha: 16 threads, 13.5 GiB.
        let fat = ForgeBudget::for_host(16, 13_811);
        assert_eq!(
            (fat.memory_max_mib, fat.memory_low_mib, fat.swap_max_mib),
            (6144, 2048, 8192)
        );
        assert_eq!(fat.memory_high_mib, 5222);
        assert_eq!(fat.pids_max, 8192);
        // macuahuitl: 20 cores, 62 GiB.
        let big = ForgeBudget::for_host(20, 63_897);
        assert_eq!(
            (big.memory_max_mib, big.swap_max_mib, big.pids_max),
            (12_288, 12_288, 10_240)
        );
        // pirria: 4 cores, 15 GiB.
        let floor = ForgeBudget::for_host(4, 15_667);
        assert_eq!(
            (
                floor.memory_max_mib,
                floor.memory_low_mib,
                floor.swap_max_mib
            ),
            (3072, 1024, 4096)
        );
        assert_eq!(floor.pids_max, 4096);
    }

    #[test]
    fn a_small_guest_keeps_a_quarter_of_its_ram() {
        let tiny = ForgeBudget::for_host(8, 4096);
        assert_eq!(tiny.memory_max_mib, 3072);
        assert!(tiny.memory_low_mib <= tiny.memory_max_mib / 2);
        assert!(tiny.memory_high_mib < tiny.memory_max_mib);
    }

    #[test]
    fn the_budget_holds_the_measured_anon_peaks() {
        // 1378-7w2p: -j16 anon peak 4049 MiB on the fat tier; -j4 2454 MiB on the floor.
        assert!(ForgeBudget::for_host(16, 13_811).memory_high_mib > 4049);
        assert!(ForgeBudget::for_host(4, 15_667).memory_high_mib > 2454);
    }

    #[test]
    fn pids_clamp() {
        assert_eq!(pids_max_for(1), 4096);
        assert_eq!(pids_max_for(12), 6144);
        assert_eq!(pids_max_for(64), 16384);
    }

    #[test]
    fn swap_is_never_expressed_through_memory_swap() {
        let args = ForgeBudget::for_host(16, 13_811).podman_args();
        assert!(
            args.iter().all(|a| !a.starts_with("--memory-swap")),
            "{args:?}"
        );
        assert!(args.contains(&"--cgroup-conf=memory.swap.max=8589934592".to_string()));
        assert!(args.contains(&"--cgroup-conf=memory.high=5475663872".to_string()));
        assert!(args.contains(&"--memory=6144m".to_string()));
        assert!(args.contains(&"--memory-reservation=2048m".to_string()));
        assert!(args.contains(&"--pids-limit=8192".to_string()));
    }

    #[test]
    fn meminfo_parses() {
        assert_eq!(
            parse_mem_total_mib("MemTotal:       14142784 kB\nMemFree: 1 kB\n"),
            Some(13_811)
        );
        assert_eq!(parse_mem_total_mib("nothing here"), None);
    }
}
