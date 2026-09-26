// @trace spec:accel-capability-probe
//! Structured hardware capability probe (CPU, GPU, NPU, memory bandwidth)
//! replacing single-string inference tier detection.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Schema version for capabilities.json per spec:accel-capability-probe
///
/// 2 (order 808-43mw) adds host identity to `HostInfo` and workload/locus
/// labels to `MeasurementRecord`. Bumped rather than added silently because
/// `load_or_probe` uses this to decide a cached document is still describable
/// — a v1 cache has no `host_id`, and re-probing is cheaper than reasoning
/// about a document that cannot name itself.
///
/// 3 (order 793-qr4t/793-qc6q) adds `HostInfo::side` — which SIDE of which
/// boundary the probe ran on — and the model dimension on
/// `MeasurementRecord`. Same reasoning as 2, and sharper: a v2 document has
/// no side, so every device it reports is unqualified, and the envelope
/// cannot distinguish "no NPU here" from "the NPU is on the other side of a
/// VM boundary". Serving that from cache would republish the exact confusion
/// 793-qr4t exists to end.
pub const SCHEMA_VERSION: u32 = 3;

/// Derived document describing host execution devices, engine availability, and measurements.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct CapabilityDocument {
    pub schema_version: u32,
    pub legacy_tier: String,
    pub devices: Vec<DeviceRecord>,
    pub engines: Vec<EngineRecord>,
    pub measurements: Vec<MeasurementRecord>,
    pub host: HostInfo,
    pub timestamp: String,
    /// Order 852-dk9z. WHICH PROBE CODE produced this document. Absent on every
    /// document written before that order, which is why it is Option + default:
    /// a legacy cache reads as None, compares unequal to any real identity, and
    /// is therefore re-probed rather than served. It is serialised into
    /// published rows on purpose — the old complaint was that nothing on a row
    /// said which code probed it.
    #[serde(default)]
    pub probe_identity: Option<String>,
    /// Device classes this probe COULD NOT ENUMERATE on this platform, as
    /// opposed to enumerated-and-found-none.
    ///
    /// ORDER 805-r98w / NPU parity, 2026-09-02. Before this existed, both
    /// outcomes produced an empty device list and the envelope rendered either
    /// as `none` — so a probe that had never looked published an affirmative
    /// denial. Measured on native Windows: `accel_npu=none` on a host whose
    /// XDNA2 NPU was serving models at that moment.
    ///
    /// `#[serde(default)]` because documents written before this order have no
    /// such field; an old cache reads as "no gaps", which is the pre-existing
    /// behaviour and no worse than it was.
    #[serde(default)]
    pub enumeration_gaps: Vec<String>,
    /// The derived HARDWARE identity of the machine this document describes, or
    /// `None` when the probe could not identify it.
    ///
    /// ORDER 805-r98w, second half. The fleet matrix is keyed `(host_id,
    /// locus)`: `locus` is the substrate half and already works, but `host_id`
    /// is an ASSERTED machine name, so rows cannot be grouped by hardware and
    /// "these two hosts are the same machine" stays unverifiable — which is the
    /// whole reason this order exists.
    ///
    /// Recorded here rather than recomputed by the matrix reader ON PURPOSE.
    /// A second implementation of an identity function is the bug this order
    /// spent a day removing: yoga and this host briefly had two, they disagreed
    /// on RAM source and rounding, and two hosts running different
    /// implementations would have compared incommensurable strings. So the
    /// probe computes it once, the document carries it, and every consumer
    /// reads the same field.
    ///
    /// `None` IS MEANINGFUL AND MUST NOT BE PAPERED OVER: it means
    /// [`hardware_fingerprint_checked`] refused, i.e. this document cannot
    /// identify its machine. A row with `None` must never be grouped with
    /// another `None` row — two documents that both failed to identify
    /// themselves are not thereby the same hardware.
    #[serde(default)]
    pub hardware_fingerprint: Option<String>,
    /// The container lane's DRM render nodes, each carrying how far the
    /// evidence for it actually goes.
    ///
    /// ORDER 793-zumy REMAINING 2. The `Enumerated < Reachable < Placed` rungs
    /// were modelled, pinned by nine tests, and INERT: nothing produced a rung
    /// above `Enumerated` and nothing carried one off the probe. An honest model
    /// that does no work is only half the fix, and this field is the half that
    /// makes it observable.
    ///
    /// EMPTY IS NOT `none`. A host with no podman, no inference container, or no
    /// render nodes all yield an empty vec, and so does a probe that could not
    /// ask. Read it as "no container-lane placement is PROVEN here", never as
    /// "this machine has no GPU" - `devices` answers that question and
    /// `enumeration_gaps` records where nobody looked.
    ///
    /// APPENDED LAST ON PURPOSE. `scripts/dev-inference-ensure.sh` reads
    /// `legacy_tier` out of this document with `grep -m1` on the RAW
    /// `tillandsias --capabilities` output, so the FIRST `legacy_tier`-looking
    /// line wins; a new block ahead of it would silently downgrade yoga's ROCm
    /// host to cpu with no device flags and no warning. Nothing in here spells
    /// `legacy_tier`, and it serialises after it either way.
    ///
    /// `#[serde(default)]` because every document written before this order has
    /// no such field; an old cache reads as "nothing proven", which is the
    /// pre-existing behaviour and no worse than it was.
    #[serde(default)]
    pub render_nodes: Vec<DrmRenderNode>,
    /// Whether THIS envelope was measured now or served from the on-disk cache.
    ///
    /// ORDER 1139-xe5m. `--capabilities` served `~/.cache/tillandsias/capabilities.json`
    /// whenever one existed, and nothing in the envelope said so: `timestamp`,
    /// `probe_identity` and `hardware_fingerprint` all describe the PRODUCING
    /// run, so a replay is byte-identical to the measurement it replays.
    /// Measured on esmeraldinha 2026-09-13 — the cache present replayed
    /// `2026-09-12T03:29:40.356539631+00:00` digit for digit across runs
    /// (`chrono::Utc::now()` does not reproduce a nanosecond field), and moving
    /// the cache aside yielded a timestamp agreeing with the wall clock.
    ///
    /// THE FIELD, NOT A STALENESS BOUND OR A BYPASS FLAG. All three were on the
    /// row; only the field makes an ALREADY-COLLECTED envelope interpretable,
    /// and the fleet capability matrix folds rows produced on other machines
    /// hours earlier. A bound or a flag changes what FUTURE runs emit and leaves
    /// every stored row exactly as ambiguous as it was. The other two remain
    /// available and are not foreclosed by this.
    ///
    /// NEVER PERSISTED AS A VALUE — [`write_capability_cache`] clears it before
    /// writing, so the on-disk document says `null` and a serve stamps `served`
    /// onto the copy it returns. Persisting `measured` would replay the claim
    /// along with the document, which is this defect exactly.
    ///
    /// `None` MEANS UNKNOWN AND IS NOT "measured": documents written before this
    /// order carry no such field, and a reader must not promote their silence
    /// into a measurement — that is the inference this order exists to stop.
    #[serde(default)]
    pub envelope_source: Option<EnvelopeSource>,
}

/// How a [`CapabilityDocument`] in hand came to be (order 1139-xe5m).
///
/// Readable from the envelope ALONE: no filesystem access, no second run, and
/// no knowledge of the producing host — which is the closure the row states,
/// because a matrix row arrives as bytes from a machine you cannot ask.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
// @trace order:1139-xe5m, spec:accel-capability-probe
pub enum EnvelopeSource {
    /// The probe ran and produced this document in this process.
    Measured,
    /// A cache entry was served unchanged; `timestamp` is the ORIGINAL
    /// measurement's, not this run's.
    Served,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct CpuCores {
    pub physical: u32,
    pub logical: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct DeviceRecord {
    pub device_class: String, // "cpu" | "gpu" | "npu"
    pub vendor: String, // "intel" | "amd" | "nvidia" | "apple" | "AMD XDNA" | "Intel NPU" | "unknown"
    pub name: String,
    pub device_node: Option<String>,
    pub fw_version: Option<String>,
    pub driver: Option<String>,
    pub usable: bool,
    pub unusable_reason: Option<String>,

    /// ORDER 1011-zp59 — WHY A DEVICE IS NOT SCHEDULED, when the answer is
    /// POLICY rather than capability.
    ///
    /// `usable` answers "can our lanes drive it", and for AMD that means a ROCm
    /// runtime reporting a gfx agent. lenovinha's Cezanne Vega has no ROCm, so
    /// `usable` is false and `unusable_reason` is `rocm-runtime-missing` —
    /// literally true, and carrying a FALSE implication. Measured 2026-09-04:
    /// the device enumerates through Vulkan as RADV RENOIR, 8.7 GiB, and places
    /// qwen2.5:0.5b and nomic-embed-text with size_vram == size. It is not
    /// broken. It is deliberately not scheduled, because the discrete RTX 3070
    /// beside it wins decode by 4.3-4.9x and embeddings by 3.1x.
    ///
    /// `present-unusable` says "cannot be used". `usable` would say "go ahead
    /// and place work here" — and a scheduler that believed it would lose 3-4x.
    /// Both are wrong, so this is a THIRD fact rather than a different value of
    /// either: the capability reading stays exactly what was measured, and the
    /// policy reading travels beside it.
    ///
    /// DELIBERATELY NOT SET BY FLIPPING `usable`. The probe cannot verify a
    /// Vulkan lane — it reads sysfs and a ROCm runtime — so claiming usability
    /// from a policy check would assert on every host a capability that was
    /// measured on one. An AMD iGPU beside a discrete card on a host with no
    /// Vulkan userspace at all would inherit a claim nobody made.
    #[serde(default)]
    pub policy_unscheduled: Option<String>,

    pub lanes: Vec<String>, // ["container", "host-native"], ["host-native"], or []
    pub memory_bandwidth_gbps: Option<f64>,
    pub memory_bandwidth_source: String, // "soc-table" | "measured" | "unknown"
    pub cpu_flags: Option<Vec<String>>,
    pub cpu_cores: Option<CpuCores>,
    pub system_ram_gb: Option<f64>,

    /// Where `name` CAME FROM: `measured` | `placeholder` (order 1137-rgfm).
    ///
    /// THE DENY-LIST COULD NOT BE MADE CORRECT, which is why this is a field
    /// and not another string comparison. `hardware_fingerprint` refused a
    /// placeholder by listing the ones someone had already found —
    /// `d.name != "Host CPU" && d.name != "unknown"` — a list written from the
    /// WINDOWS defect (805-r98w). `Apple Silicon CPU` is a different
    /// placeholder, so it passed a check whose entire purpose is to catch
    /// placeholders. A deny-list of the ones you know inherits every one you
    /// do not, and the next platform arm adds a third.
    ///
    /// The probe knows which it emitted; nothing downstream can recover it from
    /// the string. So the probe says so. This is the same shape as
    /// `memory_bandwidth_source` two fields up ("soc-table" | "measured" |
    /// "unknown") and the same shape as `is_battery_present: Option<bool>`
    /// (803-r8u4): make the absent case EXPRESSIBLE rather than inferring it
    /// from a value that cannot carry it.
    ///
    /// WHY A PLACEHOLDER NAME IS NOT MERELY UNTIDY. `hardware_fingerprint`
    /// hashes `cpu:{vendor}/{name}/{cores}` and `gpu:{vendor}/{name}`. On
    /// Apple silicon those were byte-identical across the whole fleet, so the
    /// fingerprint collapsed to core count plus RAM class and could not
    /// separate an M1 from an M5. `capability-matrix --by-hardware` re-keys the
    /// fleet on that fingerprint and reports control=yes|no per hardware GROUP,
    /// so a measurement taken on one Mac would be read as covering another —
    /// 808-43mw's "two WSL2 guests share one kernel_release" failure, on a
    /// different field.
    ///
    /// `serde(default)` yields `None` for every document filed before this
    /// existed, and `None` means "this probe did not say" — never "measured".
    /// The fingerprint refuses on `None` only when the name ALSO looks like a
    /// known placeholder, so old documents keep their current behaviour
    /// instead of all becoming unidentifiable at once.
    #[serde(default)]
    pub name_source: Option<String>,

    /// Whether this device's memory is ITS OWN or the host's: `unified` |
    /// `discrete` | `None` (order 964-r98h).
    ///
    /// 793-qr4t could only answer `unknown` for every AMD and Intel GPU in the
    /// fleet, because this struct recorded a memory BANDWIDTH and nothing that
    /// separates an integrated part sharing DRAM from a discrete board with
    /// its own VRAM. That left its unified-memory criterion — one budget, never
    /// summed — demonstrable on Apple silicon and nowhere else.
    ///
    /// `None` IS A REAL ANSWER and must not be papered over: the classifier
    /// looked and could not decide, or could not look at all. It is NOT
    /// "probably unified", and a consumer must decline to sum on `None`
    /// exactly as it does on `unified`.
    ///
    /// Recorded on the DEVICE rather than derived by the envelope on purpose.
    /// This host carries a discrete RTX 3070 and an integrated Vega at once, so
    /// memory model is a property of a device and a host-level field would have
    /// to pick one and be wrong about the other.
    #[serde(default)]
    pub memory_model: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct EngineRecord {
    pub name: String,
    pub backend: String,
    pub supported_device_classes: Vec<String>,
    /// Which lanes this engine is reachable on (order 850-bif2). `None` means
    /// every lane — the pre-existing semantics for a host-PATH binary, and the
    /// deserialization default for every row filed before this field existed.
    /// A containerized engine says `Some(["container"])`: the fleet's ollama
    /// lives inside the tillandsias-inference image, which the old host-PATH
    /// probe could not see — that blindness is how a host with a usable RTX
    /// A5000 filed `engines: []` and the matrix read `schedulable: none`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lanes: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct MeasurementRecord {
    pub device: String,
    pub engine: String,
    pub prefill_tps: Option<f64>,
    pub decode_tps: Option<f64>,
    pub joules_per_token: Option<f64>,
    pub degraded: bool,
    pub degraded_reason: Option<String>,

    /// Which workload produced these numbers (order 808-43mw).
    ///
    /// `scripts/bench-accel-lane.sh` ALREADY KNOWS this — it stamps
    /// `workload_suite: "802-2536-v1"` onto its own stdout JSON — and then
    /// drops it when it pipes a record to `--record-measurement`, because
    /// this struct had nowhere to put it. The label existed upstream and
    /// downstream and was discarded in the middle, so every number in a
    /// capability document was unattributable to the workload that produced
    /// it. Comparing two such numbers is not a comparison.
    ///
    /// `Option` + `serde(default)`, NOT required: `--record-measurement`
    /// must keep accepting the payload the bench sends TODAY, or a host
    /// running this binary against the current script silently stops
    /// recording. Widening the reader is the compatible half of the change;
    /// teaching the writer to send it is the other half, and belongs with
    /// the script, not here.
    #[serde(default)]
    pub workload_suite: Option<String>,

    /// WHERE the measurement ran, e.g. `in-guest`, `host-side-via-mirror`
    /// (order 808-43mw; motivated by the measurement in 810-jeg7).
    ///
    /// This host measured the same suite at two loci and the hop cost 5-10%
    /// on the embed arm — the same order as the cross-host differences the
    /// fleet matrix exists to detect. It did not merely add noise: it
    /// INVERTED a reported conclusion, because two errors happened to
    /// cancel. A row without a locus is not under-annotated, it is
    /// potentially wrong in a way no consumer can see.
    #[serde(default)]
    pub locus: Option<String>,

    /// WHICH MODEL produced these numbers, e.g. `qwen2.5:0.5b` (order
    /// 793-qc6q).
    #[serde(default)]
    pub model: Option<String>,

    /// The model's parameter count in BILLIONS, e.g. `0.5` or `3.0`.
    ///
    /// THIS IS THE AXIS THE DECODE CROSSOVER LIVES ON, and without it
    /// 793-qc6q's exit criterion is not merely unmet but inexpressible. That
    /// criterion forbids a hard-coded threshold: the crossover must be
    /// "derived from a bounded per-host measurement cached in
    /// capabilities.json ... not from a constant that happens to fit
    /// windows/Yolanda". A crossover is the point where the CPU and GPU decode
    /// curves cross AS MODEL SIZE VARIES — so deriving one requires ordering
    /// decode rows by size, and this struct had no size. Two `decode_tps`
    /// values with no model dimension cannot be ordered, and the only way to
    /// ship a threshold without this field is to type 1.5 into the source,
    /// which is the thing the criterion rules out.
    ///
    /// Parameters, not bytes: quantisation changes the byte count by 4x
    /// without moving the arithmetic-per-token that decides whether the
    /// per-dispatch cost is absorbed, and it is that ratio the crossover is
    /// about.
    ///
    /// `Option` + `serde(default)` for the same reason `workload_suite` is:
    /// `--record-measurement` must keep accepting the payload
    /// `scripts/bench-accel-lane.sh` sends TODAY. A record without it is
    /// usable for everything except crossover derivation, and
    /// [`decode_crossover_b`] simply does not count it.
    #[serde(default)]
    pub model_params_b: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct HostInfo {
    /// Does this host have a battery — `Some(true)`/`Some(false)` when something
    /// LOOKED, `None` when nothing could (order 803-r8u4).
    ///
    /// THIS WAS A `bool`, AND A BARE `bool` HERE CANNOT BE HONEST. Only the
    /// Linux `/sys/class/power_supply` scan ever wrote it; every other host
    /// kept the `false` initializer and serialised it as a confident denial.
    /// The absent probe and the real answer "no battery" were the same byte.
    ///
    /// MEASURED, and this is the field evidence the fleet already holds: the
    /// first macOS capability row (macneo, relayed by macuahuitl onto 657-zm2n
    /// 2026-09-04) reads `is_battery_present false` — from a MacBook, which has
    /// a battery. Nothing on that host had looked. The row was not
    /// under-annotated, it was WRONG, and no consumer could see it.
    ///
    /// This matters beyond tidiness because the inference policy router
    /// suspends background work on battery (spec inference-policy-router,
    /// ADAPT-2). A laptop that reports `false` because nobody probed it is a
    /// laptop the router will never throttle.
    ///
    /// `serde(default)` so a document filed before this field was optional —
    /// including the fixtures under `scripts/fixtures/hardware-fingerprint/` —
    /// still deserialises.
    #[serde(default)]
    pub is_battery_present: Option<bool>,
    pub kernel_release: String,

    /// WHICH MACHINE this document describes (order 808-43mw).
    ///
    /// Without it a CapabilityDocument cannot say whose capabilities it
    /// reports, which blocks the fleet matrix outright: 808-7yrd folds
    /// `host_id -> LWW-Register(document)`, so this is the FOLD KEY. There is
    /// no matrix without it.
    ///
    /// `kernel_release` is not a substitute and the reason is measurable: two
    /// WSL2 guests share `6.18.33.2-microsoft-standard-WSL2` exactly. Keying
    /// on it would silently merge two machines' rows into one, and LWW would
    /// then arbitrate between hosts that are not in conflict — turning a
    /// design whose whole point is "single writer per key by construction"
    /// into one that quietly drops half the fleet.
    ///
    /// NOT A NEW NAMING SCHEME. This is the identifier the fleet already
    /// uses: `scripts/agent-identity.sh`'s `tillandsias_node_name` (short
    /// hostname, lowercased), the same string that names
    /// `plan/mo-full-attestations.d/<host>.md`. Minting a second name for a
    /// machine that already has one would mean the matrix and the ledger
    /// disagree about who a host is.
    pub host_id: String,

    /// How `host_id` was determined: `input` or `node-name`.
    ///
    /// The packet's complaint is SILENT collision, so a consumer must be able
    /// to distinguish a host that was NAMED from one whose name was inferred
    /// and might collide. Recording only the value would reproduce the
    /// original defect one level up.
    ///
    /// Measured on this host: WSL2 inherits the Windows machine name, so the
    /// guest's `uname -n` is `Yolanda` — the derived chain agrees with the
    /// Windows side for free. That is a DEFAULT, not a guarantee:
    /// `/etc/wsl.conf`'s `network.hostname` can override it, at which point
    /// a guest-produced row would file itself under a second key for the same
    /// machine. `input` is how an operator forecloses that.
    pub host_id_source: String,

    /// OS family of the EXECUTION CONTEXT that produced this document:
    /// `linux` | `windows` | `macos`. A consumer folding the matrix reads
    /// documents produced elsewhere, so it cannot use its own `cfg!` to tell
    /// what it is looking at.
    ///
    /// READ THE NAME CAREFULLY — this is the context, not the machine, and on
    /// Windows those differ. Measured on yolanda 2026-08-18: the probe runs
    /// inside the WSL2 guest and reports `host_kind: "linux"` on a machine
    /// whose hardware spec is a Windows laptop's. That is not a defect in this
    /// field; it is 809-7e4m's two-execution-context finding arriving in the
    /// schema, and the field's value is that it now makes the split VISIBLE
    /// instead of leaving a Windows row indistinguishable from a Linux one.
    ///
    /// Deliberately NOT resolved here by inventing a `windows-wsl2` term. The
    /// guest could detect WSL2 from `kernel_release` and relabel itself, but a
    /// guess made by the context that cannot see the NPU or the machine's real
    /// RAM (the guest reports its 7.3 GB VM slice against 15.2 GB installed)
    /// would be a confident half-answer. The correct fix is the host-side
    /// contribution 809-7e4m specifies, which knows rather than infers.
    pub host_kind: String,

    /// WHICH SIDE OF WHICH BOUNDARY this probe ran on (order 793-qr4t).
    ///
    /// `native-linux` | `wsl2-guest` | `windows-host` | `macos-host` |
    /// `container` | `unknown-side`.
    ///
    /// `host_kind` above deliberately refuses to invent a `windows-wsl2` term,
    /// and that refusal is correct FOR THAT FIELD: it names the execution
    /// context's OS family, and a guest guessing at the machine's OS would be
    /// a confident half-answer. This is the field that was missing when that
    /// note was written. It does not guess at the MACHINE; it records a fact
    /// about the PROBE — where it stood — which the probe is the only party
    /// entitled to state and can state from evidence (`/dev/dxg` plus a
    /// `microsoft` kernel release is WSL2; `/run/.containerenv` is a
    /// container). The two fields answer different questions and a consumer
    /// needs both.
    ///
    /// WHY IT MUST LIVE IN THE DOCUMENT rather than be recomputed by whoever
    /// renders it: the fleet matrix folds documents produced ELSEWHERE, so a
    /// reader's own `cfg!` describes the reader, not the row. This is the same
    /// reasoning `enumeration_gaps` records above, and the same failure it
    /// prevents — a transported document keeps its own facts.
    ///
    /// `Option` + `serde(default)` because every document written before this
    /// order has no side. `None` reads as "this document does not say", which
    /// is true of them and is NOT the same as `unknown-side` (a probe that
    /// looked and could not tell).
    #[serde(default)]
    pub side: Option<String>,
}

/// The env INPUT that names this machine, overriding the derived chain.
///
/// Deliberately the same shape as `TILLANDSIAS_INFERENCE_TIER`: identity, like
/// the tier, is an input corroborated against the machine rather than derived
/// from it. On Windows a single capability row spans two execution contexts
/// (809-7e4m), and the context that can see the NPU is not the one that runs
/// this probe — so the two contributions must agree on a name that neither is
/// solely entitled to invent.
pub const HOST_ID_ENV: &str = "TILLANDSIAS_HOST_ID";

// @trace spec:accel-capability-probe
pub fn capabilities_cache_path() -> PathBuf {
    if let Ok(dir) = std::env::var("TILLANDSIAS_CACHE_DIR") {
        return PathBuf::from(dir).join("capabilities.json");
    }
    // NEVER fall back to "." — that resolves against the CURRENT WORKING
    // DIRECTORY, which during `cargo test` and every build dispatch is the
    // tracked checkout. This module had no caller until now, so the fallback was
    // unreachable and harmless; adding the first one made a HOME-less
    // environment write crates/tillandsias-headless/.cache/tillandsias/
    // capabilities.json into the source tree, which order 495 forbids outright
    // (generated evidence in the worktree fails the forge dirty-start guard for
    // whoever runs next, not for whoever caused it).
    //
    // A cache is by definition discardable, so the temp dir is the correct home
    // for one with nowhere else to live.
    // Order 815-gdjk: XDG-first via the shared resolver (this probe was the
    // measured half of the split: with XDG_CACHE_HOME set it wrote here
    // while every shell consumer resolved under the XDG root).
    tillandsias_core::cache_root::cache_root().join("capabilities.json")
}

// @trace spec:accel-capability-probe
pub fn load_or_probe(effective_tier: &str) -> CapabilityDocument {
    load_or_probe_at(
        &capabilities_cache_path(),
        effective_tier,
        Freshness::Cached,
    )
}

/// Order 852-dk9z. Publication must never be able to emit a cached document.
/// `scripts/host-capability-probe.sh` takes this path, so a published capability
/// row is fresh BY CONSTRUCTION rather than by the operator having remembered to
/// clear a cache directory first.
// @trace order:852-dk9z, spec:accel-capability-probe
pub fn probe_fresh(effective_tier: &str) -> CapabilityDocument {
    load_or_probe_at(&capabilities_cache_path(), effective_tier, Freshness::Force)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
// @trace order:852-dk9z, spec:accel-capability-probe
pub enum Freshness {
    /// Serve a cache entry that matches this binary's probe identity.
    Cached,
    /// Probe regardless of what the cache holds (and refresh the cache).
    Force,
}

/// The cache path is a PARAMETER so this is testable without mutating process
/// environment — env-var tests race against every other test in the binary.
// @trace order:852-dk9z, spec:accel-capability-probe
pub fn load_or_probe_at(
    cache_file: &Path,
    effective_tier: &str,
    freshness: Freshness,
) -> CapabilityDocument {
    let identity = probe_identity();
    if freshness == Freshness::Cached
        && let Ok(content) = fs::read_to_string(cache_file)
        && let Ok(mut doc) = serde_json::from_str::<CapabilityDocument>(&content)
        && doc.schema_version == SCHEMA_VERSION
        && doc.legacy_tier == effective_tier
        // The check 852-dk9z adds. Without it a rebuilt binary republishes its
        // predecessor's document as if it had probed.
        && doc.probe_identity.as_deref() == Some(identity.as_str())
    {
        // THE STAMP GOES ON THE COPY BEING RETURNED, not on the cache. The
        // document is otherwise returned verbatim, `timestamp` included, so
        // this field is the only thing distinguishing it from the run that
        // produced it (order 1139-xe5m).
        doc.envelope_source = Some(EnvelopeSource::Served);
        return doc;
    }
    let doc = run_probe(effective_tier);
    let _ = write_capability_cache(cache_file, &doc);
    doc
}

/// Persist a capability document, WITHOUT its [`CapabilityDocument::envelope_source`].
///
/// Order 1139-xe5m. Every write of the cache goes through here, and the reason
/// is the whole point of the field: a document written with `measured` on it
/// would be served back later still claiming it was measured, which reproduces
/// the defect in a form that now looks authoritative. The stored document says
/// `null` — unknown — and the serve path stamps `served` onto the copy it hands
/// out.
// @trace order:1139-xe5m, spec:accel-capability-probe
pub fn write_capability_cache(cache_file: &Path, doc: &CapabilityDocument) -> Result<(), String> {
    let mut stored = doc.clone();
    stored.envelope_source = None;
    if let Some(parent) = cache_file.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
    }
    let json = serde_json::to_string_pretty(&stored).map_err(|e| format!("serialize: {e}"))?;
    fs::write(cache_file, json).map_err(|e| format!("write {}: {e}", cache_file.display()))
}

/// Merge one measurement into the persisted capability document (order 805-wgbb).
///
/// `run_probe` hard-codes `measurements = Vec::new()` under a comment saying
/// microbenchmarks "run on demand" — and no on-demand path existed anywhere in
/// the tree, so `measurements: []` meant NOTHING WRITES rather than nothing has
/// run. 802-2536 asks every host to record cpu/npu/gpu numbers "into the
/// existing MeasurementRecord", which no host could do. This is that path.
///
/// KEYED BY (device, engine), replacing in place. A second run of the same
/// workload on the same lane is a NEW measurement of the same thing, not an
/// additional data point — appending would grow an unbounded log whose newest
/// entry a reader has to find by scanning, and the router reads this document
/// as its input surface, not as history.
///
/// NOTE ON LIFETIME, because it is easy to be surprised by: `load_or_probe`
/// re-probes and overwrites the cache when the schema version or the legacy
/// tier changes. Measurements are dropped then, and that is correct — a tier
/// change means the numbers describe a configuration that no longer exists —
/// but it does mean a measurement is not durable across a tier flip.
pub fn record_measurement(m: MeasurementRecord) -> Result<(), String> {
    let cache_file = capabilities_cache_path();
    let mut doc: CapabilityDocument = match fs::read_to_string(&cache_file) {
        Ok(content) => serde_json::from_str(&content).map_err(|e| {
            format!("capabilities cache is unreadable ({e}); re-run --capabilities")
        })?,
        // No cache yet: probe rather than refuse, so the first thing a fresh
        // host does can be to record a measurement.
        Err(_) => run_probe(crate::effective_inference_tier()),
    };
    // THE KEY INCLUDES THE MODEL SIZE, and omitting it made the crossover
    // underivable on every host in the fleet (order 793-qc6q).
    //
    // `decode_crossover_b` needs SEVERAL sizes per device to find the point
    // where the GPU overtakes the CPU. Keying only on (device, engine) meant
    // the second size benchmarked OVERWROTE the first, so the document could
    // hold at most one row per device no matter how many models were measured —
    // and the derivation, needing two or more, answered `Unmeasured` forever.
    // MEASURED on tlatoanis-macbook-air 2026-09-03: benchmarking 0.5B, 3B and
    // 7B on both lanes, six recordings, left exactly two rows, both 7B.
    //
    // That is why the field has looked unused since order 480. Not because
    // nobody ran the benchmark — because the store could not keep what the
    // benchmark produced.
    //
    // Two sizes on one device are DIFFERENT measurements, not a re-measurement;
    // re-running the SAME size still replaces, which is the freshness behaviour
    // this always had. `None` params keeps the old behaviour exactly, so a
    // recorder that sends no size still gets one slot per (device, engine)
    // rather than accumulating unbounded anonymous rows.
    let same_size = |a: Option<f64>, b: Option<f64>| match (a, b) {
        (Some(x), Some(y)) => (x - y).abs() < 1e-9,
        (None, None) => true,
        _ => false,
    };
    match doc.measurements.iter_mut().find(|e| {
        e.device == m.device
            && e.engine == m.engine
            && same_size(e.model_params_b, m.model_params_b)
    }) {
        Some(slot) => *slot = m,
        None => doc.measurements.push(m),
    }
    // Through the helper so the stored document never carries an
    // `envelope_source` claim (order 1139-xe5m): this path loads a document that
    // may have been stamped `served` on the way in, and writing that back would
    // persist a lie about a document that is, after this merge, neither.
    write_capability_cache(&cache_file, &doc)
}

// @trace spec:accel-capability-probe
/// `effective_tier` NO LONGER REACHES DEVICE ENUMERATION (order 935-jhh5). It
/// used to be threaded down to `enumerate_gpus` and decide `cdi_ok`, which made
/// the GPU record's container lane a restatement of the tier — itself derived
/// from the same `nvidia-smi` that record already runs.
///
/// It is still read HERE, for `legacy_tier`, and that is the right place for it:
/// the document then carries the CLAIMED tier beside INDEPENDENTLY MEASURED
/// devices, so the two can be compared instead of one being manufactured from
/// the other. Enumeration measures the machine; this field records what the
/// tier probe asserted. Do not re-thread it downward.
pub fn run_probe(effective_tier: &str) -> CapabilityDocument {
    let (mut devices, mut enumeration_gaps) = enumerate_devices();
    // 793-zumy REMAINING 2. "No container to ask" is a GAP, not a finding —
    // the same distinction `enumeration_gaps` already carries for a device
    // class this platform cannot enumerate. Measured by yoga 2026-09-02: with
    // the two collapsed, a host whose container lane was working read
    // identically to a host with no accelerator at all.
    let container_lane = probe_container_render_nodes();
    if container_lane.asked.is_none() {
        enumeration_gaps.push("container-lane".to_string());
    }
    let engines = enumerate_engines();
    // 1253-54zj: the NPU verdict is decided here, where the engines are known,
    // not written as a literal at the enumerators' push sites.
    derive_npu_usability(&mut devices, &engines);
    let measurements = Vec::new(); // Microbenchmarks run on demand / bounded
    let host = enumerate_host();
    let timestamp = chrono::Utc::now().to_rfc3339();

    let mut doc = CapabilityDocument {
        schema_version: SCHEMA_VERSION,
        legacy_tier: effective_tier.to_string(),
        devices,
        engines,
        measurements,
        host,
        timestamp,
        probe_identity: Some(probe_identity()),
        enumeration_gaps,
        hardware_fingerprint: None,
        // 793-zumy REMAINING 2: PRODUCED, not modelled. Bounded and
        // fail-quiet - a host with no podman, no container or no devices
        // contributes an empty vec rather than a fabricated row, and the
        // gap above says which of those it was.
        render_nodes: container_lane.nodes,
        // Stamped here because this is the only place a document is MEASURED.
        // Serving re-stamps its copy; writing clears it (order 1139-xe5m).
        envelope_source: Some(EnvelopeSource::Measured),
    };
    // Computed from the devices just enumerated, so the document carries its own
    // hardware identity and no consumer has to re-derive it. `checked` rather
    // than the raw hasher: a blind probe must contribute NO identity rather than
    // a plausible-looking constant that would collide with every other blind
    // host.
    // ORDER 1254-47xd. Derive the container lane from the container-vantage
    // proof this document already carries, BEFORE the fingerprint is computed
    // over it, so the identity covers the record as it will be read.
    promote_proven_container_lanes(&mut doc);
    doc.hardware_fingerprint = hardware_fingerprint_checked(&doc).ok();
    doc
}

/// ORDER 1254-47xd. Give a device the container lane its OWN render node was
/// proven to carry, and leave every other device's verdict alone.
///
/// THE DEFECT WAS A CONTRADICTION INSIDE ONE DOCUMENT. Measured on yoga: a
/// render_nodes entry read `node renderD128, vantage container, proof placed`
/// while the GPU at renderD128 read `lanes ["host-native"], unusable_reason
/// container-lane-unverified`. The probe held the proof and the record did not
/// reflect it, so capability-matrix intersected ["host-native"] with ollama's
/// ["container"], got nothing, and printed present-unscheduled for a GPU that
/// was serving a resident model at that moment. Every step downstream was
/// correct; only this one was missing.
///
/// WHY IT LIVES HERE AND NOT IN `amd_gpu_disposition`. That function is
/// host-vantage — rocm_gfx, kfd and a sysfs render node — and order 793-zumy
/// REFUSED to claim the container lane from those inputs after measuring a host
/// where all three were true and the container had neither the device nodes nor
/// a ROCm backend. That refusal is correct and is untouched. `run_probe` is the
/// first place the container-vantage evidence and the device records are both
/// in scope, so the lane is derived FROM PROOF here rather than guessed there.
///
/// KEYED PER DEVICE ON ITS OWN NODE, never on "a GPU exists and some node was
/// proven". A device's `device_node` is set from `drm_render_node_for(pci_addr)`
/// — the render node of the very PCI address that named it — so matching it to
/// `DrmRenderNode::node` is the same identity relation the record was built
/// from. On a host with two GPUs and one proven node, the unproven one keeps its
/// unverified reason; promoting it would route work to a device nobody reached.
///
/// `Reachable` IS THE BAR, NOT `Placed`, and the reason is a flap rather than a
/// preference: on yoga the same evening the field escalated reachable -> placed
/// between two runs with NO host change, so a rule keyed on the literal `Placed`
/// would grant and withdraw the lane as a model happened to be resident. Both
/// rungs are container-vantage evidence that the namespace reaches the device,
/// which is what the lane asserts. `Enumerated` is not — it says the hardware
/// exists and nothing about any lane — so it is excluded.
///
/// ABSENCE OF PROOF IS NOT PROOF OF REACH. A device with no matching
/// container-vantage node is left exactly as the disposition functions wrote it,
/// reason and all. This function only ever ADDS a lane; it never removes
/// `host-native` (that question is 1254-47xd's named unscoreable) and never
/// promotes on host-vantage evidence.
fn promote_proven_container_lanes(doc: &mut CapabilityDocument) {
    for device in &mut doc.devices {
        // The record names its node as a path; the render node names itself as
        // a basename. Compare the basename so "/dev/dri/renderD128" and
        // "renderD128" are the same node rather than two strings.
        let Some(node_path) = device.device_node.as_deref() else {
            continue;
        };
        let node_name = node_path.rsplit('/').next().unwrap_or(node_path);

        let proven_here = doc.render_nodes.iter().any(|n| {
            n.node == node_name && n.vantage == Vantage::Container && n.proof >= Proof::Reachable
        });
        if !proven_here {
            continue;
        }

        if !device.lanes.iter().any(|l| l == "container") {
            // Ahead of host-native so the lane a container can actually use
            // reads first; order within the vec is not semantic.
            device.lanes.insert(0, "container".to_string());
        }
        // The reason named exactly this gap. Leaving it beside a container lane
        // would be a second contradiction in the same record — and a reader who
        // greps the reason would still find the host "unverified" after it was
        // verified. Any OTHER reason is left alone: it is not ours to answer.
        if device.unusable_reason.as_deref() == Some("container-lane-unverified") {
            device.unusable_reason = None;
        }
    }
}

/// Order 852-dk9z. The identity of the probe CODE, not of the host.
///
/// Crate version alone is insufficient and that is not hypothetical: 856-fwyh
/// changed enumeration output on this very crate without moving its version, so
/// a version-keyed cache would still have served the stale document. The
/// revision half is an FNV-1a hash of src/accel_probe.rs computed in build.rs,
/// so ANY edit here changes it and no one has to remember to bump a constant.
pub fn probe_identity() -> String {
    format!(
        "{}+{}",
        env!("CARGO_PKG_VERSION"),
        env!("TILLANDSIAS_PROBE_REVISION")
    )
}

// @trace spec:accel-capability-probe
fn enumerate_devices() -> (Vec<DeviceRecord>, Vec<String>) {
    let mut devices = Vec::new();
    let mut gaps = Vec::new();

    // 1. CPU Device
    devices.push(enumerate_cpu());

    // 2. GPUs
    match enumerate_gpus_checked() {
        Some(g) => devices.extend(g),
        None => gaps.push("gpu".to_string()),
    }

    // 3. NPUs
    match enumerate_npus_checked() {
        Some(n) => devices.extend(n),
        None => gaps.push("npu".to_string()),
    }

    (devices, gaps)
}

/// GPU enumeration that distinguishes "looked and found none" (`Some(vec![])`)
/// from "could not look here" (`None`).
///
/// ORDER 805-r98w. The distinction is the whole point: an empty list rendered
/// as `accel_gpu=none` on a host with a Radeon 860M, because there was no
/// Windows arm and no way for the caller to tell absence from blindness.
fn enumerate_gpus_checked() -> Option<Vec<DeviceRecord>> {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        Some(enumerate_gpus())
    }
    #[cfg(target_os = "windows")]
    {
        windows_gpus()
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        // An unknown platform has NOT looked. Saying so costs a discriminator;
        // claiming `none` would be a denial we cannot support.
        None
    }
}

/// NPU enumeration, same contract as [`enumerate_gpus_checked`].
fn enumerate_npus_checked() -> Option<Vec<DeviceRecord>> {
    #[cfg(target_os = "linux")]
    {
        Some(enumerate_npus())
    }
    #[cfg(target_os = "windows")]
    {
        windows_npus()
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    {
        None
    }
}

/// The unusable reason an NPU record carries when a HEALTH fact, not an engine
/// question, is what stops it: the OS reports the device as not-OK. The
/// derivation below leaves this reason alone; every other NPU verdict is its
/// to decide.
const NPU_DEVICE_NOT_OK: &str = "device-not-ok";

/// DERIVE each NPU record's verdict from the engine list (order 1253-54zj).
///
/// Before this, both enumerators wrote `usable: false` and
/// `unusable_reason: "engine-missing"` as LITERALS at their push sites, so an
/// NPU row could not change for any host-side reason. yoga measured it: its
/// row was byte-identical before and after a full NPU toolkit layering,
/// because the comparison could not have come out any other way.
///
/// The rule is the one [`gpu_engine`] and [`phase_device_usable`] already
/// apply to the GPU (order 793-qr4t): an NPU is usable when some engine lists
/// `npu` in `supported_device_classes` AND is reachable on one of the
/// device's lanes (`lanes: None` means every lane). Otherwise the hardware is
/// here and nothing drives it: `engine-missing`. The same word as before, now
/// derived, so today's rows keep their verdict and a host that ships an NPU
/// engine sees its row flip.
///
/// `none` is never produced here. That word means NO HARDWARE and comes from
/// the envelope when no NPU record exists at all; this function only sees
/// records that were enumerated, so absence cannot be promoted into
/// present-but-undriveable.
// @trace order:1253-54zj, order:793-qr4t, spec:accel-capability-probe
pub(crate) fn derive_npu_usability(devices: &mut [DeviceRecord], engines: &[EngineRecord]) {
    for d in devices.iter_mut().filter(|d| d.device_class == "npu") {
        if d.unusable_reason.as_deref() == Some(NPU_DEVICE_NOT_OK) {
            d.usable = false;
            continue;
        }
        let driven = engines.iter().any(|e| {
            e.supported_device_classes.iter().any(|c| c == "npu")
                && e.lanes
                    .as_ref()
                    .is_none_or(|ls| ls.iter().any(|l| d.lanes.contains(l)))
        });
        d.usable = driven;
        d.unusable_reason = if driven {
            None
        } else {
            Some("engine-missing".to_string())
        };
    }
}

/// Physical RAM in GiB on macOS, or `None` when the query did not answer.
///
/// ORDER 803-r8u4 / 803-rbqf. `enumerate_cpu`'s macOS arm set cores, vendor and
/// a CPU name and then left `ram_gb` at its `None` initializer, so every macOS
/// capability document filed `system_ram_gb: null` — visible in the fleet's
/// first macOS row (macneo, relayed onto 657-zm2n 2026-09-04). The Linux and
/// Windows arms both answer this; only macOS did not.
///
/// It is a FUNCTION rather than an inline block because two records need the
/// number. On Apple silicon the GPU has no memory of its own — `memory_model`
/// is `unified` — so physical RAM IS the Metal device's memory budget, and the
/// device record that omits it cannot be reasoned about by a consumer that
/// declines to sum unified budgets.
///
/// MEASURED on tlatoanis-macbook-air (Apple M5) 2026-09-12:
/// `sysctl -n hw.memsize` -> `17179869184` -> 16.00 GiB.
///
/// GiB, not GB, matching the Windows arm's divisor: both divide by 1024^3.
/// The CPU's real part name on macOS, or `None` when the query did not answer
/// (order 1137-rgfm).
///
/// `machdep.cpu.brand_string` answers `Apple M5` on this host. The arm used to
/// hard-code the FAMILY string "Apple Silicon CPU", which is byte-identical on
/// every Apple silicon Mac in the fleet — so `hardware_fingerprint`'s
/// `cpu:{vendor}/{name}/{cores}` component carried no information and the
/// fingerprint collapsed to core count plus RAM class.
///
/// A failed query returns `None` and the caller KEEPS the family literal: the
/// old string is useless for identity but is not a lie about capability, and
/// the absent case must stay distinguishable from a measured one. That is what
/// `name_source` records.
#[cfg(target_os = "macos")]
fn macos_cpu_brand() -> Option<String> {
    let out = Command::new("sysctl")
        .args(["-n", "machdep.cpu.brand_string"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if name.is_empty() { None } else { Some(name) }
}

#[cfg(target_os = "macos")]
fn macos_system_ram_gb() -> Option<f64> {
    let out = Command::new("sysctl")
        .args(["-n", "hw.memsize"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse::<u64>()
        .ok()
        .filter(|b| *b > 0)
        .map(|b| b as f64 / (1024.0 * 1024.0 * 1024.0))
}

// @trace spec:accel-capability-probe
fn enumerate_cpu() -> DeviceRecord {
    let mut flags = Vec::new();
    let physical_cores;
    let logical_cores;
    // The Linux probe mutates these defaults incrementally; the macOS and
    // Windows arms overwrite them wholesale, so off-Linux the initializers for
    // name and vendor are never read.
    // macOS and Windows overwrite this wholesale, matching `cpu_name`/`vendor`
    // below; only the Linux arm reads the initializer.
    #[cfg_attr(not(target_os = "linux"), allow(unused_mut, unused_assignments))]
    let mut ram_gb = None;
    #[cfg_attr(not(target_os = "linux"), allow(unused_mut, unused_assignments))]
    let mut cpu_name = "Host CPU".to_string();
    // ORDER 1137-rgfm. `placeholder` until an arm MEASURES the name. Every arm
    // that fails to read one leaves this alone, so the honest default is the
    // pessimistic one and a new platform arm cannot acquire `measured` by
    // forgetting to set it.
    #[cfg_attr(
        not(any(target_os = "linux", target_os = "macos", target_os = "windows")),
        allow(unused_mut, unused_assignments)
    )]
    let mut name_source = "placeholder".to_string();
    #[cfg_attr(not(target_os = "linux"), allow(unused_mut, unused_assignments))]
    let mut vendor = "unknown".to_string();

    #[cfg(target_os = "linux")]
    {
        logical_cores = num_cpus();
        if let Ok(cpuinfo) = fs::read_to_string("/proc/cpuinfo") {
            for line in cpuinfo.lines() {
                if (line.starts_with("model name") || line.starts_with("Processor"))
                    && let Some((_, v)) = line.split_once(':')
                {
                    cpu_name = v.trim().to_string();
                    name_source = "measured".to_string(); // 1137-rgfm
                    if cpu_name.contains("Intel") {
                        vendor = "intel".to_string();
                    } else if cpu_name.contains("AMD") {
                        vendor = "amd".to_string();
                    }
                } else if (line.starts_with("flags") || line.starts_with("Features"))
                    && let Some((_, v)) = line.split_once(':')
                {
                    for flag in v.split_whitespace() {
                        let f = flag.to_lowercase();
                        if (f.contains("avx")
                            || f.contains("neon")
                            || f.contains("sve")
                            || f.contains("fma"))
                            && !flags.contains(&f)
                        {
                            flags.push(f);
                        }
                    }
                }
            }
        }
        if let Ok(meminfo) = fs::read_to_string("/proc/meminfo") {
            for line in meminfo.lines() {
                if line.starts_with("MemTotal:")
                    && let Some(kb_str) = line.split_whitespace().nth(1)
                    && let Ok(kb) = kb_str.parse::<u64>()
                {
                    ram_gb = Some((kb as f64) / 1024.0 / 1024.0);
                }
            }
        }
        physical_cores = physical_core_count().unwrap_or(logical_cores);
    }

    #[cfg(target_os = "macos")]
    {
        logical_cores = num_cpus();
        physical_cores = logical_cores;
        vendor = "apple".to_string();
        // ORDER 1137-rgfm. The family literal survives ONLY as the fallback for
        // a query that did not answer; a measured part name replaces it and
        // says so. Keeping the literal rather than inventing one preserves the
        // distinction the whole field exists for.
        cpu_name = "Apple Silicon CPU".to_string();
        if let Some(brand) = macos_cpu_brand() {
            cpu_name = brand;
            name_source = "measured".to_string();
        }
        flags.push("neon".to_string());
        // ORDER 803-r8u4: this arm used to stop above, leaving `system_ram_gb`
        // null on every macOS row. A failed query leaves it null exactly as
        // before, so the absent case is unchanged and only the measurable one
        // moves.
        ram_gb = macos_system_ram_gb();
    }

    // ORDER 805-r98w / NPU parity, 2026-09-02. Native Windows used to fall
    // through to the generic arm below, which sets physical = logical. On this
    // 8c/16t part that reported 16c16t — a WRONG number, not a missing one, and
    // the CPU model stayed the placeholder "Host CPU". Together those made the
    // hardware fingerprint refuse (correctly) and made the capability document
    // unable to identify the machine at all.
    //
    // Everything here comes from the OS, not from a guess: a query that fails
    // leaves the generic fallback in place rather than inventing a value.
    #[cfg(target_os = "windows")]
    {
        let mut got = None;
        if let Some(lines) = powershell_lines(
            "$c = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1; \
             $m = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory; \
             $c.Name + '|' + $c.NumberOfCores + '|' + $c.NumberOfLogicalProcessors + '|' + \
             $c.Manufacturer + '|' + $m",
        ) {
            if let Some(line) = lines.first() {
                let f: Vec<&str> = line.split('|').collect();
                if f.len() >= 5 {
                    let name = f[0].trim().to_string();
                    // Only accept a COMPLETE row. A partial parse that keeps
                    // some real fields and silently defaults the rest is how a
                    // document ends up half-trustworthy, which is worse than a
                    // uniformly unknown one.
                    if let (Ok(phys), Ok(log)) =
                        (f[1].trim().parse::<u32>(), f[2].trim().parse::<u32>())
                    {
                        if !name.is_empty() && phys > 0 && log > 0 {
                            name_source = "measured".to_string(); // 1137-rgfm
                            got = Some((
                                name,
                                phys,
                                log,
                                f[3].trim().to_string(),
                                f[4].trim().parse::<u64>().ok(),
                            ));
                        }
                    }
                }
            }
        }
        match got {
            Some((name, phys, log, manufacturer, total_bytes)) => {
                cpu_name = name;
                physical_cores = phys;
                logical_cores = log;
                vendor = match manufacturer.as_str() {
                    "AuthenticAMD" => "amd".to_string(),
                    "GenuineIntel" => "intel".to_string(),
                    other if !other.is_empty() => other.to_ascii_lowercase(),
                    _ => "unknown".to_string(),
                };
                ram_gb = total_bytes.map(|b| b as f64 / (1024.0 * 1024.0 * 1024.0));
            }
            None => {
                // The query could not be run or came back unparseable. Report
                // the little we know for certain and leave the model name as
                // the placeholder, which the fingerprint guard already refuses.
                logical_cores = num_cpus();
                physical_cores = logical_cores;
            }
        }
    }

    // Every other target (653-7rag). Without this arm both bindings are read
    // uninitialized and the crate fails to COMPILE on Windows — a hard error in
    // `cargo build --workspace` for a contributor who touched nothing here.
    //
    // It survived because the commit that introduced it (bd8a47d1) was a Linux
    // host repairing platform-gated code that Linux cannot compile, and
    // `./build.sh --check` does not build the workspace. Both blind spots are
    // real; this arm removes the failure mode rather than relying on either
    // being fixed. Reporting fewer facts is correct here — the probe's contract
    // is "what this host can tell you", and an unknown physical count is a
    // legitimate answer where no enumeration path exists.
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        logical_cores = num_cpus();
        physical_cores = logical_cores;
    }

    DeviceRecord {
        device_class: "cpu".to_string(),
        vendor,
        name: cpu_name,
        device_node: None,
        fw_version: None,
        driver: None,
        usable: true,
        unusable_reason: None,
        policy_unscheduled: None,
        lanes: vec!["container".to_string(), "host-native".to_string()],
        memory_bandwidth_gbps: None,
        memory_bandwidth_source: "unknown".to_string(),
        cpu_flags: Some(flags),
        cpu_cores: Some(CpuCores {
            physical: physical_cores,
            logical: logical_cores,
        }),
        system_ram_gb: ram_gb,
        memory_model: None,
        name_source: Some(name_source),
    }
}

// @trace spec:accel-capability-probe
/// The WSL2 paravirtual-GPU decision, as a pure function so every combination
/// is testable without a matching host (order 806-2r4s).
///
/// WSL2 presents the GPU as `/dev/dxg` with the D3D12 userspace in
/// `/usr/lib/wsl/lib`, and exposes NO DRI render node. With no branch for that
/// shape the probe emits nothing at all, and `accel_envelope` then reports
/// `accel_gpu=none` — making a machine with a healthy GPU indistinguishable
/// from one that has none. Those are different engineering problems ("buy
/// hardware" versus "ship a lane"), and the fleet capability matrix cannot tell
/// them apart from the envelope alone.
///
/// The device is real and present; it is only unreachable by the engines we
/// ship today. That is exactly the present-unusable state `accel_envelope`
/// already renders — this function supplies the record it needs, and adds no
/// new vocabulary.
///
/// Returns `None` (emit nothing) unless the shape is unambiguously WSL2's:
/// `/dev/dxg` present, no DRI render node, and no better GPU already found.
/// `/dev/dxg` does not exist on bare-metal Linux, and a WSL2 host that DOES
/// expose a render node is handled by the `/dev/dri` arm, so this cannot
/// manufacture a phantom device off-WSL2.
// @trace spec:accel-capability-probe
#[cfg(target_os = "linux")]
fn wsl2_paravirtual_gpu(dxg_present: bool, dri_present: bool, already_found: bool) -> bool {
    dxg_present && !dri_present && !already_found
}

/// Why a WSL2 paravirtual GPU is unusable — as a value, so a test can pin it.
///
/// ORDER 793-zumy, AND THE REASON THIS IS A FUNCTION AT ALL. The literal used
/// to sit inline in `enumerate_gpus`, which reads real `/dev` paths and cannot
/// run in a unit test. The existing envelope test looked like it covered this
/// and did not: it builds its own `DeviceRecord` fixture, so it renders whatever
/// reason the TEST supplies and passes identically against a wrong production
/// value — verified by reverting the literal and watching it stay green. A pure
/// function is the smallest thing that makes the production value assertable.
/// Gated to match its production caller, `enumerate_gpus`, which is
/// `#[cfg(target_os = "linux")]` — plus `test` so the assertion 793-zumy added
/// this function to make possible still runs on every host. Without the `test`
/// arm the macOS gate fails on dead code; without the `linux` arm the Linux
/// build loses the production value. Order 935-6fzk found this from macOS,
/// where the Linux-only caller vanishes and nothing else references it.
#[cfg(any(target_os = "linux", test))]
/// ORDER 793-zumy. What actually stops the dxg device being reachable — the
/// PURE half, unit-tested, in the shape `amd_gpu_disposition` already uses on
/// this file's AMD arm.
///
/// THIS USED TO BE AN UNCONDITIONAL STRING LITERAL. `enumerate_gpus` assigned
/// `engine-missing:no-vulkan-icd` to EVERY dxg device, and nothing read
/// `icd.d`, `libvulkan`, or an enumeration result — so the probe stated a cause
/// it had not looked for. On esmeraldinha that statement is simply false: that
/// host carries a Vulkan loader and the stock Fedora mesa-vulkan-drivers ICD
/// set, unprovisioned, and enumerates Microsoft Direct3D12 (Intel UHD) as an
/// INTEGRATED_GPU via DRIVER_ID_MESA_DOZEN over /dev/dxg. A constant cannot be
/// wrong on one host and right on another; it was wrong everywhere and
/// coincidentally matched the hosts nobody had checked.
///
/// THE VERDICT IS STILL DELIBERATELY UNCHANGED — `usable` stays false and the
/// class stays cpu-only. Deciding a dxg device is USABLE requires enumerating
/// it and rejecting PHYSICAL_DEVICE_TYPE_CPU / DRIVER_ID_MESA_LLVMPIPE, which
/// is criterion 2's other half and needs a host that can enumerate. This change
/// stops the probe asserting a false CAUSE; it does not promote the device.
///
/// WHY THE THIRD ARM IS NOT `engine-missing`. Criterion 2 requires that word
/// verbatim for the case it describes — hardware present, no runtime to reach
/// it — and both missing arms keep it. When the loader AND an ICD are present
/// the engine is NOT missing, and saying so would be the same false statement
/// with a new spelling. `engine-unverified` says what is true: something is
/// installed, nothing has enumerated it yet. The owning packet should object
/// here if criterion 2 was meant to cover that case too.
fn wsl2_paravirtual_gpu_reason_from(loader_present: bool, icd_count: usize) -> String {
    match (loader_present, icd_count) {
        (false, _) => "engine-missing:no-vulkan-loader".to_string(),
        (true, 0) => "engine-missing:no-vulkan-icd".to_string(),
        (true, _) => "engine-unverified:vulkan-present-not-enumerated".to_string(),
    }
}

#[cfg(any(target_os = "linux", test))]
/// The IO half: what is actually on disk. `root` is a parameter ONLY so tests
/// can point it at a fixture tree — production passes "/" — which is the same
/// seam `enumerate_render_nodes_at` uses and for the same reason: a test that
/// read the real filesystem would assert whatever this machine happens to have,
/// which is the vacuous-green shape this file has been bitten by before.
///
/// Both ICD directories are read because the loader reads both: the packaged
/// set lives under /usr/share and local overrides under /etc. Counting `.json`
/// entries rather than listing them keeps this a fact-gatherer — the decision
/// belongs in the pure function above, not here.
fn wsl2_vulkan_facts_at(root: &std::path::Path) -> (bool, usize) {
    // The loader's SONAME, not the -dev symlink: `libvulkan.so` without the
    // version suffix is shipped by the development package and can be present
    // on a host that cannot actually load an ICD.
    let loader_present = [
        "usr/lib/x86_64-linux-gnu/libvulkan.so.1",
        "usr/lib64/libvulkan.so.1",
        "usr/lib/libvulkan.so.1",
    ]
    .iter()
    .any(|rel| root.join(rel).exists());

    let icd_count = ["usr/share/vulkan/icd.d", "etc/vulkan/icd.d"]
        .iter()
        .filter_map(|rel| std::fs::read_dir(root.join(rel)).ok())
        .flatten()
        .flatten()
        .filter(|e| {
            e.path()
                .extension()
                .is_some_and(|x| x.eq_ignore_ascii_case("json"))
        })
        .count();

    (loader_present, icd_count)
}

// ORDER 1135-z8gn follow-up (macbookair 2026-09-13), authorised by the
// coordinator; the substance belongs to 793-zumy.
//
// THIS WAS `#[cfg(any(target_os = "linux", test))]` AND THE `test` ARM IS NOW
// A LIE. It existed so a test could reach this function without a Linux
// target. 793-zumy then RETARGETED that test onto the `_from` seam below —
// its own comment says so — which left the arm compiling a function that, off
// Linux, nothing calls at all: the production caller is itself linux-gated.
//
// On Linux the function stays alive through that production caller, so the
// gate there never saw it. On macOS under `cfg(test)` it is dead code, and
// `-D dead-code` refused every macOS land until this line changed. The
// compiler was right both times; the two hosts were simply being asked
// different questions.
//
// THE PRODUCTION ENTRY POINT IS NOW UNCOVERED, AND THAT IS DELIBERATE HERE.
// Confirmed by 793-zumy's author (yolanda, 2026-09-13): the wrapper WAS meant
// to stay covered, and after this cfg drop nothing covers its two lines —
// their tree shows one production call inside the linux-gated block, zero test
// callers, and the only grep hit in the test region is a doc comment.
//
// The remedy is theirs and is a LATER SLICE under 793-zumy, not this change: a
// `wsl2_paravirtual_gpu_reason_at(root)` seam with production passing "/",
// matching what the neighbouring probes already do, so ONE fixture-rooted test
// covers it on every host instead of a cfg arm that only pretends to. Kept
// separate on purpose — two hosts reaching into one function is the collision
// this fleet has now had twice.
//
// A cfg arm kept alive for a caller that no longer exists is not coverage; it
// is the appearance of coverage, which is worse, because it is what stopped
// anyone noticing the wrapper was untested.
#[cfg(target_os = "linux")]
/// Production entry point: gather the facts from the live filesystem, then
/// decide. Kept as a thin seam so the decision stays testable without IO.
///
/// ORDER 793-zumy, CRITERION 2's OTHER HALF. This used to be the WHOLE
/// decision, and a filesystem read cannot make it: criterion 2 opens with
/// "Detection is by ENUMERATION, not file existence", and criterion 3 requires
/// that a software rasterizer never satisfy the GPU check. Neither is decidable
/// from `icd.d` — the directory that proves llvmpipe is installed is the same
/// directory that proves Dozen is. So the filesystem facts are now the FALLBACK
/// arm only, reached when nothing enumerated, and the verdict comes from an
/// actual `vkEnumeratePhysicalDevices` when one is reachable.
fn wsl2_paravirtual_gpu_verdict() -> Wsl2VulkanVerdict {
    let (loader, icds) = wsl2_vulkan_facts_at(std::path::Path::new("/"));
    wsl2_vulkan_verdict_from(enumerate_vulkan_physical_devices().as_deref(), loader, icds)
}

/// One enumerated Vulkan physical device, reduced to exactly what criterion 2
/// and criterion 3 decide on, plus the name that will reach the fleet matrix.
///
/// ORDER 793-zumy. `driver_id` AND `device_type` are both carried deliberately,
/// for the same reason `vendor_id` and `device_id` are used together elsewhere
/// in this file: either one alone is a partial answer. lavapipe reports
/// PHYSICAL_DEVICE_TYPE_CPU *and* DRIVER_ID_MESA_LLVMPIPE today, but a software
/// rasterizer that mislabels its own type is exactly the case the rejection
/// exists to survive, and a future one that reports OTHER would slip a
/// type-only check.
#[cfg(any(target_os = "linux", test))]
#[derive(Debug, Clone, PartialEq, Eq)]
struct VulkanPhysicalDevice {
    /// `VkPhysicalDeviceProperties::deviceType`, as the raw enum value.
    device_type: u32,
    /// `VkPhysicalDeviceDriverProperties::driverID`, as the raw enum value.
    driver_id: u32,
    /// `VkPhysicalDeviceProperties::deviceName`, for `name_source=enumerated`.
    name: String,
}

/// `VK_PHYSICAL_DEVICE_TYPE_CPU`.
#[cfg(any(target_os = "linux", test))]
const VK_PHYSICAL_DEVICE_TYPE_CPU: u32 = 4;
/// `VK_DRIVER_ID_MESA_LLVMPIPE`.
#[cfg(any(target_os = "linux", test))]
const VK_DRIVER_ID_MESA_LLVMPIPE: u32 = 13;

#[cfg(any(target_os = "linux", test))]
impl VulkanPhysicalDevice {
    /// Criterion 3, as one predicate: a device that is a CPU path wearing a
    /// Vulkan interface. MEASURED on esmeraldinha 2026-09-18, both arms live in
    /// one enumeration: `llvmpipe (LLVM 22.1.8, 256 bits)` type=CPU(4)
    /// driverID=13 beside `Microsoft Direct3D12 (Intel(R) UHD Graphics)`
    /// type=INTEGRATED_GPU(1) driverID=23 (Dozen) over /dev/dxg.
    fn is_software_rasterizer(&self) -> bool {
        self.device_type == VK_PHYSICAL_DEVICE_TYPE_CPU
            || self.driver_id == VK_DRIVER_ID_MESA_LLVMPIPE
    }
}

/// What the probe is entitled to say about a `/dev/dxg` device.
#[cfg(any(target_os = "linux", test))]
#[derive(Debug, Clone, PartialEq, Eq)]
enum Wsl2VulkanVerdict {
    /// A non-CPU physical device enumerated. Carries the name it enumerated
    /// under, so the record stops being a placeholder on the one host that can
    /// prove otherwise.
    Usable { name: String },
    /// Not usable, and the reason says which question was actually asked.
    Unusable { reason: String },
}

/// ORDER 793-zumy — the pure half of criterion 2's enumeration clause and all
/// of criterion 3.
///
/// `enumeration` IS AN OPTION AND THAT IS THE WHOLE POINT. `None` means nobody
/// enumerated — no loader to `dlopen`, no instance, no `vkGetPhysicalDeviceProperties2`
/// — and `Some(&[])` means the loader answered and offered nothing. This file
/// has paid for collapsing those twice already (`accel_proof=-` conflating
/// "nobody to ask" with "asked and found none"; `accel_npu=none` derived from a
/// question that failed), so the distinction is in the type rather than in a
/// comment.
///
/// THE `None` ARM DELEGATES TO THE FILESYSTEM READING UNCHANGED, which is what
/// keeps criterion 4 true: on every host that could not enumerate, the envelope
/// is byte-identical to what it produced before this change. The two
/// `engine-missing` arms criterion 2 requires verbatim are untouched.
#[cfg(any(target_os = "linux", test))]
fn wsl2_vulkan_verdict_from(
    enumeration: Option<&[VulkanPhysicalDevice]>,
    loader_present: bool,
    icd_count: usize,
) -> Wsl2VulkanVerdict {
    let Some(devices) = enumeration else {
        return Wsl2VulkanVerdict::Unusable {
            reason: wsl2_paravirtual_gpu_reason_from(loader_present, icd_count),
        };
    };

    if let Some(real) = devices.iter().find(|d| !d.is_software_rasterizer()) {
        return Wsl2VulkanVerdict::Usable {
            name: real.name.clone(),
        };
    }

    // Enumerated, and what came back does not answer the question. Both arms
    // keep `engine-missing` — criterion 2's word for "hardware present, no
    // runtime that reaches it" — because that is exactly the state: the dxg
    // device is delivered and nothing translating onto it enumerated.
    Wsl2VulkanVerdict::Unusable {
        reason: if devices.is_empty() {
            // The loader ran and offered zero devices. Distinct from no loader:
            // this one names a question that WAS asked.
            "engine-missing:vulkan-enumerated-no-device".to_string()
        } else {
            // Criterion 3's refusal, and it must be its own token: a host where
            // lavapipe is the only answer looks identical to a working one in
            // every filesystem fact, and differs only here.
            "engine-missing:vulkan-software-rasterizer-only".to_string()
        },
    }
}

/// ORDER 793-zumy — the IO half: actually enumerate.
///
/// WHY `dlopen` AND NOT A VULKAN CRATE. This is a PROBE. A build-time binding
/// (`ash`) would link the loader into every build of a binary that must run on
/// hosts with no Vulkan at all, and would turn "this host has no loader" — a
/// first-class answer this function has to be able to give — into a link error
/// or a panic. Loading by SONAME at runtime and returning `None` when it is not
/// there is the shape the answer requires. It also adds no lockfile entry:
/// `libc` is already a dependency of this crate.
///
/// WHY THE STRUCT DEFINITIONS STOP WHERE THEY DO. Only the head of
/// `VkPhysicalDeviceProperties` is read (`deviceType` and `deviceName`), so
/// rather than transcribe `VkPhysicalDeviceLimits` — 100-odd fields whose
/// layout this file would then own and could silently get wrong — the
/// `VkPhysicalDeviceProperties2` receiving buffer is an over-sized aligned byte
/// array that the loader writes into, and the two fields are read at their
/// fixed offsets. A transcription error in a field nobody reads is a
/// vacuous-green defect; an over-sized buffer cannot have one.
///
/// Returns `None` — never `Some(vec![])` — for every failure of the mechanism
/// itself, so "nobody asked" never arrives dressed as "asked and found none".
/// MEMOISED FOR THE LIFE OF THE PROCESS, for the reason spelled out at the
/// `vkDestroyInstance` comment below: the instance this creates is never
/// destroyed, so running the body twice would leak twice. Enumerating the
/// host's physical devices is also not a question whose answer changes while
/// the process runs — a GPU does not appear mid-probe — so a second call would
/// pay the ICD load again for an identical answer.
///
/// This is NOT the `~/.cache/tillandsias/capabilities.json` cache (1139-xe5m)
/// and must not be confused with it: nothing here survives the process, so a
/// fresh run always re-enumerates and this can never serve a stale provisioning
/// state across runs.
#[cfg(target_os = "linux")]
fn enumerate_vulkan_physical_devices() -> Option<Vec<VulkanPhysicalDevice>> {
    static ENUMERATION: std::sync::OnceLock<Option<Vec<VulkanPhysicalDevice>>> =
        std::sync::OnceLock::new();
    ENUMERATION
        .get_or_init(enumerate_vulkan_physical_devices_uncached)
        .clone()
}

#[cfg(target_os = "linux")]
fn enumerate_vulkan_physical_devices_uncached() -> Option<Vec<VulkanPhysicalDevice>> {
    use std::ffi::{CStr, CString, c_char, c_void};

    const VK_STRUCTURE_TYPE_APPLICATION_INFO: u32 = 0;
    const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: u32 = 1;
    const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2: u32 = 1_000_059_001;
    const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES: u32 = 1_000_196_000;
    // VK_MAKE_API_VERSION(0, 1, 1, 0). 1.1 is what promotes
    // vkGetPhysicalDeviceProperties2 into core; the KHR alias is tried as a
    // fallback below for a 1.0 loader carrying the extension.
    const VK_API_VERSION_1_1: u32 = (1 << 22) | (1 << 12);
    // A WSL2 guest does not have dozens of GPUs. The cap exists so a
    // nonsense count out of a broken ICD cannot drive an allocation.
    const MAX_DEVICES: u32 = 16;

    #[repr(C)]
    struct VkApplicationInfo {
        s_type: u32,
        p_next: *const c_void,
        p_application_name: *const c_char,
        application_version: u32,
        p_engine_name: *const c_char,
        engine_version: u32,
        api_version: u32,
    }

    #[repr(C)]
    struct VkInstanceCreateInfo {
        s_type: u32,
        p_next: *const c_void,
        flags: u32,
        p_application_info: *const VkApplicationInfo,
        enabled_layer_count: u32,
        pp_enabled_layer_names: *const *const c_char,
        enabled_extension_count: u32,
        pp_enabled_extension_names: *const *const c_char,
    }

    #[repr(C)]
    struct VkPhysicalDeviceDriverProperties {
        s_type: u32,
        p_next: *mut c_void,
        driver_id: u32,
        driver_name: [c_char; 256],
        driver_info: [c_char; 256],
        conformance_version: [u8; 4],
    }

    // The receiving buffer for VkPhysicalDeviceProperties2. 8-aligned because
    // the struct it stands in for contains VkDeviceSize (u64) members.
    #[repr(C, align(8))]
    struct Properties2Buffer([u8; 4096]);

    // Offsets into that buffer. sType(4) + padding(4) + pNext(8) = 16 is where
    // the embedded VkPhysicalDeviceProperties starts; within it,
    // apiVersion/driverVersion/vendorID/deviceID are four u32 before
    // deviceType, and deviceName follows immediately.
    const PROPERTIES_OFFSET: usize = 16;
    const DEVICE_TYPE_OFFSET: usize = PROPERTIES_OFFSET + 16;
    const DEVICE_NAME_OFFSET: usize = PROPERTIES_OFFSET + 20;
    const VK_MAX_PHYSICAL_DEVICE_NAME_SIZE: usize = 256;

    type PfnVoid = unsafe extern "C" fn();
    type PfnGetInstanceProcAddr = unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_void;
    type PfnCreateInstance =
        unsafe extern "C" fn(*const VkInstanceCreateInfo, *const c_void, *mut *mut c_void) -> i32;
    type PfnEnumeratePhysicalDevices =
        unsafe extern "C" fn(*mut c_void, *mut u32, *mut *mut c_void) -> i32;
    type PfnGetPhysicalDeviceProperties2 = unsafe extern "C" fn(*mut c_void, *mut c_void);

    // SAFETY: every call below is an ABI-correct call into the Vulkan loader
    // through pointers it handed back, with every failure returning None
    // before the next pointer is used. No Rust value outlives the instance.
    unsafe {
        let soname = CString::new("libvulkan.so.1").ok()?;
        let lib = libc::dlopen(soname.as_ptr(), libc::RTLD_NOW);
        if lib.is_null() {
            return None;
        }

        let sym = |name: &str| -> Option<*mut c_void> {
            let c = CString::new(name).ok()?;
            let p = libc::dlsym(lib, c.as_ptr());
            if p.is_null() { None } else { Some(p) }
        };

        let get_instance_proc_addr: PfnGetInstanceProcAddr =
            std::mem::transmute::<*mut c_void, PfnGetInstanceProcAddr>(sym(
                "vkGetInstanceProcAddr",
            )?);

        let proc_addr = |instance: *mut c_void, name: &str| -> Option<PfnVoid> {
            let c = CString::new(name).ok()?;
            let p = get_instance_proc_addr(instance, c.as_ptr());
            if p.is_null() {
                None
            } else {
                Some(std::mem::transmute::<*mut c_void, PfnVoid>(p))
            }
        };

        let create_instance: PfnCreateInstance = std::mem::transmute::<PfnVoid, PfnCreateInstance>(
            proc_addr(std::ptr::null_mut(), "vkCreateInstance")?,
        );

        let app_name = CString::new("tillandsias-accel-probe").ok()?;
        let engine_name = CString::new("tillandsias").ok()?;
        let app_info = VkApplicationInfo {
            s_type: VK_STRUCTURE_TYPE_APPLICATION_INFO,
            p_next: std::ptr::null(),
            p_application_name: app_name.as_ptr(),
            application_version: 0,
            p_engine_name: engine_name.as_ptr(),
            engine_version: 0,
            api_version: VK_API_VERSION_1_1,
        };
        let create_info = VkInstanceCreateInfo {
            s_type: VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            p_next: std::ptr::null(),
            flags: 0,
            p_application_info: &app_info,
            enabled_layer_count: 0,
            pp_enabled_layer_names: std::ptr::null(),
            enabled_extension_count: 0,
            pp_enabled_extension_names: std::ptr::null(),
        };

        let mut instance: *mut c_void = std::ptr::null_mut();
        if create_instance(&create_info, std::ptr::null(), &mut instance) != 0 || instance.is_null()
        {
            return None;
        }

        // From here on every early return must still destroy the instance, so
        // the body is a closure and the teardown is unconditional after it.
        let mut out: Option<Vec<VulkanPhysicalDevice>> = None;
        'enumerate: {
            let Some(enumerate) = proc_addr(instance, "vkEnumeratePhysicalDevices") else {
                break 'enumerate;
            };
            let enumerate: PfnEnumeratePhysicalDevices =
                std::mem::transmute::<PfnVoid, PfnEnumeratePhysicalDevices>(enumerate);

            let get_props2 = proc_addr(instance, "vkGetPhysicalDeviceProperties2")
                .or_else(|| proc_addr(instance, "vkGetPhysicalDeviceProperties2KHR"));
            let Some(get_props2) = get_props2 else {
                break 'enumerate;
            };
            let get_props2: PfnGetPhysicalDeviceProperties2 =
                std::mem::transmute::<PfnVoid, PfnGetPhysicalDeviceProperties2>(get_props2);

            let mut count: u32 = 0;
            if enumerate(instance, &mut count, std::ptr::null_mut()) != 0 {
                break 'enumerate;
            }
            count = count.min(MAX_DEVICES);

            let mut handles: Vec<*mut c_void> = vec![std::ptr::null_mut(); count as usize];
            if count > 0 && enumerate(instance, &mut count, handles.as_mut_ptr()) != 0 {
                break 'enumerate;
            }
            handles.truncate(count as usize);

            let mut devices = Vec::with_capacity(handles.len());
            for handle in handles {
                if handle.is_null() {
                    continue;
                }

                let mut driver_props = VkPhysicalDeviceDriverProperties {
                    s_type: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
                    p_next: std::ptr::null_mut(),
                    driver_id: 0,
                    driver_name: [0; 256],
                    driver_info: [0; 256],
                    conformance_version: [0; 4],
                };
                let mut buffer = Properties2Buffer([0u8; 4096]);
                let base = buffer.0.as_mut_ptr();
                base.cast::<u32>()
                    .write(VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2);
                base.add(8)
                    .cast::<*mut c_void>()
                    .write((&raw mut driver_props).cast::<c_void>());

                get_props2(handle, base.cast::<c_void>());

                let device_type = base.add(DEVICE_TYPE_OFFSET).cast::<u32>().read();
                let name_bytes = std::slice::from_raw_parts(
                    base.add(DEVICE_NAME_OFFSET),
                    VK_MAX_PHYSICAL_DEVICE_NAME_SIZE,
                );
                let name = CStr::from_bytes_until_nul(name_bytes)
                    .ok()
                    .and_then(|c| c.to_str().ok())
                    .unwrap_or("")
                    .to_string();

                devices.push(VulkanPhysicalDevice {
                    device_type,
                    driver_id: driver_props.driver_id,
                    name,
                });
            }
            out = Some(devices);
        }

        // THE INSTANCE IS DELIBERATELY NOT DESTROYED, AND THIS IS MEASURED,
        // NOT A CONVENIENCE. esmeraldinha, 2026-09-18, Mesa 26.1.6 dzn+lvp in
        // a WSL2 guest: with a `vkDestroyInstance` call here, a probe run on
        // ANY NON-MAIN THREAD segfaults — not during the enumeration, which
        // completes and returns the right two devices, but when that thread
        // LATER EXITS. Isolated to this one call by a four-way experiment:
        //
        //   main thread,     with destroy  -> fine, 10 iterations
        //   spawned thread,  with destroy  -> enumerates, then SIGSEGV at thread exit
        //   spawned thread,  no destroy    -> fine, repeated threads, repeated calls
        //   `cargo test`,    with destroy  -> SIGSEGV (libtest runs every test on a
        //                                     spawned thread, which is how this was found)
        //
        // The ICD's thread-local teardown runs after the instance it belongs
        // to is gone. That is the ICD's defect — the loader prints "dzn is not
        // a conformant Vulkan implementation, testing use only" on every
        // instance creation — and this probe cannot fix it; it can only avoid
        // standing in front of it.
        //
        // THE COST IS ONE LEAKED INSTANCE PER PROCESS, AND NOT ONE PER CALL:
        // the result is memoised below, so this body runs at most once. A
        // probe that already loads a third-party ICD into its own address
        // space is not the place to insist on a teardown that crashes the
        // host process — and a crash here would take down the tray, which is
        // a far worse failure than a retained allocation in a process that is
        // about to write a capabilities document and move on.
        //
        // DO NOT "TIDY THIS UP" by restoring the destroy call without
        // re-running the four-way experiment above on a dxg-plus-ICD guest.
        // The Windows and macOS gates cannot see this code at all, and the
        // Linux gate only catches it because libtest happens to use threads.
        let _ = instance;

        out
    }
}

/// Order 850-bif2, the pure decision half of the AMD arm (unit-tested):
/// given what the walker observed for an amdgpu card, decide usability,
/// lanes, and the reason for any refusal.
///
/// `rocm-smi` presence alone is deliberately NOT evidence — the tier lattice
/// already learned that on Fedora (see detect_inference_tier's caveat): the
/// admission ticket is a ROCm runtime reporting a gfx agent. Without it the
/// device is present-unusable, which the matrix renders distinctly from
/// absent — that distinction is the whole point of recording it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn amd_gpu_disposition(
    rocm_gfx: bool,
    kfd: bool,
    render_node: bool,
) -> (bool, Vec<String>, Option<String>) {
    if !rocm_gfx {
        return (
            false,
            vec!["host-native".to_string()],
            Some("rocm-runtime-missing".to_string()),
        );
    }
    if !kfd {
        return (
            false,
            vec!["host-native".to_string()],
            Some("kfd-missing".to_string()),
        );
    }
    if !render_node {
        return (false, vec![], Some("render-node-missing".to_string()));
    }
    // ORDER 793-zumy: THE CONTAINER LANE IS NOT CLAIMED HERE, and its absence is
    // the fix rather than an omission.
    //
    // Every input above — rocm_gfx, kfd, render_node — is read from the HOST.
    // MEASURED on yoga 2026-08-30: all three were true, this function therefore
    // advertised `container`, and inside the container /dev/kfd and /dev/dri
    // were absent, size_vram was 0.00GB for every model, and the runtime
    // reported library=cpu. After their passthrough fix put the device nodes
    // IN the container, size_vram was STILL 0.00GB — the image ships no
    // ROCm/HIP backend. The envelope did not move a single character across
    // that entire real change.
    //
    // So host-vantage evidence cannot support a container-lane claim, twice
    // over: it does not know what `--device` flags a launcher will pass, and
    // even when they are passed it does not know whether a runtime inside can
    // drive them. Those are `Proof::Reachable` and `Proof::Placed`
    // respectively, and a sysfs read reaches neither.
    //
    // Unlike NVIDIA there is no CDI spec to read — AMD passthrough is explicit
    // `--device` at launch — so there is nothing host-side to inspect. The
    // honest report is the lane we CAN prove, plus a reason naming what is
    // unverified rather than silently dropping it.
    (
        true,
        vec!["host-native".to_string()],
        Some("container-lane-unverified".to_string()),
    )
}

/// ORDER 1011-zp59 — is THIS integrated GPU left unscheduled by POLICY?
///
/// Returns the reason string when a discrete GPU is present AND SCHEDULABLE
/// beside an integrated one, else `None`.
///
/// KEYED ON "A DISCRETE GPU IS PRESENT AND SCHEDULABLE", NEVER ON `tier ==
/// gpu-cuda`, and the difference is not pedantic. `effective_inference_tier()`
/// DOWNGRADES gpu-cuda to cpu when no CDI spec exists, and on that host the
/// integrated GPU is the only accelerator there is — the best lane available,
/// not a rejected one. Keying on the tier label would stamp
/// `policy:discrete-gpu-preferred` on a device that had just become the
/// preferred device, which is a worse lie than the one this packet fixes: the
/// current row at least fails toward "unusable", while that would fail toward
/// "correctly deprioritised" on a host with nothing else. The second fixture
/// arm exists for exactly that case.
///
/// "Schedulable" here means what the matrix means by it: usable, with at least
/// one lane. A discrete card that is present and unusable — no driver, no CDI —
/// does not get to deprioritise anything.
/// The call-site half of the discriminator, extracted so it can be TESTED.
///
/// `igpu_policy_unscheduled_reason` takes a boolean, so "no discrete card" and
/// "a discrete card that cannot be scheduled" collapse to the same input there
/// and a test of that function cannot tell them apart. This is where they are
/// actually distinguished, and therefore where the CDI-absent host has to be
/// pinned — asserting it one level up would be a test that passes for a reason
/// other than the one it names.
///
/// SCHEDULABLE, not merely present: usable AND carrying at least one lane. A
/// discrete card with no driver, or one whose lanes are all unproven, is not a
/// better option than the integrated part and does not get to deprioritise it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn discrete_gpu_is_schedulable(gpus: &[DeviceRecord]) -> bool {
    gpus.iter().any(|g| {
        g.device_class == "gpu"
            && g.usable
            && !g.lanes.is_empty()
            && g.memory_model.as_deref() == Some("discrete")
    })
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn igpu_policy_unscheduled_reason(
    this_device_is_integrated: bool,
    discrete_present_and_schedulable: bool,
) -> Option<String> {
    if !this_device_is_integrated || !discrete_present_and_schedulable {
        return None;
    }
    // The reason carries the MEASUREMENT, not just the verdict, because a bare
    // `policy:discrete-gpu-preferred` is the same unfalsifiable shape as the
    // reason string it replaces: a reader could not tell a measured preference
    // from an assumed one. The "fully resident" clause is load-bearing — it
    // says the losing arm placed COMPLETELY (size_vram == size), so the ratio
    // is a fair GPU-vs-GPU comparison and not the partial-offload artefact it
    // would otherwise be mistaken for.
    Some(
        "policy:discrete-gpu-preferred; measured lenovinha 2026-09-04, \
         both models fully resident size_vram==size: decode 4.3-4.9x, \
         embed 3.1x in favour of the discrete card"
            .to_string(),
    )
}

/// Intel's admission ticket, the sibling of `amd_gpu_disposition`.
///
/// Order 855-wrr3. An i915/xe RENDER NODE PROVES A DISPLAY/MEDIA DRIVER, NEVER
/// A COMPUTE LANE. Alder Lake-N ships /dev/dri/renderD128 on a part no engine
/// in this project can offload to, and Intel was the one vendor with no
/// disposition check at all: it fell through to the last-resort arm, which
/// hardcodes `usable: true` because a DRM card exists. On the fleet's declared
/// LOWER-BOUND host that published `accel_class=workstation-gpu` for a 4-core
/// N150 while the SAME BINARY's `--inference-tier` answered `tier:cpu`.
///
/// The ticket is an Intel compute runtime — Level Zero or an OpenCL ICD — the
/// same shape as ROCm's gfx agent. Without it the device is present-unusable
/// with the reason named, which the matrix renders distinctly from absent.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn intel_gpu_disposition(
    compute_runtime: bool,
    render_node: bool,
) -> (bool, Vec<String>, Option<String>) {
    if !compute_runtime {
        return (
            false,
            vec!["host-native".to_string()],
            Some("intel-compute-runtime-missing".to_string()),
        );
    }
    if !render_node {
        return (false, vec![], Some("render-node-missing".to_string()));
    }
    (
        true,
        vec!["container".to_string(), "host-native".to_string()],
        None,
    )
}

/// Every /sys/class/drm/card<N> as (pci_address, vendor_id, driver), sorted
/// by card number. Reads sysfs only; anything unreadable is skipped rather
/// than guessed.
#[cfg(target_os = "linux")]
fn drm_cards() -> Vec<(String, String, Option<String>)> {
    let mut cards: Vec<(String, String, Option<String>)> = Vec::new();
    let Ok(entries) = fs::read_dir("/sys/class/drm") else {
        return cards;
    };
    let mut names: Vec<String> = entries
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| {
            n.strip_prefix("card")
                .is_some_and(|rest| !rest.is_empty() && rest.bytes().all(|b| b.is_ascii_digit()))
        })
        .collect();
    names.sort();
    for name in names {
        let dev = Path::new("/sys/class/drm").join(&name).join("device");
        let Ok(target) = fs::canonicalize(&dev) else {
            continue;
        };
        let Some(pci_addr) = target.file_name().map(|f| f.to_string_lossy().to_string()) else {
            continue;
        };
        let Some(vendor_id) = fs::read_to_string(dev.join("vendor"))
            .ok()
            .map(|s| s.trim().to_lowercase())
        else {
            continue;
        };
        let driver = fs::read_to_string(dev.join("uevent")).ok().and_then(|u| {
            u.lines()
                .find_map(|l| l.strip_prefix("DRIVER=").map(|d| d.trim().to_string()))
        });
        cards.push((pci_addr, vendor_id, driver));
    }
    cards
}

/// The /dev/dri/renderD* node whose sysfs device resolves to the same PCI
/// address, if any — the node the container run args would deliver.
#[cfg(target_os = "linux")]
fn drm_render_node_for(pci_addr: &str) -> Option<String> {
    let entries = fs::read_dir("/sys/class/drm").ok()?;
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if !name.starts_with("renderD") {
            continue;
        }
        let dev = Path::new("/sys/class/drm").join(&name).join("device");
        if let Ok(target) = fs::canonicalize(&dev)
            && target.file_name().map(|f| f.to_string_lossy().to_string())
                == Some(pci_addr.to_string())
        {
            let node = format!("/dev/dri/{name}");
            if Path::new(&node).exists() {
                return Some(node);
            }
        }
    }
    None
}

/// Marketing name for a PCI device via `lspci -mm -s <addr>`, parsing the
/// QUOTED device field — never a substring of the whole line (the
/// comp-ATI-ble trap). None when lspci is absent or the line is malformed.
#[cfg(target_os = "linux")]
fn pci_device_name_via_lspci(pci_addr: &str) -> Option<String> {
    // lspci speaks the short form (05:00.0); sysfs the long (0000:05:00.0).
    let short = pci_addr.strip_prefix("0000:").unwrap_or(pci_addr);
    let out = Command::new("lspci")
        .args(["-mm", "-s", short])
        .output()
        .ok()
        .filter(|o| o.status.success())?;
    let line = String::from_utf8_lossy(&out.stdout);
    // Quoted fields: [1]=class, [3]=vendor, [5]=device name.
    let fields: Vec<&str> = line.trim().split('"').collect();
    let name = fields.get(5)?.trim();
    if name.is_empty() {
        None
    } else {
        Some(name.to_string())
    }
}

/// Does `rocminfo` report a gfx agent? Mirrors detect_inference_tier: the
/// runtime answering for the silicon, not a tool merely being installed.
#[cfg(target_os = "linux")]
fn rocm_gfx_present() -> bool {
    Command::new("rocminfo")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("gfx"))
        .unwrap_or(false)
}

/// Is an Intel COMPUTE runtime installed? Filesystem probe only — no
/// subprocess, and nothing substring-matches prose (the comp-ATI-ble trap).
/// Level Zero is the primary ticket; an Intel OpenCL ICD is accepted as the
/// secondary. Mesa's Vulkan ICD is deliberately NOT evidence here: it is
/// present in the Fedora Silverblue base on every Intel host and would
/// re-admit exactly the display silicon this check exists to exclude.
#[cfg(target_os = "linux")]
fn intel_compute_runtime_present() -> bool {
    const ZE: [&str; 4] = [
        "/usr/lib64/libze_intel_gpu.so.1",
        "/usr/lib64/libze_loader.so.1",
        "/usr/lib/x86_64-linux-gnu/libze_intel_gpu.so.1",
        "/usr/lib/x86_64-linux-gnu/libze_loader.so.1",
    ];
    if ZE.iter().any(|p| Path::new(p).exists()) {
        return true;
    }
    fs::read_dir("/etc/OpenCL/vendors")
        .map(|d| {
            d.flatten()
                .any(|e| e.file_name().to_string_lossy().contains("intel"))
        })
        .unwrap_or(false)
}

/// ORDER 793-zumy — REAL GPU ENUMERATION, replacing file-existence detection.
///
/// THE CLASS THIS EXISTS TO END, in yoga's words: A LABEL THAT SUBSTITUTES FOR
/// THE WIRING IT NAMES. Four measured instances, one shape:
///
///   * accel_probe.rs computed `cdi_ok = effective_tier == "gpu-cuda"` — a label
///     derived from the same `nvidia-smi` the surrounding code had already run.
///     The container lane was advertised on a host where
///     `podman run --device nvidia.com/gpu=all` returned rc=126 (935-jhh5).
///   * WSL2 detection is `dxg_present && !dri_present` — file existence. Nothing
///     enumerates, so the software-rasterizer rejection this packet requires is
///     not merely untested there, it is UNIMPLEMENTABLE (yolanda, 793-zumy).
///   * The inference container announced `TILLANDSIAS_INFERENCE_TIER=gpu-rocm`
///     with `HostConfig.Devices == []` and `size_vram=0` on every model (yoga).
///   * dev-inference-ensure.sh wires `--device` for gpu-cuda only; gpu-rocm falls
///     through empty while the tier label is still passed in (yoga).
///
/// A label that stands in for wiring READS AS EVIDENCE to every later reader,
/// which is why the gap survived three orders unnoticed.
///
/// THE RULE: a lane is proven by what can be STATTED OR PLACED — a device node
/// visible in-container, a nonzero size_vram, a real enumeration — never by a
/// label, an env var, or the presence of a file. The precedent is already
/// in-tree and is a shell script: images/inference/entrypoint.sh refuses a cuda
/// tier when `[ -e /dev/nvidia0 ]` fails INSIDE the container.
///
/// WHY DRM RENDER NODES ARE THE RIGHT PRIMITIVE HERE, measured on lenovinha
/// 2026-08-30 — the fleet's only dual-vendor host:
///
///   renderD128  vendor=0x1002 device=0x1638 driver=amdgpu   (AMD Cezanne iGPU)
///   renderD129  vendor=0x10de device=0x24dd driver=nvidia    (RTX 3070 dGPU)
///
///   1. IT REPRESENTS TWO GPUs. `/dev/dri exists` is one bit and cannot; this is
///      the enumeration gap 793-zumy was filed against, and this host is the
///      fixture that shows it.
///   2. IT CARRIES REAL IDENTITY — PCI vendor/device and the BOUND KERNEL
///      DRIVER, not a guess from a filename.
///   3. IT REJECTS SOFTWARE RASTERIZERS STRUCTURALLY. lavapipe/llvmpipe are
///      USERSPACE-ONLY ICDs: they create no DRM render node, so an enumeration
///      of render nodes cannot see them AT ALL. Criterion 3 is satisfied by
///      construction rather than by a blocklist of driver names — and a
///      blocklist is exactly the shape that rots when a new rasterizer appears.
///
/// WHAT THIS DELIBERATELY DOES NOT COVER, stated so nobody reads it as total:
/// WSL2. /dev/dxg is not a DRM device and creates no render node, so a
/// paravirtualised GPU is invisible here and its arm must keep its own proof.
/// Yolanda's `engine-missing:no-vulkan-icd` reason already carries that case
/// honestly. Enumerating nothing on WSL2 is CORRECT for this primitive; it is
/// the WSL2 arm's job to say what it can prove, not this one's job to guess.
/// WHERE a piece of evidence was gathered. Yoga's tightening of the rule, and it
/// is the dimension whose absence produced their finding: not "proven by what
/// can be statted or placed" but PROVEN BY WHAT CAN BE STATTED FROM WHERE THE
/// WORK HAPPENS.
///
/// Measured on yoga 2026-08-30, one machine, two true statements:
///   host envelope : accel_gpu=usable, /dev/kfd 235,0 and /dev/dri/renderD128 present
///   in-container  : /dev/kfd absent, /dev/dri absent, size_vram=0 for every model
/// "usable" was true of the MACHINE and false of every lane any workload runs
/// in, and nothing in the envelope distinguished those. The node existed the
/// entire time it was missing where it mattered.
///
/// So a record carries its vantage. An enumeration performed on the host is
/// evidence ABOUT THE HOST and must never be read as a container-lane claim —
/// which is exactly the substitution this packet exists to end, one level up
/// from the label.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Vantage {
    /// Observed from the host's own filesystem.
    Host,
    /// Observed from inside a container — the only vantage that can speak for
    /// the container lane. `images/inference/entrypoint.sh` is the in-tree
    /// precedent: it refuses a cuda tier when `[ -e /dev/nvidia0 ]` fails THERE.
    Container,
}

impl Vantage {
    pub fn token(&self) -> &'static str {
        match self {
            Vantage::Host => "host",
            Vantage::Container => "container",
        }
    }
}

/// HOW FAR THE EVIDENCE ACTUALLY GOES. Yoga's second refinement, measured on
/// their host 2026-08-30, and it is a rung this model did not have.
///
/// My rule after their first message was "statted from where the work happens".
/// They then supplied the case that breaks it, and it is the case a
/// label-based probe gets wrong most confidently:
///
///     hardware present                              yes  (real AMD, real PCI ids)
///     device nodes stat-able INSIDE the container   yes  (/dev/kfd, /dev/dri/renderD128)
///     a runtime that can drive them                 NO   (no ROCm/HIP backend in the image)
///     -> size_vram = 0.00GB, decode 12.18 -> 12.22 tok/s, unchanged
///
/// EVERY SIGNAL SHORT OF PLACEMENT SAID YES. The vantage rule was satisfied and
/// the lane still could not run. So: A STAT PROVES THE DEVICE IS REACHABLE FROM
/// WHERE THE WORK HAPPENS; IT DOES NOT PROVE A LANE. ONLY PLACEMENT PROVES A
/// LANE. Two rungs, not one — and the three requirements (hardware, device
/// nodes, a runtime) are INDEPENDENT. The tier label asserted all three.
///
/// THE IN-TREE PROOF THAT THIS DISTINCTION IS ALREADY UNDERSTOOD, and the
/// sharpest thing in yoga's report: on that same envelope the NPU line reads
/// `engine-missing` while the GPU line reads `usable` — the two devices are in
/// the IDENTICAL state. The GPU's verdict came from a label; the NPU's came
/// from something closer to a check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Proof {
    /// The hardware exists and identifies itself. Says nothing about any lane.
    Enumerated,
    /// Its device nodes are stat-able from the vantage the work runs in.
    /// Necessary, and NOT sufficient — this is exactly where yoga's host sat
    /// with size_vram still 0.
    Reachable,
    /// Work was actually placed on it: a runtime reported non-zero residency.
    /// The only rung that proves a lane EXISTS.
    ///
    /// AND IT IS NOT A CLAIM ABOUT CAPACITY — yoga's caveat, recorded here so
    /// this rung does not inherit the problem it fixes. Non-zero residency
    /// proves a runtime placed weights on a device. It does NOT prove the
    /// device is doing the compute (a PARTIAL OFFLOAD reports non-zero VRAM
    /// while most layers run on CPU), and it does not prove the lane works at
    /// the size that matters (a lane that places 200 MB may still fail at
    /// 5 GB).
    ///
    /// PLACED ANSWERS "DID ANY WORK LAND HERE", NOT "WILL THE WORK LAND HERE".
    /// A scheduler reading it as capacity is making the same substitution one
    /// rung up, which is exactly how this family reproduces.
    Placed,
}

impl Proof {
    pub fn token(&self) -> &'static str {
        match self {
            Proof::Enumerated => "enumerated",
            Proof::Reachable => "reachable",
            Proof::Placed => "placed",
        }
    }
    /// A lane may be ADVERTISED only at the top rung. Deliberately not `>=
    /// Reachable`: that is the mistake this whole packet family is about, and
    /// it is one keystroke away, so it is stated as a method rather than left
    /// to each caller's comparison.
    pub fn proves_a_lane(&self) -> bool {
        matches!(self, Proof::Placed)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DrmRenderNode {
    /// e.g. "renderD128"
    pub node: String,
    /// PCI vendor id, e.g. 0x10de
    pub vendor_id: u16,
    /// PCI device id.
    ///
    /// USE THIS WITH `vendor_id`, NEVER ALONE.
    ///
    /// CORRECTED 2026-08-30. This comment previously argued the point with a
    /// FABRICATED counterexample — "0x1638 is BOTH yoga's Krackan Radeon
    /// 840M/860M AND lenovinha's Cezanne". That is false. Measured from each
    /// host's own `lspci -nn`:
    ///
    ///   yoga       04:00.0 Krackan Radeon 840M/860M   [1002:1114]
    ///   lenovinha  05:00.0 Cezanne  Radeon Vega       [1002:1638]
    ///
    /// device_id DISCRIMINATES those two parts; it does not collide. I took the
    /// collision from a peer message rather than from an artifact, and wrote it
    /// into a doc comment that outlives the message — the assertion-not-artifact
    /// error, committed on the very field built to resist it.
    ///
    /// THE CONCLUSION SURVIVES, on a measured argument instead of an invented
    /// one: VENDOR alone collides — yoga's 1002:1114 and lenovinha's 1002:1638
    /// share 0x1002, so vendor identifies a manufacturer, not a part. And on
    /// lenovinha the two render nodes are different vendors AND different
    /// devices (0x1002:0x1638 amdgpu, 0x10de:0x24dd nvidia), so the node index
    /// carries no identity of its own. The PAIR, keyed to the node, is what
    /// names a GPU. Neither half alone is sufficient, and only one half was ever
    /// shown to collide.
    pub device_id: u16,
    /// bound kernel driver, e.g. "amdgpu" / "nvidia" / "i915"
    pub driver: String,
    /// WHERE this was observed. Set by the enumerator, never by a caller: a
    /// record that could be relabelled is a label again.
    pub vantage: Vantage,
    /// HOW FAR the evidence goes. An enumeration can only ever establish
    /// `Enumerated`; reaching `Reachable` needs a stat from the work's vantage
    /// and `Placed` needs a runtime's residency report, neither of which a
    /// sysfs walk can do. Hardcoded here so no caller can inflate it.
    pub proof: Proof,
}

impl DrmRenderNode {
    /// Vendor name from the PCI id. Unknown ids are named as themselves rather
    /// than guessed — an honest "0x1234" beats a wrong "intel".
    pub fn vendor(&self) -> String {
        match self.vendor_id {
            0x10de => "nvidia".to_string(),
            0x1002 => "amd".to_string(),
            0x8086 => "intel".to_string(),
            other => format!("0x{other:04x}"),
        }
    }
}

/// Parse one hex sysfs id file body ("0x10de\n") into a u16.
///
/// Split out because it is the only fiddly part and the whole enumeration is
/// worthless if it silently yields 0 for a value it could not read.
/// Parse a sysfs PCI id (`0x1002`) into a `u16`.
///
/// PCI-ONLY, AND THE TYPE IS THE CONTRACT. A PCI vendor/device id is 16 bits by
/// the PCI spec, and the only production caller reads sysfs
/// (`/sys/class/drm/card<N>/device/{vendor,device}`), so `u16` is correct here
/// and not merely convenient. Anything wider is not a PCI id.
///
/// DO NOT REUSE THIS FOR A VULKAN `vendorID`. That is a DIFFERENT NAMESPACE:
/// `uint32_t`, Khronos-assigned, and deliberately outside the PCI range for
/// vendors that have no PCI id — lavapipe/llvmpipe reports 0x10005, which is
/// 65541 and does not fit. `u16::from_str_radix` returns None on it, the `?` at
/// the call site drops the WHOLE node, and a dropped row is indistinguishable
/// from a device that never enumerated. So the failure would not read as
/// "software rasterizer rejected"; it would read as "no such device", silently,
/// for exactly the rows 793-zumy criterion 2 exists to reject EXPLICITLY.
/// Rejecting a rasterizer and losing it must never produce the same record.
///
/// A Vulkan id therefore needs its own field (`u32`) and its own parser. Today
/// nothing captures one: the enumerator is sysfs-only and rejects
/// lavapipe/llvmpipe STRUCTURALLY, because a userspace-only ICD creates no DRM
/// render node to find. This comment exists so the next person to add Vulkan
/// enumeration does not reach for the nearest parser that compiles.
///
/// Raised by esme, corrected against this code by yolanda, settled on yoga
/// against the hwfp-v2 field set: that bump records vendor_id/device_id from
/// THIS path — sysfs PCI — so it needs no change.
pub fn parse_pci_id(body: &str) -> Option<u16> {
    let t = body.trim();
    let hex = t.strip_prefix("0x").unwrap_or(t);
    u16::from_str_radix(hex, 16).ok()
}

/// Enumerate DRM render nodes under a sysfs root. `root` is a parameter ONLY so
/// tests can point it at a fixture tree — production always passes
/// "/sys/class/drm". A test that read the real /sys would assert whatever this
/// machine happens to be, which is the vacuous-green shape yolanda caught on
/// this very packet: a test that built its own fixture, never touched
/// production, and stayed GREEN when production was reverted to a wrong value.
pub fn enumerate_render_nodes_at(root: &std::path::Path, vantage: Vantage) -> Vec<DrmRenderNode> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(root) else {
        return out;
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| n.starts_with("renderD"))
        .collect();
    names.sort();
    for name in names {
        let dev = root.join(&name).join("device");
        let vendor = std::fs::read_to_string(dev.join("vendor")).unwrap_or_default();
        let device = std::fs::read_to_string(dev.join("device")).unwrap_or_default();
        let driver = std::fs::read_link(dev.join("driver"))
            .ok()
            .and_then(|p| p.file_name().and_then(|f| f.to_str()).map(str::to_string))
            .unwrap_or_else(|| "unknown".to_string());
        // This function reads a filesystem. Whose filesystem is the caller's
        // business; what it can honestly say is "I saw this from where I ran".
        // Production passes /sys/class/drm.
        if let Some(n) = assemble_render_node(&name, &vendor, &device, &driver, vantage) {
            out.push(n);
        }
    }
    out
}

/// Build ONE [`DrmRenderNode`] from the four raw sysfs reads that identify it.
///
/// 793-zumy REMAINING 2. Extracted so the two TRANSPORTS that can reach those
/// four values — a direct `read_dir` walk on a filesystem this process can see,
/// and a `podman exec` that cats them from inside the container — share ONE
/// identity implementation. A second implementation of an identity function is
/// the bug order 805-r98w spent a day removing: two hosts briefly had two
/// hardware fingerprint functions, they disagreed on RAM source and rounding,
/// and the strings they produced were incommensurable. The same trap is one
/// copy-paste away here, so the assembly lives in one place and the transports
/// only supply bytes.
///
/// A node whose identity cannot be read is SKIPPED, not defaulted to zero: a
/// record claiming vendor 0x0000 is still a claim, and this packet is about not
/// making claims the evidence does not support.
///
/// The rung is hardcoded to [`Proof::Enumerated`] and there is no parameter for
/// it. Reading four files sees HARDWARE; it cannot see a container's device
/// list and it cannot see `size_vram`, so this is the only rung either
/// transport is entitled to claim, whichever vantage it ran from.
pub fn assemble_render_node(
    node: &str,
    vendor_body: &str,
    device_body: &str,
    driver: &str,
    vantage: Vantage,
) -> Option<DrmRenderNode> {
    let vendor_id = parse_pci_id(vendor_body)?;
    let device_id = parse_pci_id(device_body)?;
    let driver = driver.trim();
    Some(DrmRenderNode {
        node: node.to_string(),
        vendor_id,
        device_id,
        driver: if driver.is_empty() {
            "unknown".to_string()
        } else {
            driver.to_string()
        },
        vantage,
        proof: Proof::Enumerated,
    })
}

/// A stable identifier for the HARDWARE this document describes, so two hosts
/// can be SHOWN identical rather than ASSERTED identical.
///
/// 805-r98w. The cost of not having this was paid on 2026-08-31: an accelerator
/// result measured here was reported as "replicates on a THIRD SUBSTRATE" when
/// nothing could establish that this host and yoga's are the same substrate.
/// Both hosts then had to strike the framing. Two machines each describing
/// themselves and calling the pair a control is precisely what this fixes.
///
/// WHAT IS IN IT — hardware only:
///   cpu:<vendor>/<name>/<physical>c<logical>t
///   gpu:<vendor>/<name>
///   npu:<vendor>/<device_node>
///   ram:<class>
/// Devices are sorted before hashing, because enumeration order is not a
/// property of the machine and a fingerprint that changed with it would fail
/// the one job it has.
///
/// WHAT IS DELIBERATELY OUT, and this is the design rather than an omission:
///
///   * THE OS, KERNEL, AND CONTAINER RUNTIME. Those are the SUBSTRATE, and the
///     packet's whole point is a matrix keyed on (fingerprint, substrate) where
///     same-fingerprint rows isolate the substrate as the only free variable.
///     Folding the OS in would make every row unique and the control impossible.
///     This host and yoga's must fingerprint IDENTICALLY despite one running
///     Windows/WSL2 and the other bare Linux — that equality is the deliverable.
///   * `driver`, for the same reason: a driver version is substrate, not silicon.
///   * `usable` and `lanes`: those are what the matrix MEASURES. Keying on them
///     would let the answer choose the question.
///
/// RAM IS BUCKETED, not exact. Two machines with the same DIMMs report slightly
/// different `system_ram_gb` once firmware reservations differ, and an exact
/// figure would split a twin pair on a number neither user chose.
///
/// NOT A UNIQUENESS CLAIM. Two genuinely identical machines SHOULD collide —
/// that is the point. This says "same hardware", never "same host"; `host_id`
/// remains the identity key and this is deliberately not a substitute for it.
/// Why a fingerprint may not be computed from this document.
///
/// ORDER 805-r98w. Measured on native Windows 2026-09-02: the capability
/// document there carries ONE device — `cpu/unknown/Host CPU`, cores reported
/// 16c16t on an 8c/16t part — with no GPU record, no NPU record, and RAM absent
/// from both `host.ram_gb` and `system_ram_gb`. [`hardware_fingerprint`] hashed
/// that happily and returned `hw1-4714b1195f92e0c6`, which is not an identity:
/// EVERY Windows host reporting 16 logical cores produces that same string.
///
/// A comparison key that silently degrades to a constant is worse than no key,
/// because the failure it produces is a FALSE TWIN — two different machines
/// declared identical — which is the exact failure this order was filed
/// against. So the document must be refused, loudly, naming what is missing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FingerprintRefusal {
    pub missing: Vec<String>,
}

impl std::fmt::Display for FingerprintRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "capability document cannot identify this machine (missing: {}) - a fingerprint from it would collide with unrelated hosts",
            self.missing.join(", ")
        )
    }
}

/// The discriminating fields a document must carry before its hash means
/// anything. Deliberately NOT "all of them": a machine with no NPU is still
/// identifiable. The bar is that SOMETHING beyond a placeholder CPU name
/// separates this host from another.
///
/// @trace scripts/hardware-fingerprint.sh (the sibling implementation, whose
/// `compare` mode exists to REFUSE a twin claim rather than bless one)
pub fn hardware_fingerprint_checked(
    doc: &CapabilityDocument,
) -> Result<String, FingerprintRefusal> {
    let mut missing: Vec<String> = Vec::new();

    // A CPU name the probe filled in with a placeholder identifies nothing.
    //
    // ORDER 1137-rgfm — THIS ASKS THE PROBE, AND FALLS BACK TO THE DENY-LIST.
    // It used to be the deny-list alone:
    //     d.name != "Host CPU" && d.name != "unknown"
    // written from the Windows defect (805-r98w), which is the only shape a
    // deny-list can have — the placeholders someone already tripped over. It
    // therefore passed `Apple Silicon CPU`, a placeholder emitted by a
    // different arm, in a check whose entire purpose is to catch placeholders.
    // Every new platform arm can add a third, and the guard cannot know.
    //
    // `name_source` moves the question to the only party that can answer it:
    // the probe knows whether it MEASURED the name or filled one in, and
    // nothing downstream can recover that from the string. `Some("measured")`
    // is identifying; `Some("placeholder")` is refused no matter how specific
    // the string looks.
    //
    // THE DENY-LIST STAYS FOR `None`, deliberately. A document filed before
    // this field existed says nothing about provenance, and treating that
    // silence as "placeholder" would make every stored document in the fleet
    // unidentifiable the day this lands — a correctness change that reads as an
    // outage. For those rows the old test is exactly as good as it ever was.
    // The list is not extended with "Apple Silicon CPU": a macOS probe new
    // enough to emit that string is new enough to set `name_source`, so adding
    // it would only mask the field being unset.
    let cpu_named = doc.devices.iter().any(|d| {
        d.device_class == "cpu"
            && !d.name.is_empty()
            && match d.name_source.as_deref() {
                Some("measured") => true,
                Some(_) => false,
                None => d.name != "Host CPU" && d.name != "unknown",
            }
    });
    if !cpu_named {
        missing.push("cpu model name (probe emitted a placeholder)".to_string());
    }

    let has_gpu = doc.devices.iter().any(|d| d.device_class == "gpu");
    let has_npu = doc.devices.iter().any(|d| d.device_class == "npu");
    let has_ram = doc.devices.iter().any(|d| d.system_ram_gb.is_some());
    if !has_gpu && !has_npu && !has_ram {
        missing.push("every secondary discriminator (no gpu, no npu, no ram)".to_string());
    }

    if missing.is_empty() {
        Ok(hardware_fingerprint(doc))
    } else {
        Err(FingerprintRefusal { missing })
    }
}

/// The outcome of a VALID hardware comparison between two capability documents.
///
/// ORDER 805-r98w. Returned only when the comparison is legitimate; every case
/// where it is not is a [`ComparisonRefusal`], which deliberately carries NO
/// verdict. A refusal that still hands back a hardware answer is worse than
/// either alone — the caller reads the answer and discards the caveat, which is
/// exactly how a false twin gets blessed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FingerprintComparison {
    /// Same fingerprint. NOT a uniqueness claim: two genuinely identical
    /// machine models SHOULD collide, which is the whole point.
    Same(String),
    Different {
        a: String,
        b: String,
    },
}

/// Why two documents may not be compared at all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ComparisonRefusal {
    /// One or both documents cannot identify their machine.
    Unidentifiable {
        which: String,
        refusal: FingerprintRefusal,
    },
    /// The documents were produced from different VANTAGES, so their device
    /// records are not commensurable.
    ///
    /// The same machine reports its iGPU as "WSL2 paravirtual GPU (/dev/dxg)"
    /// under WSL2 — the PATH, not the silicon — and emits no GPU device at all
    /// probed natively on Windows. A difference across that boundary is not
    /// evidence of different hardware, so reporting one would be a FALSE
    /// NEGATIVE twin: the mirror of the false positive this order was filed
    /// against, and just as wrong.
    CrossVantage { a_kind: String, b_kind: String },
}

impl std::fmt::Display for ComparisonRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ComparisonRefusal::Unidentifiable { which, refusal } => {
                write!(f, "refused:unidentifiable-document ({which}): {refusal}")
            }
            ComparisonRefusal::CrossVantage { a_kind, b_kind } => write!(
                f,
                "refused:cross-vantage-comparison ({a_kind} vs {b_kind}) - the substrate changes the device records, so a difference here is not evidence of different hardware"
            ),
        }
    }
}

/// Compare two capability documents as HARDWARE, refusing when the comparison
/// would not mean what a reader takes it to mean.
///
/// This is the single implementation of the comparison rule — the shell's
/// `compare` mode calls it rather than restating it, because two copies of an
/// identity rule is the same bug the fingerprint exists to prevent, moved up a
/// layer. Adopted with yoga 2026-09-02.
///
/// Refuses, never guesses:
///   - either document unable to identify its machine (see
///     [`hardware_fingerprint_checked`]),
///   - documents from different `host.host_kind` vantages.
pub fn compare_documents(
    a: &CapabilityDocument,
    b: &CapabilityDocument,
) -> Result<FingerprintComparison, ComparisonRefusal> {
    // Vantage FIRST. A cross-vantage pair must refuse even when both documents
    // are individually fine, and checking identifiability first would let a
    // caller that only inspects the error type believe the vantage was checked.
    if a.host.host_kind != b.host.host_kind {
        return Err(ComparisonRefusal::CrossVantage {
            a_kind: a.host.host_kind.clone(),
            b_kind: b.host.host_kind.clone(),
        });
    }

    let fa =
        hardware_fingerprint_checked(a).map_err(|refusal| ComparisonRefusal::Unidentifiable {
            which: "a".to_string(),
            refusal,
        })?;
    let fb =
        hardware_fingerprint_checked(b).map_err(|refusal| ComparisonRefusal::Unidentifiable {
            which: "b".to_string(),
            refusal,
        })?;

    if fa == fb {
        Ok(FingerprintComparison::Same(fa))
    } else {
        Ok(FingerprintComparison::Different { a: fa, b: fb })
    }
}

/// The version of the FIELD SET the fingerprint is composed from — hashed into
/// the string and carried in its `hw<N>-` prefix. Bump on any change to which
/// fields are included or how they are classed.
pub const FIELD_SET_VERSION: u32 = 2;

// VERSION HISTORY, kept because the reason for the bump is the evidence that
// the mechanism works.
//
// 1 -> 2 (2026-09-02). Version 1 shipped in two INCOMPATIBLE forms and both
// called themselves `hw1-`. The commit that introduced this constant also
// folded `fieldset:N` into the hashed input, which changes the string for
// identical hardware — a field-set change by this constant's own definition —
// and did not bump the version. yoga built off the earlier commit and got
// `hw1-134b5c800683d4d2`; this host on the later one produced a different
// composition under the same tag. Two incomparable strings sharing a version is
// exactly what the constant exists to prevent, and it happened in the commit
// that created it.
//
// Bumping to 2 makes the incompatibility visible instead of silent: every
// string minted before that commit is now distinguishable at a glance. The rule
// stands and is restated here because it was broken once already — bump on ANY
// change to which fields are included, how they are classed, OR how they are
// serialised.
//
// WHY THAT MISS WAS STRUCTURAL, not careless (yoga, 2026-09-02): a version
// constant cannot guard the commit that creates it, because at that moment
// there is no previous version for anything to differ from. The FIRST use of a
// new invariant is the one occurrence the invariant cannot check. Whatever the
// next such guard is, its introducing commit is the one that needs reviewing by
// hand — the guard will cover every case but that one.

pub fn hardware_fingerprint(doc: &CapabilityDocument) -> String {
    fn ram_class(gb: f64) -> String {
        // Nearest power-of-two-ish class. 15.2 and 15.9 are both "16".
        const CLASSES: [f64; 9] = [2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0, 256.0, 512.0];
        let best = CLASSES
            .iter()
            .min_by(|a, b| {
                (*a - gb)
                    .abs()
                    .partial_cmp(&(*b - gb).abs())
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .copied()
            .unwrap_or(gb);
        format!("{best:.0}")
    }

    let mut parts: Vec<String> = Vec::new();
    let mut ram: Option<String> = None;
    for d in &doc.devices {
        match d.device_class.as_str() {
            "cpu" => {
                let cores = d
                    .cpu_cores
                    .as_ref()
                    .map(|c| format!("{}c{}t", c.physical, c.logical))
                    .unwrap_or_else(|| "?c?t".to_string());
                parts.push(format!("cpu:{}/{}/{}", d.vendor, d.name, cores));
            }
            "gpu" => parts.push(format!("gpu:{}/{}", d.vendor, d.name)),
            "npu" => parts.push(format!(
                "npu:{}/{}",
                d.vendor,
                d.device_node.as_deref().unwrap_or("-")
            )),
            _ => {}
        }
        // First device carrying a RAM figure wins; `map` keeps this flat, which
        // clippy's collapsible_if requires under the gate's -D warnings.
        if ram.is_none() {
            ram = d.system_ram_gb.map(ram_class);
        }
    }
    parts.sort();
    if let Some(r) = ram {
        parts.push(format!("ram:{r}"));
    }
    // ORDER 805-r98w, adopted from yoga 2026-09-02. The field-set version is
    // HASHED, not merely prefixed. A tag bolted on the front can be stripped,
    // ignored, or compared away by a caller that only looks at the hex; folding
    // it into the input makes a v1 and a v2 string differ EVERYWHERE, so they
    // can never be silently compared even by code that never heard of the tag.
    //
    // Bump FIELD_SET_VERSION whenever the composition of `parts` changes —
    // fields added, removed, or classed differently (the RAM rounding included).
    // That is what makes such a change safe: it becomes a visible
    // incompatibility rather than two hosts quietly disagreeing about what a
    // number means.
    parts.insert(0, format!("fieldset:{FIELD_SET_VERSION}"));
    let joined = parts.join("|");
    // cksum-grade is enough: this is a comparison key, not a security boundary,
    // and a readable prefix beats an opaque digest when a human is asking why
    // two rows did not match.
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in joined.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x1000_0000_01b3);
    }
    format!("hw{FIELD_SET_VERSION}-{h:016x}")
}

/// Upgrade a node to [`Proof::Placed`] from a runtime's reported residency.
///
/// 793-zumy REMAINING 2, second half. Takes the residency as a VALUE rather than
/// fetching it, which keeps the only rung that proves a lane decidable without a
/// network round trip and testable without a live runtime. The caller supplies
/// `resident_bytes` — in practice the sum of `size_vram` across
/// `ollama /api/ps` — and the IO stays at the caller's layer where it can be
/// mocked, timed, and refused independently.
///
/// EXACTLY-ONE-CANDIDATE OR NOTHING, and this is the load-bearing rule.
/// `/api/ps` reports residency per MODEL, never per DEVICE. On a host with one
/// candidate node the attribution is unambiguous; with two it is a guess, and a
/// guess recorded as `Placed` is precisely this packet's failure class — a label
/// standing in for the wiring it names, one rung higher and therefore worse.
/// With zero or several candidates this returns `None` and upgrades nothing.
///
/// CANDIDATES ARE `Reachable` NODES, not merely enumerated ones: a runtime
/// cannot have placed weights on a device the work's vantage cannot even stat.
/// That ordering is why the rungs are ordered.
///
/// NOT A CAPACITY CLAIM, restating the enum's own caveat because this is the
/// function that could quietly become one: non-zero residency proves weights
/// landed, not that the device does the compute (a partial offload reports
/// non-zero VRAM with most layers on CPU) and not that a larger model would fit.
///
/// Returns the node index upgraded, or `None` when nothing could be attributed.
pub fn upgrade_placed(nodes: &mut [DrmRenderNode], resident_bytes: u64) -> Option<usize> {
    if resident_bytes == 0 {
        return None;
    }
    let mut candidates = nodes
        .iter()
        .enumerate()
        .filter(|(_, n)| n.proof >= Proof::Reachable);
    let (idx, _) = candidates.next()?;
    if candidates.next().is_some() {
        // Two or more reachable nodes and a per-model residency figure: the
        // honest answer is that we cannot say WHICH one, so we say nothing.
        return None;
    }
    if nodes[idx].proof < Proof::Placed {
        nodes[idx].proof = Proof::Placed;
    }
    Some(idx)
}

/// Upgrade `Enumerated` nodes to [`Proof::Reachable`] by STATTING them from the
/// vantage the work runs in.
///
/// 793-zumy REMAINING 2, first half. The rungs were modelled but inert: nothing
/// produced anything above `Enumerated`, and an honest model that does no work
/// is only half the fix.
///
/// THE IN-TREE PRECEDENT IS `images/inference/entrypoint.sh`, which refuses a
/// cuda tier when `[ -e /dev/nvidia0 ]` fails INSIDE the container. This is that
/// check, lifted into the probe and given a rung.
///
/// CONTAINER VANTAGE ONLY, and this is the whole point rather than a
/// restriction. [`Vantage::Container`] is documented as the only vantage that
/// can speak for the container lane, so a HOST stat is not weaker evidence for
/// that lane — it is evidence about a different question. A node enumerated on
/// the host and statted on the host stays `Enumerated`; claiming otherwise
/// would be this packet's own failure class, a label standing in for the wiring
/// it names.
///
/// STILL NOT A LANE. Reachable is necessary and NOT sufficient: yoga's host sat
/// exactly here with the device statted and `size_vram` still 0. Only
/// [`Proof::Placed`] proves a lane, and nothing here produces it.
///
/// Never downgrades: a node already at a higher rung is left alone.
pub fn upgrade_reachable_at(nodes: &mut [DrmRenderNode], dev_dri_root: &std::path::Path) -> usize {
    let mut upgraded = 0;
    for n in nodes.iter_mut() {
        if n.vantage != Vantage::Container {
            continue;
        }
        if n.proof >= Proof::Reachable {
            continue;
        }
        // `exists()` follows symlinks, which is what we want: /dev/dri entries
        // are commonly symlinked and the question is whether opening the path
        // would find a device, not whether the entry is itself a node.
        if dev_dri_root.join(&n.node).exists() {
            n.proof = Proof::Reachable;
            upgraded += 1;
        }
    }
    upgraded
}

/// The shell the container-vantage producer runs INSIDE the container.
///
/// 793-zumy REMAINING 2. The in-tree precedent this packet names is
/// `images/inference/entrypoint.sh`, which refuses a cuda tier when
/// `[ -e /dev/nvidia0 ]` fails THERE rather than on the host. This is that
/// check generalised: one bounded, read-only `sh` that cats the four sysfs
/// files identifying each render node and lists `/dev/dri`, emitting a
/// line-oriented blob a pure function can parse.
///
/// WHY BOTH SECTIONS IN ONE EXEC. `/sys` is bind-mounted from the host into a
/// podman container whether or not any device was passed, so a sysfs walk run
/// inside the container still describes the HOST's silicon - it establishes
/// identity, never access. `/dev/dri` is the half that answers the container's
/// own question. Splitting them across two execs would let the two halves
/// describe different moments; taking both in one round trip is also the
/// cheaper thing to do.
///
/// It writes nothing and reads only sysfs and a device directory listing, so it
/// is safe to run against a container serving live inference.
const CONTAINER_PROOF_SH: &str = r#"
for d in /sys/class/drm/renderD*; do
  [ -d "$d/device" ] || continue
  n=${d##*/}
  v=$(cat "$d/device/vendor" 2>/dev/null)
  p=$(cat "$d/device/device" 2>/dev/null)
  dr=$(readlink "$d/device/driver" 2>/dev/null)
  dr=${dr##*/}
  printf 'DRM\t%s\t%s\t%s\t%s\n' "$n" "$v" "$p" "${dr:-unknown}"
done
for e in /dev/dri/*; do
  [ -e "$e" ] || continue
  printf 'DEV\t%s\n' "${e##*/}"
done
"#;

/// Parse [`CONTAINER_PROOF_SH`]'s output into `(render nodes, /dev/dri entries)`.
///
/// Pure, so the whole container-vantage path is testable without podman, a
/// container, or a GPU - which matters because the hosts that must REVIEW this
/// code (a Windows host whose probe runs natively, a macOS host) can never run
/// it. Identity assembly is delegated to [`assemble_render_node`]: this
/// function transports bytes and does not decide what a render node is.
///
/// Unparseable and short lines are SKIPPED rather than defaulted. A blob that
/// arrived truncated must yield fewer nodes, never a node with invented fields.
pub fn parse_container_proof_output(
    text: &str,
    vantage: Vantage,
) -> (Vec<DrmRenderNode>, Vec<String>) {
    let mut nodes = Vec::new();
    let mut dev_entries = Vec::new();
    for line in text.lines() {
        let f: Vec<&str> = line.trim_end().split('\t').collect();
        match f.first().copied() {
            Some("DRM") if f.len() == 5 => {
                if let Some(n) = assemble_render_node(f[1], f[2], f[3], f[4], vantage) {
                    nodes.push(n);
                }
            }
            Some("DEV") if f.len() == 2 && !f[1].is_empty() => {
                dev_entries.push(f[1].to_string());
            }
            _ => {}
        }
    }
    nodes.sort_by(|a, b| a.node.cmp(&b.node));
    (nodes, dev_entries)
}

/// Upgrade `Enumerated` nodes to [`Proof::Reachable`] from a LISTING of the
/// device directory as seen from the work's vantage.
///
/// 793-zumy REMAINING 2, first half, for the vantage that cannot be reached by
/// [`upgrade_reachable_at`]: the container's `/dev/dri` is not a path this
/// process can stat, so the stat happens over there and this consumes its
/// result. The RULES are identical - container vantage only, never downgrades,
/// no rung claimed for a node the listing does not name.
///
/// A HOST-VANTAGE NODE IS SKIPPED even if the listing names it, exactly as in
/// the filesystem sibling. A host stat is not weaker evidence for the container
/// lane; it is evidence about a different question, and blurring the two is
/// this packet's own failure class.
///
/// STILL NOT A LANE. Reachable is necessary and not sufficient: yoga's host sat
/// exactly here, with `/dev/kfd` and `/dev/dri/renderD128` both stat-able
/// inside the container and `size_vram` still 0.00GB because the image shipped
/// no runtime that could drive them.
pub fn upgrade_reachable_from_listing(nodes: &mut [DrmRenderNode], listing: &[String]) -> usize {
    let mut upgraded = 0;
    for n in nodes.iter_mut() {
        if n.vantage != Vantage::Container {
            continue;
        }
        if n.proof >= Proof::Reachable {
            continue;
        }
        if listing.iter().any(|e| e == &n.node) {
            n.proof = Proof::Reachable;
            upgraded += 1;
        }
    }
    upgraded
}

/// Total bytes a runtime reports RESIDENT on an accelerator, from one
/// `ollama /api/ps` body.
///
/// 793-zumy REMAINING 2, second half. [`upgrade_placed`] deliberately takes the
/// figure as a value rather than fetching it; this is the parser that turns a
/// response into that value, kept pure for the same reason.
///
/// `None` MEANS UNKNOWN AND MUST NOT COLLAPSE INTO ZERO. A body that does not
/// parse, or that carries no `models` array, is a runtime we could not ask -
/// which is a different fact from a runtime that answered "nothing is
/// resident", and [`upgrade_placed`] treats zero as a definite refusal.
/// Reporting unknown as zero would be an affirmative denial derived from a
/// failed question, the same shape as the `accel_npu=none` this family already
/// corrected.
///
/// A model row missing `size_vram` contributes 0 rather than poisoning the sum:
/// ollama omits the key for a CPU-resident model, and that genuinely is no
/// accelerator residency.
pub fn parse_ollama_resident_bytes(body: &str) -> Option<u64> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    let models = v.get("models")?.as_array()?;
    let mut total: u64 = 0;
    for m in models {
        total = total.saturating_add(m.get("size_vram").and_then(|b| b.as_u64()).unwrap_or(0));
    }
    Some(total)
}

/// PRODUCE the container lane's proof rungs, with both IO edges injected.
///
/// 793-zumy REMAINING 2, the composition the packet was actually asking for:
/// the rungs were modelled, pinned and inert, because NOTHING CALLED the
/// upgraders outside their own tests. An honest model that does no work is only
/// half the fix. This is the caller.
///
/// `probe` runs [`CONTAINER_PROOF_SH`] inside the container; `residency`
/// fetches `/api/ps` from the runtime in it. Both return `None` when they could
/// not ask. Injected rather than called directly so the composition - which is
/// where the rung ordering actually gets enforced - is testable without podman,
/// a container, a GPU, or a network, on every host in the fleet.
///
/// THE ORDERING IS THE POINT AND IT IS ENFORCED HERE, not documented here:
/// residency is applied only to nodes that reached `Reachable`, and
/// [`upgrade_placed`] refuses when the attribution is ambiguous. A `Placed` this
/// function emits therefore rests on a device the container could stat AND a
/// runtime that reported weights on exactly one candidate.
///
/// An unreachable container yields an EMPTY vec, never a fabricated row: no
/// evidence is not evidence of absence.
pub fn produce_container_proofs_with<P, R>(mut probe: P, mut residency: R) -> Vec<DrmRenderNode>
where
    P: FnMut() -> Option<String>,
    R: FnMut() -> Option<String>,
{
    let Some(blob) = probe() else {
        return Vec::new();
    };
    let (mut nodes, dev_entries) = parse_container_proof_output(&blob, Vantage::Container);
    upgrade_reachable_from_listing(&mut nodes, &dev_entries);
    // Asked ONLY when something could actually carry a placement. With no
    // reachable node the answer cannot change any rung, and this keeps a probe
    // on a CPU-only host from making a round trip to learn nothing.
    if nodes.iter().any(|n| n.proof >= Proof::Reachable)
        && let Some(bytes) = residency().as_deref().and_then(parse_ollama_resident_bytes)
    {
        upgrade_placed(&mut nodes, bytes);
    }
    nodes
}

/// The podman containers the fleet's ollama can run in, most-specific first.
///
/// CORRECTED 2026-09-02, MEASURED BY YOGA, and the correction is the point.
/// This was a single hardcoded `"tillandsias-inference"` while
/// `scripts/dev-inference-ensure.sh` creates `tillandsias-dev-inference`
/// on every dev host. So the producer execed into a container that does not
/// exist there, got nothing, and reported the bottom of the scale on a machine
/// where the lane demonstrably works — devices passed, `/api/ps` answering from
/// inside the container that IS running.
///
/// That is the sixth instance this cycle of one name fixed in one place: the
/// plan-binary probe, the hardware fingerprint, this probe's own two
/// transports, the Windows purge clear, the embed endpoint, and now this. The
/// remedy is the same one: not a second hardcoded name beside the first, which
/// is how these drift, but ONE resolution with the environment as the single
/// source when a caller knows better.
///
/// `TILLANDSIAS_INFERENCE_CONTAINER` is that hook: the lane that CREATES the
/// container can name it, and then there is one source rather than a list this
/// file has to keep in sync with a shell script.
/// KEPT IN SYNC BY A GUARD, not by care:
/// `scripts/check-inference-container-name-agreement.sh` (967-6ax6) fails the
/// build if the name `dev-inference-ensure.sh` CREATES is absent from this
/// list. The env hook below is the real single source, but it only reaches
/// processes that script spawned — a probe run from the tray or a cron falls
/// back to this list, so the two literals still have to agree.
const INFERENCE_CONTAINER_CANDIDATES: [&str; 2] =
    ["tillandsias-inference", "tillandsias-dev-inference"];

/// Which inference container is actually present, or `None` when there is none
/// to ask.
///
/// `None` IS THE LOAD-BEARING RETURN. It is the difference between "we asked
/// the container lane and it has nothing" and "there was no container lane to
/// ask", and yoga's measurement is what proved those must not share a token: on
/// their host the envelope read `accel_proof=-` — identical to a machine with
/// no accelerator at all — while the lane was working. The failure was silent
/// and it under-claimed, which is the direction this file already warns is the
/// one that gets missed, because the wasted work it causes looks like
/// diligence.
fn resolve_inference_container() -> Option<String> {
    let exists = |name: &str| -> bool {
        tillandsias_podman::podman_cmd_sync()
            .args(["container", "exists", name])
            .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget())
            .ok()
            .map(|o| o.status.success())
            .unwrap_or(false)
    };
    if let Some(name) = inference_container_override(
        std::env::var("TILLANDSIAS_INFERENCE_CONTAINER")
            .ok()
            .as_deref(),
    ) {
        return Some(name);
    }
    INFERENCE_CONTAINER_CANDIDATES
        .iter()
        .find(|n| exists(n))
        .map(|n| n.to_string())
}

/// The override half of [`resolve_inference_container`], split out so it can be
/// tested without a podman on the host.
///
/// An EXPLICIT name is the caller NAMING the container, not a candidate to be
/// judged — the same rule `plan-binary-probe.sh` applies to
/// `TILLANDSIAS_PLAN_BIN`, and for the same reason: probing an override
/// collapses "you named the wrong one" into "there is none", which is the
/// distinction 967-6ax6 exists to preserve.
///
/// Blank is NOT an override. An exported-but-empty variable is the shape a
/// shell produces from an unset expansion (`export X="${X:-}"`), and treating
/// it as a name would make the probe exec into `""` and report nothing found —
/// reintroducing the silent under-claim through the very hook added to fix it.
fn inference_container_override(raw: Option<&str>) -> Option<String> {
    let name = raw?.trim();
    (!name.is_empty()).then(|| name.to_string())
}

/// Run one bounded, read-only command inside the resolved inference container.
///
/// Never `--tty` and never attaching stdin: an exec that attaches stdin can
/// wedge a one-shot launch forever absorbing SIGTERM, which `main.rs`'s
/// readiness probe already learned. Any non-success exit reads as "could not
/// ask" - `None`, not an empty answer.
fn inference_container_exec(container: &str, args: &[&str]) -> Option<String> {
    let mut cmd = tillandsias_podman::podman_cmd_sync();
    cmd.args(["exec", container]);
    cmd.args(args);
    let out = cmd
        .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget())
        .ok()
        .filter(|o| o.status.success())?;
    Some(String::from_utf8_lossy(&out.stdout).to_string())
}

/// PRODUCTION entry point for the container lane's proof rungs.
///
/// 793-zumy REMAINING 2. Wires [`produce_container_proofs_with`] to the two real
/// IO edges: `podman exec ... sh -c CONTAINER_PROOF_SH` for identity and
/// reachability, and `podman exec ... curl /api/ps` for residency. `127.0.0.1`
/// deliberately - inside the inference container the runtime is local whatever
/// the enclave's DNS is doing, which is the same reason `main.rs`'s readiness
/// probe uses it.
///
/// DO NOT USE `podman inspect ... HostConfig.Devices` AS THE REACHABILITY CHECK.
/// Measured by yoga 2026-09-02 on gfx1152: that field prints `[]` for a
/// container whose `/dev/kfd` and `/dev/dri/*` nodes ARE present inside. It is a
/// label that reads as evidence the wiring happened, which is this packet's
/// entire failure class arriving from the tooling instead of from us. Exec and
/// list the nodes.
///
/// THE DIRECTION MATTERS: it is a FALSE NEGATIVE. The field reads `[]` on a host
/// where the devices WERE passed, so a verifier trusting it concludes "no
/// devices passed" and goes off re-fixing a passthrough that already works -
/// which is what 937-68n4 landed. This family's other four instances all failed
/// the other way, toward an over-claim; this one is worth naming separately
/// because the wasted work it causes looks like diligence.
pub fn probe_container_render_nodes() -> ContainerLaneProbe {
    let Some(container) = resolve_inference_container() else {
        return ContainerLaneProbe {
            nodes: Vec::new(),
            asked: None,
        };
    };
    let nodes = produce_container_proofs_with(
        || inference_container_exec(&container, &["sh", "-c", CONTAINER_PROOF_SH]),
        || {
            inference_container_exec(
                &container,
                &[
                    "curl",
                    "-fsS",
                    "--max-time",
                    "2",
                    "http://127.0.0.1:11434/api/ps",
                ],
            )
        },
    );
    ContainerLaneProbe {
        nodes,
        asked: Some(container),
    }
}

/// What the container-lane probe found AND whether there was anything to ask.
///
/// The second field exists because an empty `nodes` means two different things
/// and the envelope must not render them the same. See
/// [`resolve_inference_container`] for the measurement that forced the split.
pub struct ContainerLaneProbe {
    pub nodes: Vec<DrmRenderNode>,
    /// The container actually probed, or `None` when none was present.
    pub asked: Option<String>,
}

/// Does ONE spec body name the NVIDIA kind AND a usable device node?
///
/// Split out so it is testable without the filesystem: a spec that names the
/// kind but no `/dev/nvidiaN` node cannot deliver a GPU, and neither can one
/// whose node sits under a self-referential `/run/host` prefix — that lands at
/// the wrong in-container path, which is exactly the spec a bad `--dev-root`
/// produced on this host.
#[cfg(target_os = "linux")]
fn spec_body_delivers_nvidia(body: &str) -> bool {
    body.contains("nvidia.com/gpu") && body.contains("/dev/nvidia") && !body.contains("/run/host")
}

#[cfg(target_os = "linux")]
fn spec_file_delivers_nvidia(path: &std::path::Path) -> bool {
    std::fs::read_to_string(path)
        .map(|b| spec_body_delivers_nvidia(&b))
        .unwrap_or(false)
}

#[cfg(target_os = "linux")]
fn nvidia_cdi_deliverable() -> bool {
    // podman's own default search path, plus the user dir a rootless immutable
    // host must use (podman does not search it unless containers.conf declares
    // it — the correction recorded on 665-zddn).
    let mut dirs: Vec<std::path::PathBuf> = vec![
        std::path::PathBuf::from("/etc/cdi"),
        std::path::PathBuf::from("/var/run/cdi"),
    ];
    if let Ok(home) = std::env::var("HOME") {
        dirs.push(std::path::Path::new(&home).join(".config/cdi"));
    }

    for dir in dirs {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("yaml") {
                continue;
            }
            if spec_file_delivers_nvidia(&path) {
                return true;
            }
        }
    }
    false
}

/// ORDER 935-jhh5: `effective_tier` USED TO BE A PARAMETER HERE and is gone on
/// purpose. Its only consumer was `cdi_ok = effective_tier == "gpu-cuda"`, and
/// that tier is itself derived from the same `nvidia-smi` this function already
/// runs — so the parameter was the circularity, carried in by signature. The
/// compiler flagging it unused the moment the real check landed is the proof
/// that the dependency is severed rather than merely rerouted.
/// The sysfs facts the memory-model classifier decides on (order 964-r98h).
///
/// A struct rather than three parameters so the classifier is a pure function
/// over EVIDENCE, testable without the hardware that produced it — every case
/// below is a real machine somebody has, and only one of them is this one.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
// @trace order:964-r98h, spec:accel-capability-probe
pub struct GpuMemoryEvidence {
    /// `mem_info_vram_total` — amdgpu only; absent for every other driver.
    pub vram_total: Option<u64>,
    /// `mem_info_vis_vram_total` — the CPU-VISIBLE part of the above.
    pub vis_vram_total: Option<u64>,
    /// The largest prefetchable PCI BAR: the device's memory aperture.
    pub largest_prefetchable_bar: Option<u64>,
}

/// A dedicated memory aperture at or above this size cannot be a window onto
/// system RAM — nothing carves a gigabyte-scale prefetchable BAR for an
/// integrated part. Measured on this host: the discrete RTX 3070 exposes an
/// 8192 MiB prefetchable BAR (resizable BAR enabled) and the integrated Vega
/// exposes 256 MiB.
const DISCRETE_BAR_FLOOR_BYTES: u64 = 1024 * 1024 * 1024;

/// Decide a device's memory model from sysfs evidence, or refuse.
///
/// READ THE FIRST RUNG BEFORE ANYTHING ELSE, BECAUSE THIS HOST FALSIFIED THE
/// OBVIOUS RULE — including the one I wrote into 964-r98h's own context, which
/// proposed that `mem_info_vram_total` "is absent or zero for an integrated
/// part". Measured here, it is exactly backwards:
///
///     card0  NVIDIA RTX 3070 (DISCRETE)    no mem_info_vram_total at all
///     card1  AMD Vega iGPU  (INTEGRATED)   mem_info_vram_total = 2 GiB
///
/// The file belongs to `amdgpu`, not to dedicated memory: the proprietary
/// NVIDIA driver does not export it, and an APU DOES, because its BIOS carves a
/// UMA region out of system RAM and amdgpu reports that carve-out as VRAM. A
/// classifier built on "has a VRAM total => discrete" would have labelled both
/// devices on this machine wrongly, in opposite directions, and passed review.
///
/// THE RUNGS, each sound on its own and tried in order:
///
/// 1. `vis_vram < vram` => DISCRETE. Part of the device's memory is not
///    CPU-visible, so there is memory behind an aperture — which only exists
///    when the memory is the device's own. This is the pre-resizable-BAR
///    signature (a 256 MiB window onto 8 GiB of VRAM) and it is decisive.
///
/// 2. A prefetchable BAR >= 1 GiB => DISCRETE. The resizable-BAR case, where
///    rung 1 goes quiet because the whole of VRAM became CPU-visible.
///
///    THIS RUNG DEPENDS ON FIRMWARE, NOT ON SILICON, and the distinction was
///    yolanda's (2026-09-03) after I had already written "this is how the 3070
///    is classified" as though it were a fact about the card. Resizable BAR is
///    firmware and driver state: with it ON, a discrete card exposes its whole
///    VRAM as one large aperture and this rung fires; with it OFF — still the
///    default on plenty of boards, and the historical PCIe behaviour — the same
///    card exposes the legacy 256 MiB aperture and this rung does not.
///
///    MEASURED HERE, and it confirms their model rather than mine:
///    `lspci -vv -s 01:00.0` reports `Region 1: 64-bit, prefetchable [size=8G]`
///    on this RTX 3070, so ReBAR is enabled on this host. What the discrete arm
///    has been demonstrated against is therefore ONE FIRMWARE CONFIGURATION of
///    one card, not the card.
///
///    The same 3070 with ReBAR disabled exports no `mem_info_vram_total`
///    (rungs 1 and 3 need one) and has no aperture at or above the floor
///    (rung 2), so it reaches NO rung and lands on `undetermined`. That is the
///    ladder failing SAFE — the mislabel would have been `unified` — and it is
///    pinned by `a_non_rebar_discrete_card_lands_on_undetermined_not_unified`
///    rather than left as a property someone has to notice.
///
/// 3. `vram` known, fully CPU-visible, and NO large aperture => UNIFIED. All of
///    the device's memory is reachable through a small window, which is what a
///    UMA carve-out looks like and what dedicated VRAM never looks like. This
///    is the weakest rung and its limit is stated rather than hidden: a
///    hypothetical discrete board with under a gigabyte of VRAM and no
///    resizable BAR would land here wrongly. No such part is in this fleet, and
///    the rung is guarded by requiring the amdgpu VRAM figure to be present at
///    all — a driver that reports no VRAM never reaches it.
///
/// 4. Otherwise `None`. NOT a vendor lookup. A vendor table would answer for
///    the NVIDIA card above without evidence, and 964-r98h exists precisely
///    because `unified` is wrong for a discrete Radeon and `discrete` is wrong
///    for every iGPU in the fleet — a guess that is right about most hosts is
///    the confident half-answer this packet family keeps removing.
// @trace order:964-r98h, spec:accel-capability-probe
pub fn memory_model_from_evidence(e: &GpuMemoryEvidence) -> Option<&'static str> {
    if let (Some(vram), Some(vis)) = (e.vram_total, e.vis_vram_total)
        && vram > 0
        && vis < vram
    {
        return Some("discrete");
    }
    if e.largest_prefetchable_bar
        .is_some_and(|b| b >= DISCRETE_BAR_FLOOR_BYTES)
    {
        return Some("discrete");
    }
    if let (Some(vram), Some(vis), Some(bar)) =
        (e.vram_total, e.vis_vram_total, e.largest_prefetchable_bar)
        && vram > 0
        && vis >= vram
        && bar < DISCRETE_BAR_FLOOR_BYTES
    {
        return Some("unified");
    }
    None
}

/// Read the evidence for one PCI device from sysfs (order 964-r98h).
///
/// Everything here is best-effort: a missing or unreadable file is `None`, not
/// a zero. Zero is a claim about the hardware and absence is a claim about the
/// probe, and collapsing them is the failure this whole packet family is about.
#[cfg(target_os = "linux")]
// @trace order:964-r98h, spec:accel-capability-probe
fn read_gpu_memory_evidence(pci_addr: &str) -> GpuMemoryEvidence {
    let dev = PathBuf::from("/sys/bus/pci/devices").join(pci_addr);
    let read_u64 = |name: &str| -> Option<u64> {
        fs::read_to_string(dev.join(name))
            .ok()
            .and_then(|s| s.trim().parse::<u64>().ok())
    };
    GpuMemoryEvidence {
        vram_total: read_u64("mem_info_vram_total"),
        vis_vram_total: read_u64("mem_info_vis_vram_total"),
        largest_prefetchable_bar: fs::read_to_string(dev.join("resource"))
            .ok()
            .map(|s| largest_prefetchable_bar(&s)),
    }
}

/// The largest prefetchable BAR in a sysfs `resource` file, in bytes.
///
/// Each line is `<start> <end> <flags>` in hex. A zero-sized BAR reads
/// `0x0 0x0 0x0`, and PREFETCHABLE (bit 3 of the flags) is what distinguishes a
/// memory aperture from an MMIO register window — the RTX 3070's 16 MiB
/// register BAR is not evidence of anything, and counting it would put every
/// GPU over a megabyte-scale floor.
///
/// A pure function over the file's TEXT so the parser is testable without a
/// PCI device, which matters more than usual here: this is the one place a
/// silent misparse would produce a confident wrong classification rather than
/// an honest `None`.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
// @trace order:964-r98h, spec:accel-capability-probe
fn largest_prefetchable_bar(resource_file: &str) -> u64 {
    const PCI_PREFETCHABLE: u64 = 0x8;
    let hex = |t: &str| u64::from_str_radix(t.trim_start_matches("0x"), 16).ok();
    resource_file
        .lines()
        .filter_map(|line| {
            let mut f = line.split_whitespace();
            let (start, end, flags) = (hex(f.next()?)?, hex(f.next()?)?, hex(f.next()?)?);
            if end <= start || flags & PCI_PREFETCHABLE == 0 {
                return None;
            }
            Some(end - start + 1)
        })
        .max()
        .unwrap_or(0)
}

fn enumerate_gpus() -> Vec<DeviceRecord> {
    let mut gpus = Vec::new();

    // The tier no longer reaches this function at all (order 935-jhh5). It used
    // to be a parameter whose ONLY consumer was the Linux arm's
    // `cdi_ok = effective_tier == "gpu-cuda"` — a check derived from the same
    // `nvidia-smi` that arm already runs. With that circularity removed the
    // parameter went too, and this `let _ = effective_tier;` — the
    // non-Linux fallback that existed purely to silence the resulting
    // unused-parameter warning — went with it. The cross-target gate (656-spux)
    // caught it: it compiles on the host either way, and only the Windows
    // target proved the line was now referencing something that no longer
    // exists. The macOS arm is host-native only by spec (PROBE-7).

    #[cfg(target_os = "macos")]
    {
        // PROBE-7: macOS Metal is host-native ONLY, container MUST NOT appear
        gpus.push(DeviceRecord {
            device_class: "gpu".to_string(),
            vendor: "apple".to_string(),
            name: "Apple Metal GPU".to_string(),
            device_node: None,
            fw_version: None,
            driver: None,
            usable: true,
            // ORDER 803-rbqf: A DEVICE EXCLUDED BY LANE MUST NAME THE
            // OBSTRUCTION. This record dropped the `container` lane silently,
            // so a consumer reading it saw a device that simply was not offered
            // there and had no way to learn why. The AMD arm already set the
            // precedent with `container-lane-unverified`: the field carries the
            // reason for a LANE restriction, not only for `usable: false`.
            //
            // The obstruction here is structural rather than unverified, and
            // that is worth stating in the string. The container on a macOS
            // host runs inside the linux-aarch64 VZ guest, and Metal does not
            // cross that boundary — there is no passthrough to enable and no
            // launcher flag that would change the answer.
            unusable_reason: Some("metal-not-reachable-from-linux-aarch64-guest".to_string()),
            policy_unscheduled: None,
            lanes: vec!["host-native".to_string()],
            memory_bandwidth_gbps: None,
            memory_bandwidth_source: "unknown".to_string(),
            cpu_flags: None,
            cpu_cores: None,
            // ORDER 803-r8u4 / 803-rbqf. Apple silicon has ONE memory budget.
            // `memory_model: None` meant "the classifier could not decide", and
            // a consumer must decline to sum on `None` exactly as on `unified` —
            // so the routing behaviour happened to be right while the recorded
            // fact was missing. 793-qr4t's unified-memory criterion is
            // "demonstrable on Apple silicon and nowhere else", and it was not
            // demonstrable here, because the one platform that can show it
            // filed no evidence.
            //
            // This is the only arm in this function that may assert `unified`
            // from the platform rather than from device evidence, and it is not
            // the `cfg`-derived-capability mistake 1090-8nh4 removed: that arm
            // claimed a RUNTIME accelerator tier from a COMPILE-TIME fact, and
            // was compiled out in the guest where the answer mattered. This code
            // only ever executes on a real macOS host, and "Apple silicon shares
            // DRAM between CPU and GPU" is an architectural invariant of every
            // machine that can run it, not a measurement standing in for one.
            system_ram_gb: macos_system_ram_gb(),
            memory_model: Some("unified".to_string()),
            // ORDER 1137-rgfm. "Apple Metal GPU" is a FAMILY literal, identical
            // on every Apple silicon Mac, so the fingerprint's
            // `gpu:{vendor}/{name}` component discriminates nothing. Naming a
            // real Metal device needs a framework call rather than a sysctl and
            // is NOT done here; what is done is refusing to let the literal
            // pass as measured. The honest label is the one the deny-list could
            // never apply to a name nobody had seen before.
            name_source: Some("placeholder".to_string()),
        });
    }

    #[cfg(target_os = "linux")]
    {
        let nvidia_present = Command::new("nvidia-smi")
            .arg("-L")
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| !s.is_empty());

        if let Some(nvidia_output) = nvidia_present {
            let cdi_ok = nvidia_cdi_deliverable();
            let lanes = if cdi_ok {
                vec!["container".to_string(), "host-native".to_string()]
            } else {
                vec!["host-native".to_string()]
            };
            let unusable_reason = if cdi_ok {
                None
            } else {
                Some("cdi-spec-missing".to_string())
            };
            let first_line = nvidia_output.lines().next().unwrap_or("NVIDIA GPU");
            // Order 964-r98h. This arm is built from `nvidia-smi`, which knows
            // the card but not its sysfs path, so the memory evidence is
            // fetched via the DRM enumeration's PCI address for the same
            // silicon. Deliberately NOT a vendor shortcut: `0x10de` would give
            // the answer for free and would be a guess, and this host is the
            // one that shows why that matters — the NVIDIA card exports no
            // `mem_info_vram_total` at all, so it is classified from its 8 GiB
            // prefetchable BAR, which is evidence, or it is not classified.
            let nvidia_memory_model = drm_cards()
                .into_iter()
                .find(|(_, vendor_id, _)| vendor_id == "0x10de")
                .and_then(|(pci_addr, _, _)| {
                    memory_model_from_evidence(&read_gpu_memory_evidence(&pci_addr))
                })
                .map(|m| m.to_string());
            gpus.push(DeviceRecord {
                device_class: "gpu".to_string(),
                vendor: "nvidia".to_string(),
                name: nvidia_model_name(first_line),
                // Read from nvidia-smi's own line (1137-rgfm: the probe says
                // whether it measured the name; the deny-list cannot).
                name_source: Some("measured".to_string()),
                device_node: Some("/dev/nvidia0".to_string()),
                fw_version: None,
                driver: None,
                usable: true,
                unusable_reason,
                policy_unscheduled: None,
                lanes,
                memory_bandwidth_gbps: None,
                memory_bandwidth_source: "unknown".to_string(),
                cpu_flags: None,
                cpu_cores: None,
                system_ram_gb: None,
                memory_model: nvidia_memory_model,
            });
        }

        // Order 850-bif2: enumerate DRM cards by PCI identity. The old arm
        // fired only when NO GPU had been found yet — an AMD iGPU beside an
        // NVIDIA dGPU was invisible to the matrix — and hardcoded vendor
        // "amd" for whatever it hit. /sys/class/drm/card*/device carries the
        // real vendor id and driver, so nothing here substring-matches prose
        // (the comp-ATI-ble trap; see scripts/derive-host-identity.sh).
        let rocm_gfx = rocm_gfx_present();
        let kfd = Path::new("/dev/kfd").exists();
        let intel_rt = intel_compute_runtime_present();
        for (pci_addr, vendor_id, driver) in drm_cards() {
            let render_node = drm_render_node_for(&pci_addr);
            match (vendor_id.as_str(), driver.as_deref()) {
                // The nvidia-smi arm above owns NVIDIA cards; re-reporting
                // them here would double-count the same silicon.
                ("0x10de", _) => continue,
                ("0x1002", Some("amdgpu")) => {
                    let (usable, lanes, unusable_reason) =
                        amd_gpu_disposition(rocm_gfx, kfd, render_node.is_some());
                    // ORDER 1011-zp59. Computed BEFORE the record is built so
                    // the memory model is read once and used for both the
                    // `memory_model` field and the integrated/discrete test.
                    let this_mm = memory_model_from_evidence(&read_gpu_memory_evidence(&pci_addr))
                        .map(|m| m.to_string());
                    // "Discrete AND schedulable" is read off the records the
                    // NVIDIA arm already pushed — usable, with at least one
                    // lane. A present-but-unusable discrete card deprioritises
                    // nothing.
                    let policy_unscheduled = igpu_policy_unscheduled_reason(
                        this_mm.as_deref() == Some("unified"),
                        discrete_gpu_is_schedulable(&gpus),
                    );
                    let lspci_name = pci_device_name_via_lspci(&pci_addr);
                    gpus.push(DeviceRecord {
                        device_class: "gpu".to_string(),
                        vendor: "amd".to_string(),
                        name: lspci_name
                            .clone()
                            .unwrap_or_else(|| "AMD GPU (amdgpu)".to_string()),
                        // 1137-rgfm: lspci answered -> measured; the fallback
                        // string is a placeholder and must say so.
                        name_source: Some(
                            (if lspci_name.is_some() {
                                "measured"
                            } else {
                                "placeholder"
                            })
                            .to_string(),
                        ),
                        device_node: render_node,
                        fw_version: None,
                        driver: Some("amdgpu".to_string()),
                        usable,
                        unusable_reason,
                        policy_unscheduled,
                        lanes,
                        memory_bandwidth_gbps: None,
                        memory_bandwidth_source: "unknown".to_string(),
                        cpu_flags: None,
                        cpu_cores: None,
                        system_ram_gb: None,
                        memory_model: this_mm,
                    });
                }
                // Order 855-wrr3: Intel now has a disposition of its own
                // instead of falling to the last-resort `usable: true` arm.
                ("0x8086", Some("i915")) | ("0x8086", Some("xe")) => {
                    let (usable, lanes, unusable_reason) =
                        intel_gpu_disposition(intel_rt, render_node.is_some());
                    let lspci_name = pci_device_name_via_lspci(&pci_addr);
                    gpus.push(DeviceRecord {
                        device_class: "gpu".to_string(),
                        vendor: "intel".to_string(),
                        name: lspci_name
                            .clone()
                            .unwrap_or_else(|| "Intel GPU".to_string()),
                        // 1137-rgfm: lspci answered -> measured; the fallback
                        // string is a placeholder and must say so.
                        name_source: Some(
                            (if lspci_name.is_some() {
                                "measured"
                            } else {
                                "placeholder"
                            })
                            .to_string(),
                        ),
                        device_node: render_node,
                        fw_version: None,
                        driver,
                        usable,
                        unusable_reason,
                        policy_unscheduled: None,
                        lanes,
                        memory_bandwidth_gbps: None,
                        memory_bandwidth_source: "unknown".to_string(),
                        cpu_flags: None,
                        cpu_cores: None,
                        system_ram_gb: None,
                        memory_model: memory_model_from_evidence(&read_gpu_memory_evidence(
                            &pci_addr,
                        ))
                        .map(|m| m.to_string()),
                    });
                }
                // Any other vendor keeps the old last-resort shape — but only
                // when nothing else was found, and with the REAL vendor
                // instead of the old hardcoded "amd".
                (vid, _) if gpus.is_empty() => {
                    let lspci_name = pci_device_name_via_lspci(&pci_addr);
                    gpus.push(DeviceRecord {
                        device_class: "gpu".to_string(),
                        vendor: match vid {
                            "0x8086" => "intel".to_string(),
                            "0x1002" => "amd".to_string(),
                            _ => "unknown".to_string(),
                        },
                        name: lspci_name
                            .clone()
                            .unwrap_or_else(|| "Vulkan GPU".to_string()),
                        // 1137-rgfm: lspci answered -> measured; the fallback
                        // string is a placeholder and must say so.
                        name_source: Some(
                            (if lspci_name.is_some() {
                                "measured"
                            } else {
                                "placeholder"
                            })
                            .to_string(),
                        ),
                        device_node: render_node
                            .or_else(|| Some(format!("/sys/bus/pci/devices/{pci_addr}"))),
                        fw_version: None,
                        driver,
                        usable: true,
                        unusable_reason: None,
                        policy_unscheduled: None,
                        lanes: vec!["container".to_string(), "host-native".to_string()],
                        memory_bandwidth_gbps: None,
                        memory_bandwidth_source: "unknown".to_string(),
                        cpu_flags: None,
                        cpu_cores: None,
                        system_ram_gb: None,
                        memory_model: memory_model_from_evidence(&read_gpu_memory_evidence(
                            &pci_addr,
                        ))
                        .map(|m| m.to_string()),
                    });
                }
                _ => {}
            }
        }

        if wsl2_paravirtual_gpu(
            Path::new("/dev/dxg").exists(),
            Path::new("/dev/dri").exists(),
            !gpus.is_empty(),
        ) {
            // ORDER 793-zumy, criterion 2's enumeration half. Everything below
            // that reads `verdict` used to be a constant: `usable: false`, a
            // placeholder name, no lane, and a reason derived from the
            // filesystem. On a host where the loader answers, the answer now
            // comes from the loader.
            let verdict = wsl2_paravirtual_gpu_verdict();
            let enumerated_name = match &verdict {
                Wsl2VulkanVerdict::Usable { name } => Some(name.clone()),
                Wsl2VulkanVerdict::Unusable { .. } => None,
            };
            gpus.push(DeviceRecord {
                device_class: "gpu".to_string(),
                // /dev/dxg is vendor-AGNOSTIC: Intel, AMD and NVIDIA all present
                // through it under WSL2 (measured on two Windows hosts, an Intel
                // UHD and an AMD Radeon 860M). Naming a vendor here would be a
                // guess, and a wrong vendor in the fleet matrix is worse than an
                // honest "unknown".
                vendor: "unknown".to_string(),
                // ORDER 793-zumy: the placeholder is now the FALLBACK, not the
                // only answer. When a device enumerated, its own
                // `VkPhysicalDeviceProperties::deviceName` is the name and the
                // source says `enumerated` — "Microsoft Direct3D12 (Intel(R)
                // UHD Graphics)" on esmeraldinha — because a name the loader
                // handed back is not a placeholder and must not be declared as
                // one (1137-rgfm cuts both ways).
                name: enumerated_name
                    .clone()
                    .unwrap_or_else(|| "WSL2 paravirtual GPU (/dev/dxg)".to_string()),
                // Every WSL2 host that could not enumerate emits this same
                // string: it identifies the substrate, not the card
                // (1137-rgfm: declared placeholder).
                name_source: Some(if enumerated_name.is_some() {
                    "enumerated".to_string()
                } else {
                    "placeholder".to_string()
                }),
                device_node: Some("/dev/dxg".to_string()),
                fw_version: None,
                driver: None,
                usable: enumerated_name.is_some(),
                // ORDER 793-zumy. This said `wsl2-no-dri-render-node`, and that
                // reason was a red herring dressed as a diagnosis. WSL2 delivers
                // the GPU through /dev/dxg and is NOT EXPECTED to create a DRI
                // render node at all, so naming the render node's absence as the
                // obstruction describes normal WSL2 rather than anything wrong —
                // while reading, to a scheduler, as a hardware verdict. Measured
                // on yolanda 2026-08-29: /dev/dxg present, /dev/dri absent,
                // /usr/lib/wsl/lib carrying libd3d12/libd3d12core/libdxcore, and
                // NO Vulkan loader — vulkaninfo off PATH, /usr/share/vulkan/icd.d
                // absent entirely. The device is delivered; the translation layer
                // is not installed. That is the real obstruction and it is a
                // PROVISIONING fact, three packages away (793-a8e7), not a
                // statement about the silicon. The same host has already driven
                // this GPU at 2.04x CPU prefill once a loader was present.
                //
                // `engine-missing` is the grammar's existing word for exactly
                // this — hardware present, no runtime to reach it — and is what
                // the packet's criterion 2 requires verbatim. The suffix keeps
                // WHICH engine and therefore what would fix it, matching the
                // sibling `rocm-runtime-missing` / `intel-compute-runtime-missing`
                // shape: a provisioning statement should name its own remedy.
                //
                // THE VERDICT IS NO LONGER A CONSTANT (793-zumy, criterion 2).
                // It stays false — and `unusable_reason` stays populated — on
                // every host where nothing enumerated a non-CPU device, which
                // is every host this file has ever been measured on except the
                // one carrying a working Dozen ICD. Inflating the class where
                // the GPU is NOT reachable would place GPU work on a host that
                // cannot run it; refusing it where the loader just enumerated
                // the device is the false negative this packet was filed for.
                // Both directions are now decided by the same evidence.
                // ORDER 803-rbqf, WHICH THIS ARM MUST OBEY TOO: A DEVICE
                // EXCLUDED BY LANE MUST NAME THE OBSTRUCTION. The enumerated
                // arm below is `usable: true` with the `container` lane
                // dropped, which is exactly the macOS Metal shape — and that
                // record does NOT leave the field empty, because a consumer
                // reading a device that is simply not offered in a lane has no
                // way to learn why. Leaving this `None` on the usable arm would
                // have rendered `accel_gpu=present-unusable` beside the NPU's
                // reason as the first named obstruction, which is the bare
                // verdict this envelope's own contract forbids.
                //
                // `unverified` and not a structural claim, which is where this
                // differs from Metal. Metal genuinely cannot cross into the
                // linux-aarch64 guest — there is no flag that would change the
                // answer. /dev/dxg has not been shown to be unpassable; it has
                // only never been probed from inside a container on this host,
                // so the AMD arm's `container-lane-unverified` is the honest
                // word. Claiming it structural would be a second false cause
                // in the packet that exists to remove the first one.
                unusable_reason: match &verdict {
                    // MEASURED 2026-09-19, so this is no longer `unverified`.
                    // It said `container-lane-unverified:dxg-unprobed` until
                    // the container lane was actually probed on esmeraldinha,
                    // three arms:
                    //   --device /dev/dxg alone                -> llvmpipe ONLY
                    //   + /usr/lib/wsl/lib bound               -> dzn loads, then
                    //        ID3D12DeviceFactory::CreateDevice failed; llvmpipe only
                    //   + ALL of /usr/lib/wsl (incl. drivers/) -> the host's two
                    //        devices, Dozen driverID=23 beside llvmpipe
                    //
                    // So the node DOES cross and the d3d12 libraries are
                    // mountable; what is absent is the projected WINDOWS DRIVER
                    // STORE that dzn resolves the real D3D12 device out of.
                    // Naming it that way matters: "dxg does not reach the
                    // container" would be false, and would read as a
                    // passthrough limitation when it is a mount policy the
                    // product could choose to change.
                    //
                    // KEPT UNDER 48 CHARACTERS DELIBERATELY (43). `slug()` caps
                    // every envelope value at 48 and says nothing when it cuts:
                    // an earlier spelling of this token was 52 characters and
                    // rendered as `container-lane-unverified_dxg-not-probed-in-cont`
                    // — a token that is not the token, with no marker that it
                    // had been shortened. Same failure the `nvidia_model_name`
                    // comment above records for a name truncated mid-UUID, and
                    // the same remedy: shorten the input, do not raise the cap.
                    Wsl2VulkanVerdict::Usable { .. } => {
                        Some("container-lane-absent:dxg-needs-wsl-drivers".to_string())
                    }
                    Wsl2VulkanVerdict::Unusable { reason } => Some(reason.clone()),
                },
                policy_unscheduled: None,
                // The lane is HOST-NATIVE ONLY, and never `container`. The
                // Vulkan device was enumerated by THIS process, in the guest;
                // nothing here has looked inside a container, and /dev/dxg is
                // not passed into one by default. Claiming a container lane off
                // a host-native enumeration is precisely the vantage confusion
                // `Vantage` exists to prevent.
                lanes: if enumerated_name.is_some() {
                    vec!["host-native".to_string()]
                } else {
                    // No lane: unreachable from the container AND from
                    // host-native code in the guest, because nothing translates
                    // onto the dxg path.
                    vec![]
                },
                memory_bandwidth_gbps: None,
                memory_bandwidth_source: "unknown".to_string(),
                cpu_flags: None,
                cpu_cores: None,
                system_ram_gb: None,
                memory_model: None,
            });
        }
    }

    gpus
}

// @trace spec:accel-capability-probe
/// Run a PowerShell query and return its non-empty stdout lines, or `None` when
/// the query could not be RUN at all.
///
/// ORDER 805-r98w. `None` and `Some(vec![])` are different facts and the caller
/// must not be able to confuse them: a PowerShell that failed to launch, exited
/// non-zero, or was blocked by policy has told us NOTHING about the hardware,
/// while an empty result set is a genuine finding. Collapsing the two is the
/// exact defect this order was filed against, one layer down.
#[cfg(target_os = "windows")]
fn powershell_lines(script: &str) -> Option<Vec<String>> {
    let out = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect(),
    )
}

/// Pull `VEN_xxxx` / `DEV_xxxx` out of a Windows PNP instance id.
///
/// Returns the pair as `1002:1114`, vendor and device TOGETHER — never either
/// alone. Vendor collides across parts, and device collides across vendors.
///
/// CAUTION, measured 2026-09-02 and stronger than the fleet assumed: the pair
/// is NOT sufficient to separate two machines either. This host (Radeon 860M)
/// reports 1002:1114, and yoga's host (Radeon 840M) reports 1002:1114 as well —
/// AMD ships the two bins under one device id, not merely one marketing name.
/// So the PCI pair would NOT have separated the hosts the fleet called twins;
/// the CPU model is still what does. Recorded on the accessor so nobody keys a
/// substrate control on it later.
#[cfg(target_os = "windows")]
fn pci_pair(instance_id: &str) -> Option<String> {
    let up = instance_id.to_ascii_uppercase();
    let grab = |key: &str| -> Option<String> {
        let i = up.find(key)? + key.len();
        let v: String = up[i..].chars().take(4).collect();
        (v.len() == 4 && v.chars().all(|c| c.is_ascii_hexdigit())).then_some(v)
    };
    Some(format!(
        "{}:{}",
        grab("VEN_")?.to_lowercase(),
        grab("DEV_")?.to_lowercase()
    ))
}

/// Enumerate GPUs on native Windows via `Win32_VideoController`.
///
/// HOST-NATIVE LANE ONLY, deliberately. Presence of a display adapter says
/// nothing about whether a CONTAINER can reach it, and the container lane on
/// this platform runs inside the WSL2 guest which probes itself. Claiming a
/// container lane from here would manufacture the reachability the accel matrix
/// exists to measure — the `Enumerated < Reachable < Placed` ordering is not
/// decoration.
#[cfg(target_os = "windows")]
fn windows_gpus() -> Option<Vec<DeviceRecord>> {
    let lines = powershell_lines(
        "Get-CimInstance Win32_VideoController -ErrorAction Stop | \
         ForEach-Object { $_.Name + '|' + $_.PNPDeviceID + '|' + $_.DriverVersion }",
    )?;
    Some(
        lines
            .iter()
            .filter_map(|l| {
                let mut f = l.split('|');
                let name = f.next()?.trim().to_string();
                if name.is_empty() {
                    return None;
                }
                let instance = f.next().unwrap_or("").trim();
                let driver = f.next().unwrap_or("").trim();
                let pair = pci_pair(instance);
                Some(DeviceRecord {
                    device_class: "gpu".to_string(),
                    vendor: match pair.as_deref().and_then(|p| p.split(':').next()) {
                        Some("1002") => "amd".to_string(),
                        Some("8086") => "intel".to_string(),
                        Some("10de") => "nvidia".to_string(),
                        _ => "unknown".to_string(),
                    },
                    name,
                    // Win32_VideoController's own Name (1137-rgfm: measured).
                    name_source: Some("measured".to_string()),
                    device_node: pair,
                    fw_version: None,
                    driver: (!driver.is_empty()).then(|| driver.to_string()),
                    // ENUMERATED, not reachable: see the doc comment.
                    usable: false,
                    unusable_reason: Some("host-native-only-not-container-reachable".to_string()),
                    policy_unscheduled: None,
                    lanes: vec!["host-native".to_string()],
                    memory_bandwidth_gbps: None,
                    memory_bandwidth_source: "unknown".to_string(),
                    cpu_flags: None,
                    cpu_cores: None,
                    system_ram_gb: None,
                    memory_model: None,
                })
            })
            .collect(),
    )
}

/// Enumerate NPUs on native Windows via the `ComputeAccelerator` device class.
///
/// Queried BY CLASS rather than by a hardware id, so an Intel NPU enumerates
/// here too without a table of ids to keep current. Verified on this host:
/// VEN_1022 / DEV_17F0, Status OK, FriendlyName "NPU Compute Accelerator
/// Device" — the same 1022:17f0 part yoga enumerates on Linux as amdxdna.
///
/// `usable: false` with `engine-missing` mirrors the Linux arm on purpose. A
/// present, driver-bound NPU still has no runtime this product can dispatch to;
/// yoga's phrase for the Linux side — "not missing the NPU, missing a
/// userspace" — is true on Windows as well, and a probe that flipped this to
/// usable because the device enumerates would be labelling wiring that does not
/// exist.
#[cfg(target_os = "windows")]
fn windows_npus() -> Option<Vec<DeviceRecord>> {
    let lines = powershell_lines(
        "Get-PnpDevice -Class ComputeAccelerator -PresentOnly -ErrorAction Stop | \
         ForEach-Object { $_.Status + '|' + $_.FriendlyName + '|' + $_.InstanceId }",
    )?;
    Some(
        lines
            .iter()
            .filter_map(|l| {
                let mut f = l.split('|');
                let status = f.next()?.trim().to_string();
                let name = f.next().unwrap_or("").trim().to_string();
                let instance = f.next().unwrap_or("").trim();
                let pair = pci_pair(instance);
                let vendor = match pair.as_deref().and_then(|p| p.split(':').next()) {
                    Some("1022") => "AMD XDNA".to_string(),
                    Some("8086") => "Intel NPU".to_string(),
                    _ => "unknown".to_string(),
                };
                // A device the OS reports as not-OK is enumerated but not
                // healthy; say which, rather than folding it into the same
                // engine-missing bucket as a working one.
                // The engine verdict is NOT decided here: derive_npu_usability
                // decides it in run_probe from the engines list (1253-54zj).
                // Only the OS health fact is recorded at this site.
                let reason = if status.eq_ignore_ascii_case("OK") {
                    None
                } else {
                    Some(NPU_DEVICE_NOT_OK.to_string())
                };
                Some(DeviceRecord {
                    device_class: "npu".to_string(),
                    vendor,
                    // 1137-rgfm: the PnP name is measured; the empty-name
                    // fallback is a placeholder and says so.
                    name_source: Some(
                        (if name.is_empty() {
                            "placeholder"
                        } else {
                            "measured"
                        })
                        .to_string(),
                    ),
                    name: if name.is_empty() {
                        "Unknown Compute Accelerator".to_string()
                    } else {
                        name
                    },
                    device_node: pair,
                    fw_version: None,
                    driver: None,
                    usable: false,
                    unusable_reason: reason,
                    policy_unscheduled: None,
                    lanes: vec!["host-native".to_string()],
                    memory_bandwidth_gbps: None,
                    memory_bandwidth_source: "unknown".to_string(),
                    cpu_flags: None,
                    cpu_cores: None,
                    system_ram_gb: None,
                    memory_model: None,
                })
            })
            .collect(),
    )
}

#[cfg(target_os = "linux")]
fn enumerate_npus() -> Vec<DeviceRecord> {
    let mut npus = Vec::new();
    let accel_dir = Path::new("/sys/class/accel");

    // PROBE-2: Kernel without accel class (e.g. WSL2) yields empty list and succeeds
    //
    // THIS IS A FINDING, NOT A GAP, and the distinction is deliberate (805-r98w,
    // 2026-09-02). The same day's work made native Windows report `unknown`
    // instead of `none`, because there no enumeration code existed at all — the
    // probe had never looked. Linux is not that case: sysfs IS the enumeration
    // mechanism, it was consulted, and an absent accel class is a true statement
    // about this kernel (no accel-class driver is bound). So this arm records no
    // enumeration gap and `none` stands.
    //
    // Measured in the tillandsias-build WSL2 guest: /sys/class/accel absent,
    // /dev/dxg present, amdxdna not loaded — on a machine whose NPU the Windows
    // host enumerates as 1022:17f0. The guest's `none` is vantage-correct: that
    // NPU is not passed through to WSL2 and nothing in the guest can reach it.
    // Cross-vantage disagreement about one machine is expected and is why
    // compare_documents refuses a cross-vantage pair.
    //
    // Do NOT "fix" this into `unknown`. Most Linux hosts genuinely have no NPU;
    // reporting unknown everywhere would trade a correct answer for noise, and
    // would be today's reasoning applied past the case that motivated it.
    if !accel_dir.exists() {
        return npus;
    }

    if let Ok(entries) = fs::read_dir(accel_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("accel") {
                let dev_path = entry.path();
                let uevent_path = dev_path.join("device/uevent");
                let uevent_content = fs::read_to_string(&uevent_path).unwrap_or_default();

                let mut driver_name = None;
                for line in uevent_content.lines() {
                    if let Some(drv) = line.strip_prefix("DRIVER=") {
                        driver_name = Some(drv.trim().to_string());
                        break;
                    }
                }

                let (vendor, name_str) = match driver_name.as_deref() {
                    Some("amdxdna") => ("AMD XDNA".to_string(), "AMD XDNA NPU".to_string()),
                    Some("intel_vpu") => ("Intel NPU".to_string(), "Intel NPU".to_string()),
                    Some(other) => ("unknown".to_string(), format!("Unknown NPU ({other})")),
                    None => ("unknown".to_string(), "Unknown Accel Device".to_string()),
                };

                let fw_version = fs::read_to_string(dev_path.join("device/firmware_version"))
                    .or_else(|_| fs::read_to_string(dev_path.join("device/fw_version")))
                    .ok()
                    .map(|s| s.trim().to_string());

                let node_path = format!("/dev/accel/{name}");

                // PROBE-3 (1253-54zj): the verdict is NOT written here any more.
                // It used to be the literal usable:false + "engine-missing", so
                // no host-side change could flip an NPU row. derive_npu_usability
                // decides it in run_probe from the engines list.
                npus.push(DeviceRecord {
                    device_class: "npu".to_string(),
                    vendor,
                    name: name_str,
                    // Derived from the driver name ("Intel NPU"), not read from
                    // the device: a placeholder by construction (1137-rgfm).
                    name_source: Some("placeholder".to_string()),
                    device_node: Some(node_path),
                    fw_version,
                    driver: driver_name,
                    usable: false,
                    unusable_reason: None,
                    policy_unscheduled: None,
                    lanes: vec!["host-native".to_string()],
                    memory_bandwidth_gbps: None,
                    memory_bandwidth_source: "unknown".to_string(),
                    cpu_flags: None,
                    cpu_cores: None,
                    system_ram_gb: None,
                    memory_model: None,
                });
            }
        }
    }

    npus
}

// @trace spec:accel-capability-probe
fn enumerate_host() -> HostInfo {
    // ORDER 803-r8u4. `None` IS THE STARTING POSITION, not `Some(false)`.
    //
    // A host with no arm below has not looked, and the only truthful thing it
    // can say is that it does not know. The old initializer was `false`, which
    // is a different claim — "this machine has no battery" — and every non-Linux
    // host made it without evidence.
    #[cfg_attr(not(any(target_os = "linux", target_os = "macos")), allow(unused_mut))]
    // The macOS arm answers in one expression rather than accumulating, so the
    // `None` initializer it replaces is never read there.
    #[cfg_attr(target_os = "macos", allow(unused_assignments))]
    let mut battery: Option<bool> = None;

    #[cfg(target_os = "linux")]
    {
        // A READABLE directory with no battery in it IS evidence of absence, so
        // this arm distinguishes the two outcomes the old code could not: the
        // scan that ran and found nothing answers `Some(false)`, while a
        // directory that could not be read at all leaves `None`.
        if let Ok(entries) = fs::read_dir("/sys/class/power_supply") {
            let mut found = false;
            for entry in entries.flatten() {
                let type_path = entry.path().join("type");
                if let Ok(t) = fs::read_to_string(type_path)
                    && t.trim().eq_ignore_ascii_case("battery")
                {
                    found = true;
                    break;
                }
            }
            battery = Some(found);
        }
    }

    #[cfg(target_os = "macos")]
    {
        // `pmset -g batt` names an internal battery when one is present. MEASURED
        // on tlatoanis-macbook-air (Apple M5) 2026-09-12:
        //
        //   Now drawing from 'AC Power'
        //    -InternalBattery-0 (id=23068771)\t80%; AC attached; not charging
        //
        // A desktop Mac prints the header and no `-InternalBattery-` line, which
        // is why the marker is the battery row rather than the exit status: the
        // command succeeds on both, and only the row separates them. A pmset
        // that fails to run leaves `None`, because then nothing looked.
        //
        // NOT KEYED ON "AC Power"/"Battery Power" — that is the CHARGING state,
        // which changes when someone unplugs the machine. The question here is
        // whether the hardware exists.
        battery = Command::new("pmset")
            .args(["-g", "batt"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).contains("InternalBattery"));
    }

    let kernel = Command::new("uname")
        .arg("-r")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    let (host_id, host_id_source) = resolve_host_id();

    let side = detect_side(&kernel);

    HostInfo {
        is_battery_present: battery,
        kernel_release: kernel,
        host_id,
        host_id_source,
        host_kind: host_kind().to_string(),
        side: Some(side.to_string()),
    }
}

/// Order 793-qr4t. Which side of which boundary this probe is standing on.
///
/// Evidence, in the order that matters, and the ORDER IS THE DESIGN: a forge
/// inside a container on a WSL2 guest is BOTH, and the answer a consumer needs
/// is the innermost boundary — that is the one whose far side holds the devices
/// it cannot reach. Widening the container test to run second would report
/// `wsl2-guest` for a container and re-open exactly the blind spot this field
/// closes.
///
/// Kernel release is a PARAMETER so the WSL2 arm is testable on a host that is
/// not WSL2. The filesystem probes are not parameterised because they are cheap
/// and their absence is the common case; [`side_from_evidence`] is the pure
/// function the tests drive.
#[cfg_attr(not(target_os = "linux"), allow(unused_variables))]
fn detect_side(kernel_release: &str) -> &'static str {
    #[cfg(target_os = "macos")]
    {
        "macos-host"
    }
    #[cfg(target_os = "windows")]
    {
        "windows-host"
    }
    #[cfg(target_os = "linux")]
    {
        side_from_evidence(
            Path::new("/run/.containerenv").exists() || Path::new("/.dockerenv").exists(),
            Path::new("/dev/dxg").exists(),
            kernel_release,
        )
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        "unknown-side"
    }
}

/// The Linux side decision as a pure function (order 793-qr4t).
///
/// WSL2 wants BOTH signals, not either. `/dev/dxg` alone appears on a Windows
/// host running WSLg-adjacent stacks and, more importantly, is the very node
/// 793-zumy teaches the GPU arm to read — reusing it as a side test would make
/// the side depend on whether a GPU happened to be paravirtualised. A
/// `microsoft` kernel release alone is likewise not decisive: it is the string
/// two WSL2 guests already share verbatim (see `HostInfo::host_id`), and it
/// survives into any image built from that kernel. Together they are the shape
/// only a WSL2 guest has.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn side_from_evidence(in_container: bool, dxg_present: bool, kernel_release: &str) -> &'static str {
    if in_container {
        return "container";
    }
    let microsoft_kernel = kernel_release.to_ascii_lowercase().contains("microsoft");
    if dxg_present && microsoft_kernel {
        return "wsl2-guest";
    }
    "native-linux"
}

// @trace spec:accel-capability-probe
/// Map the compile target onto the fleet's host vocabulary (order 808-43mw).
///
/// The ledger already speaks `linux` / `windows` / `macos`, so the matrix uses
/// those rather than Rust's `macos`-vs-`darwin` spelling of the same idea.
fn host_kind() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        std::env::consts::OS
    }
}

// @trace spec:accel-capability-probe
/// Normalise a node name the way the fleet's shell probe does (order 808-43mw).
///
/// Strip the domain and lowercase — the same two steps `tillandsias_node_name`
/// applies with bash builtins. Kept as a pure function so the agreement with
/// the shell chain is testable without a matching hostname.
fn normalize_node_name(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    let short = trimmed.split('.').next().unwrap_or("");
    if short.is_empty() {
        return None;
    }
    Some(short.to_ascii_lowercase())
}

// @trace spec:accel-capability-probe
/// Resolve `(host_id, host_id_source)` — the input first, then the fleet chain.
///
/// The fallback order mirrors `scripts/agent-identity.sh` deliberately:
/// `hostname` -> `uname -n` -> `/etc/hostname`. It is NOT a fresh guess at how
/// to name a machine; agreeing with the shell probe is the point, because the
/// matrix key and the attestation ledger's filename must be the same string.
///
/// Returns `unknown` rather than an empty string when nothing answers. An empty
/// host_id would fold as a legitimate key and silently collect every
/// unidentifiable host into one row — the exact collision this field exists to
/// prevent, reintroduced through the error path.
fn resolve_host_id() -> (String, String) {
    resolve_host_id_from(std::env::var(HOST_ID_ENV).ok().as_deref())
}

/// The resolver proper, with the input as a PARAMETER rather than a read of
/// the process environment (1146-z8ux). Two tests used to exercise this by
/// `set_var`/`remove_var` on `HOST_ID_ENV` from parallel threads of one test
/// process; when one removed the variable inside the other's window the first
/// resolved by node-name and the suite failed about one run in fifteen with
/// nothing wrong in the tree. Taking the input here deletes the shared global
/// from the tests instead of scheduling around it; production reads the
/// environment exactly once, in `resolve_host_id`.
fn resolve_host_id_from(input: Option<&str>) -> (String, String) {
    if let Some(v) = input
        && let Some(id) = normalize_node_name(v)
    {
        return (id, "input".to_string());
    }

    // `hostname -s` is deliberately NOT tried: order 743-mgf3 measured it
    // rejected under MSYS, and the shell probe dropped it for that reason.
    for (prog, args) in [("hostname", &[][..]), ("uname", &["-n"][..])] {
        if let Ok(out) = Command::new(prog).args(args).output()
            && out.status.success()
            && let Some(id) = normalize_node_name(&String::from_utf8_lossy(&out.stdout))
        {
            return (id, "node-name".to_string());
        }
    }

    if let Ok(content) = fs::read_to_string("/etc/hostname")
        && let Some(id) = normalize_node_name(&content)
    {
        return (id, "node-name".to_string());
    }

    ("unknown".to_string(), "unknown".to_string())
}

fn is_binary_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(meta) = fs::metadata(path) {
            return meta.is_file() && (meta.permissions().mode() & 0o111 != 0);
        }
        false
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

fn is_binary_available(binary: &str) -> bool {
    if let Ok(path_var) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path_var) {
            let full = dir.join(binary);
            if is_binary_executable(&full) {
                return true;
            }
        }
    }
    for std_path in ["/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/bin"] {
        let full = Path::new(std_path).join(binary);
        if is_binary_executable(&full) {
            return true;
        }
    }
    false
}

// @trace order:803-825k, order:850-bif2, spec:accel-capability-probe
fn enumerate_engines() -> Vec<EngineRecord> {
    enumerate_engines_with(is_binary_available, inference_image_present)
}

/// Is the fleet's inference image (`localhost/tillandsias-inference`) present
/// in the local podman store? That image ships ollama, so its presence is the
/// container-lane engine the host-PATH scan is structurally blind to
/// (order 850-bif2). `podman` absent or failing reads as "no image" — an
/// engine we cannot prove is an engine we do not claim.
fn inference_image_present() -> bool {
    tillandsias_podman::podman_cmd_sync()
        .args(["images", "--format", "{{.Repository}}"])
        .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget())
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .any(|l| l.trim().ends_with("/tillandsias-inference"))
        })
        .unwrap_or(false)
}

fn enumerate_engines_with<F, G>(mut binary_check: F, mut container_check: G) -> Vec<EngineRecord>
where
    F: FnMut(&str) -> bool,
    G: FnMut() -> bool,
{
    let mut engines = Vec::new();

    if binary_check("ollama") {
        engines.push(EngineRecord {
            name: "ollama".to_string(),
            backend: "llama-server".to_string(),
            supported_device_classes: vec!["cpu".to_string(), "gpu".to_string()],
            lanes: None,
        });
    }

    if binary_check("llama-server") {
        engines.push(EngineRecord {
            name: "llama-server".to_string(),
            backend: "llama.cpp".to_string(),
            supported_device_classes: vec!["cpu".to_string(), "gpu".to_string()],
            lanes: None,
        });
    }

    // Order 850-bif2: the containerized engine. Recorded only when the host
    // has no host-PATH ollama already covering every lane, and scoped to the
    // container lane — claiming host-native reach for a binary inside an
    // image would be the same over-claim in the other direction.
    if !engines.iter().any(|e| e.name == "ollama") && container_check() {
        engines.push(EngineRecord {
            name: "ollama".to_string(),
            backend: "llama-server".to_string(),
            supported_device_classes: vec!["cpu".to_string(), "gpu".to_string()],
            lanes: Some(vec!["container".to_string()]),
        });
    }

    engines
}

fn num_cpus() -> u32 {
    std::thread::available_parallelism()
        .map(|n| n.get() as u32)
        .unwrap_or(1)
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn physical_core_count() -> Option<u32> {
    #[cfg(target_os = "linux")]
    {
        if let Ok(content) = fs::read_to_string("/proc/cpuinfo") {
            let mut cores = std::collections::HashSet::new();
            let mut current_socket = None;
            let mut current_core = None;
            for line in content.lines() {
                if line.starts_with("physical id")
                    && let Some((_, v)) = line.split_once(':')
                {
                    current_socket = v.trim().parse::<u32>().ok();
                } else if line.starts_with("core id")
                    && let Some((_, v)) = line.split_once(':')
                {
                    current_core = v.trim().parse::<u32>().ok();
                }
                if let (Some(s), Some(c)) = (current_socket, current_core) {
                    cores.insert((s, c));
                    current_socket = None;
                    current_core = None;
                }
            }
            if !cores.is_empty() {
                return Some(cores.len() as u32);
            }
        }
    }
    None
}

/// Order 480 follow-up: project the capability document into ONE agent-facing
/// line so a forge can state, at launch, what accelerators this node actually
/// offers a container.
///
/// WHY THIS EXISTS: the probe above was implemented, unit-tested, and closed —
/// with NO caller anywhere in the product. `capabilities.json` was never written
/// on any host and nothing reached a forge. That is this project's named
/// recurring failure class ("verified where it was written is not verified where
/// it runs") in its purest form: the module's own tests passed while the feature
/// did not exist at runtime. The envelope is the surface that makes it real.
///
/// PINNED GRAMMAR (a closed vocabulary; agents branch on this, never on prose):
///   accel_class=<workstation-gpu|mobile-npu|hybrid-gpu-npu|cpu-only>
///   accel_gpu=<usable|present-unusable|none> accel_gpu_name=<slug|->
///   accel_npu=<usable|present-unusable|none> accel_npu_name=<slug|->
///   accel_reason=<reason|-> accel_cpu_cores=<n|-> accel_ram_gb=<n|->
///
/// `accel_class` is the TWO-TIER ROUTING SIGNAL: this workstation reports
/// `workstation-gpu`, a mobile host with a working NPU reports `mobile-npu`, and
/// a host whose accelerator cannot be delivered to a container reports
/// `cpu-only` with `accel_reason` naming why. An agent picks model size from the
/// class without probing hardware it cannot see.
///
/// USABILITY IS DECIDED BY THE CONTAINER LANE, not by `usable`. A device record
/// can carry `usable: true` together with `unusable_reason: cdi-spec-missing`
/// (the NVIDIA-without-CDI case constructs exactly that), so `usable` alone
/// would report a GPU this forge cannot touch. `lanes` contains `container`
/// only when the runtime can actually hand the device over, which is precisely
/// the question an agent inside a forge is asking.
// @trace spec:accel-capability-probe
pub fn accel_envelope(doc: &CapabilityDocument) -> String {
    let pick = |class: &str| -> Option<&DeviceRecord> {
        // Prefer a container-deliverable device; otherwise report the best
        // evidence we have, so "present but unusable" never renders as "none".
        doc.devices
            .iter()
            .find(|d| d.device_class == class && d.lanes.iter().any(|l| l == "container"))
            .or_else(|| doc.devices.iter().find(|d| d.device_class == class))
    };

    let state = |d: Option<&DeviceRecord>| match d {
        None => "none",
        Some(d) if d.lanes.iter().any(|l| l == "container") && d.unusable_reason.is_none() => {
            "usable"
        }
        Some(_) => "present-unusable",
    };

    let gpu = pick("gpu");
    let npu = pick("npu");
    let (gpu_state, mut npu_state) = (state(gpu), state(npu));

    // "none" is a FINDING; where the probe could not look it would be a guess
    // wearing a finding's clothes. The document records WHICH classes it failed
    // to enumerate, so this reads the run that produced the document rather than
    // the platform that is rendering it — a cached or transported document
    // keeps its own gaps, which a compile-time constant could never do.
    let gap = |class: &str| doc.enumeration_gaps.iter().any(|g| g == class);

    // ORDER 793-qr4t. A THIRD reason a class can come back empty, and it is not
    // the same as either of the two above.
    //
    // `none` means enumerated-and-absent. `unknown` means this probe has no arm
    // for the class on this platform (the Darwin ANE: present, drivable through
    // CoreML, on THIS side, and invisible only because `enumerate_npus` reads
    // `/sys/class/accel`). Neither describes a WSL2 guest, where the arm exists,
    // ran, and correctly found nothing — because the device is on the far side
    // of a VM boundary. Measured: an XDNA2 NPU healthy on the Windows side
    // (VEN_1022&DEV_17F0, driver 32.0.20102.3930) rendering `accel_npu=none` in
    // the guest, which reads as "this machine cannot do NPU work" and would
    // mis-plan a whole tier.
    //
    // The discriminator is the SIDE, not the class: on a boundary side the
    // probe's enumeration is evidence about the guest, never about the machine.
    // A native-Linux host with no NPU keeps `none`, which is the criterion that
    // stops this from being a blanket relabel.
    let side = accel_side(doc);
    let boundary_side = matches!(side, "wsl2-guest" | "container");
    let absent_state = |gap: bool| -> &'static str {
        if gap {
            "unknown"
        } else if boundary_side {
            "unobservable-from-this-side"
        } else {
            "none"
        }
    };
    if npu.is_none() {
        npu_state = absent_state(gap("npu"));
    }
    let mut gpu_state = gpu_state;
    if gpu.is_none() {
        gpu_state = absent_state(gap("gpu"));
    }

    let class = match (gpu_state, npu_state) {
        ("usable", "usable") => "hybrid-gpu-npu",
        ("usable", _) => "workstation-gpu",
        (_, "usable") => "mobile-npu",
        _ => "cpu-only",
    };

    // The first named obstruction, so `cpu-only` is never a bare verdict.
    let reason = gpu
        .and_then(|d| d.unusable_reason.as_deref())
        .or_else(|| npu.and_then(|d| d.unusable_reason.as_deref()))
        .unwrap_or(match (gpu_state, npu_state) {
            // So `cpu-only` is never a bare verdict on a host that simply could
            // not look for the accelerators it is denying.
            ("unknown", "unknown") => "gpu-and-npu-not-enumerable-on-this-platform",
            ("unknown", _) => "gpu-not-enumerable-on-this-platform",
            (_, "unknown") => "npu-not-enumerable-on-this-platform",
            // Order 793-qr4t: same principle one boundary out. The obstruction
            // is the boundary itself, and naming it is what stops a reader
            // concluding the hardware is absent.
            ("unobservable-from-this-side", "unobservable-from-this-side") => {
                "gpu-and-npu-across-the-boundary-from-this-side"
            }
            ("unobservable-from-this-side", _) => "gpu-across-the-boundary-from-this-side",
            (_, "unobservable-from-this-side") => "npu-across-the-boundary-from-this-side",
            _ => "-",
        });

    let cpu = doc.devices.iter().find(|d| d.device_class == "cpu");
    let cores = cpu
        .and_then(|d| d.cpu_cores.as_ref())
        .map(|c| c.logical.to_string())
        .unwrap_or_else(|| "-".to_string());
    let ram = cpu
        .and_then(|d| d.system_ram_gb)
        .map(|g| format!("{g:.0}"))
        .unwrap_or_else(|| "-".to_string());

    // 793-zumy REMAINING 2. The HIGHEST rung any container-lane render node
    // reached, appended LAST so every existing grep/sed consumer and
    // `litmus:accel-envelope-reaches-the-forge` are unaffected by its arrival.
    //
    // `-` MEANS NOBODY ASKED OR NOTHING ANSWERED, and it is deliberately not
    // `enumerated`: an absent producer and a producer that found a device are
    // different facts, and collapsing them is the substitution this packet
    // exists to end. Only `placed` may be read as a lane - `Proof::proves_a_lane`
    // is the one comparison a consumer should make, and it is one keystroke away
    // from `>= reachable`, which is the mistake this whole family is about.
    let proof = match doc.render_nodes.iter().map(|n| n.proof).max() {
        Some(p) => p.token(),
        // NOBODY TO ASK vs ASKED AND FOUND NOTHING. Yoga measured these
        // collapsed into one token on 2026-09-02 and the envelope on a host
        // with a WORKING container lane was indistinguishable from one with no
        // accelerator — under-claiming, silently. `unknown` is the same word
        // this envelope already uses for a device class the probe could not
        // enumerate, and it is deliberately not `none`.
        None if gap("container-lane") => "unknown",
        None => "none",
    };

    // ORDERS 793-qr4t + 793-qc6q. APPENDED, never interleaved: every key above
    // keeps its name, position and meaning, so 769-w3ma's consumers and
    // `litmus:accel-envelope-reaches-the-forge` read exactly what they read
    // before. A grammar extension that moved an existing key would be a rename
    // wearing an addition's clothes.
    let mem_model = mem_model(side, gpu);
    let routing = routing_summary(doc);

    format!(
        "accel_class={} accel_gpu={} accel_gpu_name={} accel_npu={} accel_npu_name={} \
         accel_reason={} accel_cpu_cores={} accel_ram_gb={} accel_proof={} \
         accel_side={} accel_gpu_path={} accel_gpu_engine={} \
         accel_mem_model={} accel_mem_budget_gb={} \
         accel_prefill_dev={} accel_decode_dev={} accel_decode_crossover_b={} \
         accel_source={}",
        class,
        gpu_state,
        gpu.map(|d| slug(&d.name))
            .unwrap_or_else(|| "-".to_string()),
        npu_state,
        npu.map(|d| slug(&d.name))
            .unwrap_or_else(|| "-".to_string()),
        slug(reason),
        cores,
        ram,
        proof,
        side,
        gpu_path(side, gpu),
        gpu_engine(doc, gpu),
        mem_model,
        // ONE budget, side-scoped, and the whole point of emitting it beside
        // `accel_mem_model` rather than alone. Measured on windows/Yolanda: the
        // probe reported `accel_ram_gb=7` (the guest's slice) while dzn
        // advertised a 7.58 GiB DEVICE_LOCAL heap — the SAME physical DRAM,
        // counted twice, and neither of them the machine's 15.2 GB. A 522
        // sizing consumer that adds a GPU pool to a CPU pool on a
        // `unified` node has doubled a pool that does not exist. There is
        // exactly one number here on purpose: nothing to add.
        ram,
        routing.prefill,
        routing.decode,
        routing.crossover,
        // ORDER 1139-xe5m, APPENDED LAST for the same reason `accel_proof` was:
        // every key above keeps its name, position and meaning, and
        // `litmus:accel-envelope-reaches-the-forge` reads what it read before.
        //
        // THE LINE NEEDS IT, NOT ONLY THE JSON. This one line is what a forge
        // receives as TILLANDSIAS_ACCEL_ENVELOPE and what the capability matrix
        // folds; an agent holding it cannot open the producing host's cache
        // file, so a JSON-only field would leave exactly the reader this packet
        // is about unable to tell a replay from a measurement.
        //
        // `unknown` for a document written before this order — NOT `measured`.
        // Promoting silence to a measurement is the inference the order exists
        // to stop, and it would make every legacy row read as fresh.
        match doc.envelope_source {
            Some(EnvelopeSource::Measured) => "measured",
            Some(EnvelopeSource::Served) => "served",
            None => "unknown",
        },
    )
}

/// Order 793-qr4t. Which side of which boundary produced this document.
///
/// Read from the DOCUMENT, never from the reader's own `cfg!`: the fleet matrix
/// folds rows probed on other machines, so a renderer that asked itself would
/// answer about itself. `None` (every pre-schema-3 document) reads
/// `unknown-side`, which is honest — those documents genuinely do not say — and
/// is deliberately NOT `native-linux`, since defaulting a missing side to the
/// commonest one would silently re-assert the collapse this field removes.
// @trace order:793-qr4t, spec:accel-capability-probe
pub fn accel_side(doc: &CapabilityDocument) -> &str {
    doc.host.side.as_deref().unwrap_or("unknown-side")
}

/// HOW the GPU is reached: `drm` | `dxg-d3d12` | `metal` | `cuda` | `none`.
///
/// The PATH is not the ENGINE and conflating them is one of the four facts
/// 793-qr4t is unpacking. A WSL2 guest reaches its GPU over `/dev/dxg` and
/// drives it with Vulkan-over-D3D12; the path is a property of the boundary,
/// the engine of the software stack, and a host can have either without the
/// other. Measured on windows/Yolanda: `/dev/dxg` present and ollama logging
/// `library=cpu`, because no Vulkan loader was installed — a real path with no
/// engine on it.
///
/// Decided from the device NODE first, because that is evidence, and only then
/// from the side, which is an inference about a device we could not otherwise
/// place.
// @trace order:793-qr4t, spec:accel-capability-probe
fn gpu_path(side: &str, gpu: Option<&DeviceRecord>) -> &'static str {
    let Some(g) = gpu else {
        return "none";
    };
    let node = g.device_node.as_deref().unwrap_or("");
    if node.starts_with("/dev/dxg") {
        return "dxg-d3d12";
    }
    if node.starts_with("/dev/nvidia") {
        return "cuda";
    }
    if node.starts_with("/dev/dri") || node.starts_with("/dev/kfd") {
        return "drm";
    }
    match side {
        "macos-host" => "metal",
        "windows-host" => "dxg-d3d12",
        "wsl2-guest" => "dxg-d3d12",
        "native-linux" | "container" => "drm",
        _ => "none",
    }
}

/// WHICH ENGINE, IF ANY, CAN DRIVE THE GPU — the third of the four collapsed
/// facts, and the one whose absence made a host with a usable RTX A5000 report
/// `schedulable: none`.
///
/// `engine-missing` and `none` are different answers to different questions and
/// that difference is the whole key: `none` means there is no GPU here (buy
/// hardware); `engine-missing` means there is a GPU and we ship nothing that
/// can drive it (ship a lane). The probe already distinguishes them for the
/// NPU — that record carries `unusable_reason: engine-missing` — and could not
/// for the GPU, because `accel_envelope` never read `doc.engines` at all.
///
/// AN UNRECOGNISED ENGINE RENDERS ITS OWN SLUG rather than being forced into
/// the nearest listed value. The known mappings below cover the stacks the
/// fleet ships; `ollama` is on this very host and is not one of them. Reporting
/// it as, say, `rocm` because it is the closest label would be exactly the
/// confident half-answer this packet is dismantling, and a reader who does not
/// recognise a slug can find out, whereas a reader given a wrong one cannot.
// @trace order:793-qr4t, spec:accel-capability-probe
fn gpu_engine(doc: &CapabilityDocument, gpu: Option<&DeviceRecord>) -> String {
    let Some(_) = gpu else {
        return "none".to_string();
    };
    let Some(e) = doc
        .engines
        .iter()
        .find(|e| e.supported_device_classes.iter().any(|c| c == "gpu"))
    else {
        return "engine-missing".to_string();
    };
    let hay = format!("{} {}", e.name, e.backend).to_ascii_lowercase();
    let known = if hay.contains("rocm") || hay.contains("hip") {
        Some("rocm")
    } else if hay.contains("cuda") {
        Some("cuda")
    } else if hay.contains("metal") {
        Some("metal")
    } else if hay.contains("vulkan") && (hay.contains("dozen") || hay.contains("dzn")) {
        Some("vulkan-dozen")
    } else if hay.contains("vulkan") && hay.contains("radv") {
        Some("vulkan-radv")
    } else {
        None
    };
    known
        .map(|k| k.to_string())
        .unwrap_or_else(|| slug(&e.name))
}

/// What the envelope PRINTS for the memory model, in five distinguishable
/// states (order 964-r98h; the five-way split is yolanda's correction).
///
/// The classifier itself lives on the device now
/// ([`memory_model_from_evidence`]), so this function's only remaining job is
/// the one it was getting wrong: saying WHY there is no answer.
///
/// YOLANDA'S DEFECT, WHICH THEY SHIPPED IN THIS FILE AND YOGA CAUGHT, ARRIVING
/// ONE FIELD OVER. Their `accel_proof` rendered a single token for both "nobody
/// to ask" and "asked and found nothing", so a host whose lane was WORKING read
/// identically to one with no accelerator. My first version had the same hole:
/// "no GPU at all", "a GPU whose evidence path cannot run on this side", and "a
/// GPU whose classifier ran and could not decide" all printed `unknown`. Those
/// are three different engineering problems and only the last is a defect in
/// the classifier.
///
///   `unified`  / `discrete`                  — decided from evidence.
///   `no-gpu`                                 — nothing to sum against.
///   `unobservable-from-this-side`            — a real GPU, and an evidence
///        path this side cannot reach. The WSL2 row is the case: a paravirtual
///        GPU on `/dev/dxg` exposes no DRM sysfs at all, so that host will
///        report this permanently until a Windows-side arm supplies the value.
///        That is a true statement about the boundary, not a gap in the probe.
///   `undetermined`                           — the classifier RAN and refused.
///
/// EVERY NON-DECIDED STATE CARRIES THE SAME OBLIGATION: do not sum a GPU pool
/// with a CPU pool. `unified` is the only value that positively licenses
/// reading `accel_mem_budget_gb` as the whole machine.
// @trace order:964-r98h, spec:accel-capability-probe
fn mem_model(side: &str, gpu: Option<&DeviceRecord>) -> &'static str {
    let Some(g) = gpu else {
        return "no-gpu";
    };
    match g.memory_model.as_deref() {
        Some("unified") => "unified",
        Some("discrete") => "discrete",
        // Apple silicon is unified BY CONSTRUCTION — there is no discrete
        // alternative to confuse it with — and the Darwin arm has no sysfs to
        // read, so this is the one architectural assertion kept in the
        // renderer rather than derived from evidence.
        _ if side == "macos-host" || g.vendor.eq_ignore_ascii_case("apple") => "unified",
        _ if matches!(side, "wsl2-guest" | "container" | "windows-host") => {
            "unobservable-from-this-side"
        }
        _ => "undetermined",
    }
}

/// Where the decode phase's CPU/GPU curves cross, DERIVED from this host's own
/// measurements (order 793-qc6q).
#[derive(Debug, Clone, Copy, PartialEq)]
// @trace order:793-qc6q, spec:accel-capability-probe
pub enum DecodeCrossover {
    /// No pair of CPU and GPU decode measurements at a common model size.
    /// The policy MUST NOT invent one: the packet's exit criterion rules out
    /// "a constant that happens to fit windows/Yolanda", and an unmeasured host
    /// routing decode to the GPU on that constant's authority is precisely the
    /// silent 1.23x regression it was written to prevent.
    Unmeasured,
    /// The GPU wins decode at this parameter count (billions) and above.
    AtOrAbove(f64),
    /// Measured across every available size and the CPU won at all of them.
    /// Distinct from `Unmeasured`: this host HAS looked, and the answer is no.
    CpuWinsThroughout,
}

/// Derive the decode crossover from `doc.measurements`.
///
/// WHY THIS READS A CACHE AND NOT A CONSTANT: decode is memory-bandwidth-bound,
/// so on unified memory the iGPU reads the same DRAM as the CPU and brings only
/// compute against a fixed per-dispatch cost. Below some size that cost
/// dominates. WHERE that size falls is a property of one machine's
/// compute-to-bandwidth ratio — measured at between 0.5B and 3B on
/// windows/Yolanda (decode 0.5B: CPU 78.68 vs GPU 63.75 t/s; 3B: CPU 19.64 vs
/// GPU 26.96) — and Apple silicon is a second unified architecture with far
/// higher bandwidth where the same threshold has no reason to hold. Hard-coding
/// Yolanda's number would read one host's hardware ratio as an architectural
/// law.
///
/// The returned threshold is a MEASURED SIZE, never an interpolation between
/// two. Interpolating would manufacture a precision the three-point sample
/// cannot support, and the routing decision only ever compares against it.
///
/// A CPU ROW AND A GPU ROW ARE COMPARABLE ONLY WITHIN ONE
/// [`MeasurementRecord::locus`] (order 793-qc6q, closing a hole this function
/// shipped with). The crossover is the point where two curves cross, so every
/// verdict it returns rests on a SUBTRACTION between a CPU number and a GPU
/// number — and that subtraction is meaningless across a boundary that costs
/// 5-10% by itself. That figure is not hypothetical: `MeasurementRecord::locus`
/// exists because this fleet measured the same suite at two loci and the hop
/// INVERTED a reported conclusion, two errors having cancelled. Pairing across
/// loci here would have reproduced that inversion inside a routing threshold,
/// where nothing downstream could see it.
///
/// So rows are grouped by locus and paired only within a group. An
/// unattributed row (`locus: None`) forms its own group rather than joining
/// any other: absent is not a value, and treating it as one would silently
/// pair the very rows whose side nobody recorded.
///
/// WHEN TWO LOCI DISAGREE the most conservative verdict wins — `CpuWins`
/// over a threshold, and a higher threshold over a lower one. That is the
/// standing tie-break of this whole packet rather than a new rule: the CPU is
/// the floor (620-ca7g), and the failure being prevented is a silent 1.23x
/// regression from routing to the GPU too eagerly. Erring toward the CPU costs
/// a measured fraction; erring the other way is the defect.
// @trace order:793-qc6q, spec:accel-capability-probe
/// Decode throughput at ONE model size, in ONE locus.
///
/// The locus is part of the KEY, not metadata hanging off the row: two rows
/// that differ only in locus describe different measurements and must never
/// merge into one. Naming the fields rather than carrying a tuple is what
/// makes that readable at the use site — `row.locus` beside `row.params_b`
/// says the pairing rule out loud, where `.0` beside `.1` did not.
struct DecodeSizeRow<'a> {
    locus: Option<&'a str>,
    params_b: f64,
    cpu_tps: Option<f64>,
    gpu_tps: Option<f64>,
}

/// The same row once BOTH devices have reported at that size and locus — the
/// only shape a crossover can be read from.
struct PairedSize<'a> {
    locus: Option<&'a str>,
    params_b: f64,
    cpu_tps: f64,
    gpu_tps: f64,
}

// @trace order:793-qc6q, spec:accel-capability-probe
pub fn decode_crossover_b(doc: &CapabilityDocument) -> DecodeCrossover {
    let mut sizes: Vec<DecodeSizeRow<'_>> = Vec::new();
    for m in &doc.measurements {
        let (Some(p), Some(tps)) = (m.model_params_b, m.decode_tps) else {
            continue;
        };
        // A degraded run is not evidence about the device; it is evidence the
        // run went wrong, and folding it in would move a threshold on the
        // strength of a failure.
        if m.degraded {
            continue;
        }
        let dev = m.device.to_ascii_lowercase();
        let locus = m.locus.as_deref();
        let slot = sizes
            .iter_mut()
            .find(|r| r.locus == locus && (r.params_b - p).abs() < 1e-9);
        let entry = match slot {
            Some(e) => e,
            None => {
                sizes.push(DecodeSizeRow {
                    locus,
                    params_b: p,
                    cpu_tps: None,
                    gpu_tps: None,
                });
                sizes.last_mut().expect("just pushed")
            }
        };
        if dev.starts_with("cpu") {
            entry.cpu_tps = Some(entry.cpu_tps.map_or(tps, |v: f64| v.max(tps)));
        } else if dev.starts_with("gpu") {
            entry.gpu_tps = Some(entry.gpu_tps.map_or(tps, |v: f64| v.max(tps)));
        }
    }

    // Only sizes measured on BOTH devices, and both at the SAME locus, survive.
    let mut paired: Vec<PairedSize<'_>> = sizes
        .into_iter()
        .filter_map(|r| {
            Some(PairedSize {
                locus: r.locus,
                params_b: r.params_b,
                cpu_tps: r.cpu_tps?,
                gpu_tps: r.gpu_tps?,
            })
        })
        .collect();
    if paired.is_empty() {
        return DecodeCrossover::Unmeasured;
    }
    paired.sort_by(|a, b| a.params_b.partial_cmp(&b.params_b).expect("finite sizes"));

    let mut loci: Vec<Option<&str>> = paired.iter().map(|r| r.locus).collect();
    loci.sort_unstable();
    loci.dedup();

    let mut verdict: Option<DecodeCrossover> = None;
    for locus in loci {
        // `paired` is sorted by size, so the FIRST size at which the GPU draws
        // level within this locus is the crossover for it.
        let this = match paired
            .iter()
            .filter(|r| r.locus == locus)
            .find(|r| r.gpu_tps >= r.cpu_tps)
        {
            Some(r) => DecodeCrossover::AtOrAbove(r.params_b),
            None => DecodeCrossover::CpuWinsThroughout,
        };
        // Most conservative wins: the CPU floor beats any threshold, and
        // between two thresholds the HIGHER one sends less work to the GPU.
        verdict = Some(match (verdict, this) {
            (None, v) => v,
            (Some(DecodeCrossover::CpuWinsThroughout), _)
            | (_, DecodeCrossover::CpuWinsThroughout) => DecodeCrossover::CpuWinsThroughout,
            (Some(DecodeCrossover::AtOrAbove(a)), DecodeCrossover::AtOrAbove(b)) => {
                DecodeCrossover::AtOrAbove(a.max(b))
            }
            (Some(prev), _) => prev,
        });
    }
    verdict.unwrap_or(DecodeCrossover::Unmeasured)
}

/// A phase of inference work. The UNIT OF ROUTING (order 793-qc6q).
///
/// Not the host and not the model. Two independent lines of evidence agree that
/// the phases want different devices on the SAME host with the SAME model:
/// ours (prefill is a batched GEMM and compute-bound, so the iGPU wins;
/// decode is bandwidth-bound and on unified memory it does not) and AMD's
/// Lemonade hybrid mode, which puts prompt processing on the NPU and token
/// generation on the GPU. A per-host device choice has to be wrong for one of
/// them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
// @trace order:793-qc6q, spec:accel-capability-probe
pub enum Phase {
    Prefill,
    Decode,
    Embed,
    Rerank,
}

/// WHICH LANE the routing question is being asked about (order 793-qc6q).
///
/// THE SECOND HALF OF "PER PHASE, NOT PER HOST", and it was missing. A device
/// is not usable or unusable in the abstract: it is deliverable to a container
/// or it is not, and those are different questions with different answers on
/// the same machine at the same moment. [`accel_envelope`] asks the container
/// question and is right to — it renders for an agent inside a forge — but
/// [`route_phase`] inherited that hard-coded `container` and could therefore
/// only ever answer for one lane.
///
/// MEASURED CONSEQUENCE (2026-09-03, the fleet's only unified-memory host):
/// macOS Metal reads `present-unusable` because a forge container cannot reach
/// it, which is CORRECT for the container lane and wrong for host-native
/// inference — and routing believed it, sending both phases to the CPU on a
/// host where the GPU wins decode by 1.27-1.64x and prefill by 3.2-3.8x. The
/// device state was accurate; the question was under-specified.
///
/// The tokens are the ones `DeviceRecord::lanes` and `EngineRecord::lanes` are
/// already spelled with, so this selects among existing evidence rather than
/// introducing a parallel vocabulary. NOT to be confused with
/// [`MeasurementRecord::locus`], which says where a BENCHMARK ran
/// (`in-guest`, `host-side-via-mirror`) — a different axis with a different
/// vocabulary, related only in that both exist because "here" was ambiguous.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
// @trace order:793-qc6q, spec:accel-capability-probe
pub enum RoutingLocus {
    /// Work that will run inside a container — the forge lane, and the
    /// question [`accel_envelope`] renders for.
    Container,
    /// Work that will run directly on the host: the macOS Metal case, and any
    /// host-side inference server the enclave does not own.
    HostNative,
}

impl RoutingLocus {
    /// The `lanes` token this locus is spelled with in a capability document.
    // @trace order:793-qc6q, spec:accel-capability-probe
    pub fn lane(self) -> &'static str {
        match self {
            RoutingLocus::Container => "container",
            RoutingLocus::HostNative => "host-native",
        }
    }
}

/// Where a phase runs, and WHY it is not running somewhere better.
#[derive(Debug, Clone, PartialEq, Eq)]
// @trace order:793-qc6q, spec:accel-capability-probe
pub struct Placement {
    /// `npu` | `gpu` | `cpu`.
    pub device: &'static str,
    /// Never empty, and never `-` when the device is `cpu`.
    ///
    /// THE PACKET'S THIRD EXIT CRITERION IS ABOUT THIS FIELD: "a fallback is
    /// never silent". The failure it names is the one that cost a day on
    /// windows/Yolanda — ollama logging `library=cpu` while every signal said
    /// GPU, because the loader was absent and nothing said so. A reason string
    /// is the difference between a fallback and a mystery.
    pub reason: String,
}

/// Whether a device class can actually be driven IN THIS LOCUS: a lane AND an
/// engine, both on the side the work will run.
///
/// BOTH HALVES, and this is the engine-qualification 793-qr4t adds being
/// consumed rather than merely published. macuahuitl reported a container-lane
/// RTX A5000 with `engines: []` and the matrix printed `schedulable: none` —
/// correctly, since a device nothing can drive is not a target. Routing that
/// reads only the lane would send work to it and land on the same
/// `library=cpu` silence.
///
/// THE ENGINE IS CHECKED AGAINST THE LOCUS TOO, which it was not before. An
/// engine's `lanes` is `None` for a host-PATH binary (every lane) and
/// `Some(["container"])` for the fleet's containerized ollama. Asking the
/// host-native question while counting a container-only engine as an answer
/// reproduces the exact defect this locus parameter exists to fix, one field
/// further in: a device that is genuinely reachable host-native, credited to an
/// engine that is not.
// @trace order:793-qc6q, spec:accel-capability-probe
fn phase_device_usable(doc: &CapabilityDocument, class: &str, locus: RoutingLocus) -> bool {
    let lane = locus.lane();
    let lane_ok = doc.devices.iter().any(|d| {
        d.device_class == class && d.lanes.iter().any(|l| l == lane) && d.unusable_reason.is_none()
    });
    let engine_ok = doc.engines.iter().any(|e| {
        e.supported_device_classes.iter().any(|c| c == class)
            // `None` means every lane — the pre-existing semantics for a host
            // PATH binary, preserved literally so no document filed before
            // 850-bif2 changes meaning under this read.
            && e.lanes.as_ref().is_none_or(|ls| ls.iter().any(|l| l == lane))
    });
    lane_ok && engine_ok
}

/// Route one phase in one locus, given the model's size in billions of
/// parameters where the caller knows it (order 793-qc6q).
///
/// THE CPU IS THE FLOOR AND EVERY ARM ENDS THERE. 620-ca7g is preserved
/// literally: there is no input to this function that yields a device the host
/// cannot run on, and no configuration that makes an accelerator a hard
/// requirement — the worst case is `cpu` with a reason naming what was missing.
///
/// `locus` SAYS WHICH SIDE THE WORK WILL RUN ON, and is not a hint. The same
/// document answers differently for [`RoutingLocus::Container`] and
/// [`RoutingLocus::HostNative`] on any host whose accelerator does not cross
/// the boundary — which is every macOS host in the fleet, and the reason this
/// function reported `cpu` for both phases on a machine whose GPU wins both.
/// A caller that does not know its own side is asking a question that has no
/// answer; there is deliberately no default.
// @trace order:793-qc6q, spec:accel-capability-probe
pub fn route_phase(
    doc: &CapabilityDocument,
    phase: Phase,
    model_params_b: Option<f64>,
    locus: RoutingLocus,
) -> Placement {
    let npu = phase_device_usable(doc, "npu", locus);
    let gpu = phase_device_usable(doc, "gpu", locus);
    let lane = locus.lane();
    // EXIT CRITERION 3, sharpened by the locus. "no-usable-gpu-for-decode" was
    // true and unactionable: it did not say IN WHICH LANE the GPU was not
    // usable, so a macOS reader could not tell a host with no GPU from a host
    // whose GPU simply does not cross into a container. Every fallback reason
    // below therefore names the lane it was decided in.
    let cpu = |reason: &str| Placement {
        device: "cpu",
        reason: format!("{reason}-in-{lane}"),
    };

    match phase {
        // Compute-bound and batched: every accelerator we have measured wins,
        // so the order is simply best-available.
        Phase::Prefill => {
            if npu {
                Placement {
                    device: "npu",
                    reason: format!("npu-usable-prefill-is-compute-bound-in-{lane}"),
                }
            } else if gpu {
                Placement {
                    device: "gpu",
                    reason: format!("no-usable-npu-gpu-wins-compute-bound-prefill-in-{lane}"),
                }
            } else {
                cpu("no-usable-accelerator-for-prefill")
            }
        }
        Phase::Decode => {
            if !gpu {
                return cpu("no-usable-gpu-for-decode");
            }
            match decode_crossover_b(doc) {
                DecodeCrossover::Unmeasured => cpu("decode-crossover-unmeasured-on-this-host"),
                DecodeCrossover::CpuWinsThroughout => {
                    cpu("cpu-wins-decode-at-every-measured-size-on-this-host")
                }
                DecodeCrossover::AtOrAbove(t) => match model_params_b {
                    None => cpu("model-size-unknown-cannot-apply-measured-crossover"),
                    Some(p) if p >= t => Placement {
                        device: "gpu",
                        reason: format!("model-{p}b-at-or-above-measured-crossover-{t}b-in-{lane}"),
                    },
                    Some(p) => cpu(&format!("model-{p}b-below-measured-crossover-{t}b")),
                },
            }
        }
        // NEVER THE iGPU, and the guard is unconditional rather than
        // conditioned on `mem_model` reaching `unified`. Measured: embed is
        // CPU 8.7ms vs GPU 10.2ms — the GPU LOSES — and `mem_model` answers
        // `unknown` for every AMD and Intel DRM device in the fleet, so a
        // guard written as "unless unified" would open on exactly the hosts
        // the measurement came from.
        Phase::Embed => {
            if npu {
                Placement {
                    device: "npu",
                    reason: format!("npu-embedding-engine-usable-in-{lane}"),
                }
            } else {
                cpu("embed-never-routed-to-gpu-measured-slower-than-cpu")
            }
        }
        // Not measured anywhere in the fleet. The floor is the honest answer
        // and it says so, rather than borrowing the embed arm's reasoning for
        // a workload nobody has timed.
        Phase::Rerank => cpu("rerank-on-npu-unverified-cpu-is-the-measured-floor"),
    }
}

/// The three routing keys the envelope renders (order 793-qc6q).
struct RoutingSummary {
    prefill: &'static str,
    decode: &'static str,
    crossover: String,
}

/// WHY `accel_decode_dev` IS NOT A PER-MODEL ANSWER: the envelope is rendered
/// once at forge launch and read by agents choosing models later, so it cannot
/// know a size. It states the POLICY — is the GPU reachable for decode at all
/// on this host — and publishes the threshold beside it as
/// `accel_decode_crossover_b`, so a consumer applies the same comparison
/// [`route_phase`] would. Folding the threshold into the device value would
/// force a size the renderer does not have.
fn routing_summary(doc: &CapabilityDocument) -> RoutingSummary {
    // THE ENVELOPE ASKS THE CONTAINER QUESTION, and passing the locus
    // explicitly is how that stays a decision rather than an inherited
    // default. Its whole audience is an agent inside a forge — the doc comment
    // on `accel_envelope` says so — so `Container` is right here and the
    // pinned `accel_*` grammar is unchanged by 793-qc6q's locus work. A
    // host-native consumer must call `route_phase` with its own locus instead
    // of reading these keys, which describe a lane it is not in.
    let locus = RoutingLocus::Container;
    let prefill = route_phase(doc, Phase::Prefill, None, locus).device;
    let crossover = decode_crossover_b(doc);
    let decode = match crossover {
        DecodeCrossover::AtOrAbove(_) if phase_device_usable(doc, "gpu", locus) => "gpu",
        _ => "cpu",
    };
    let crossover = match crossover {
        DecodeCrossover::Unmeasured => "unmeasured".to_string(),
        DecodeCrossover::CpuWinsThroughout => "cpu-wins".to_string(),
        DecodeCrossover::AtOrAbove(t) => format!("{t}"),
    };
    RoutingSummary {
        prefill,
        decode,
        crossover,
    }
}

/// Extract the model name from an `nvidia-smi -L` line.
///
/// The raw line is `GPU 0: NVIDIA RTX A5000 (UUID: GPU-354dc81c-…)`. Storing it
/// verbatim was wrong on two counts. It is noisy — the envelope's bounded name
/// field truncated mid-UUID, so an agent read a mangled identifier instead of a
/// model. And the UUID is a STABLE HARDWARE IDENTIFIER for this machine, which
/// the envelope hands to every forge container and writes into an on-disk
/// context file; a device model is what a consumer needs, so the serial number
/// has no business travelling with it.
///
/// Falls back to the whole line when the shape does not match, so an unexpected
/// `nvidia-smi` format degrades to "noisy" rather than "empty".
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn nvidia_model_name(line: &str) -> String {
    let after_index = line.split_once(": ").map(|(_, rest)| rest).unwrap_or(line);
    let without_uuid = after_index
        .split_once(" (UUID:")
        .map(|(name, _)| name)
        .unwrap_or(after_index);
    let trimmed = without_uuid.trim();
    if trimmed.is_empty() {
        line.trim().to_string()
    } else {
        trimmed.to_string()
    }
}

/// Collapse a free-form device name into one whitespace-free token.
///
/// The envelope is a space-separated `key=value` line, so a raw device name
/// ("NVIDIA RTX A5000", or an `nvidia-smi -L` line carrying a UUID in
/// parentheses) would split into extra fields and silently corrupt every key
/// after it. Bounded length keeps one long name from dominating the line.
fn slug(raw: &str) -> String {
    let mut out: String = raw
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect();
    // Collapse runs and trim, so "GPU 0: NVIDIA RTX" does not become
    // "GPU_0__NVIDIA_RTX" with meaningless doubled separators.
    while out.contains("__") {
        out = out.replace("__", "_");
    }
    let out = out.trim_matches('_').to_string();
    if out.is_empty() {
        return "-".to_string();
    }
    out.chars().take(48).collect()
}

#[cfg(test)]
mod inference_container_resolution_tests {
    use super::*;

    /// The override is taken VERBATIM, never probed. 967-6ax6: probing an
    /// explicit name would collapse "you named the wrong one" into "there is
    /// none", which is the exact conflation that made a working lane report the
    /// bottom of the scale.
    #[test]
    fn an_explicit_name_is_honoured_as_given() {
        assert_eq!(
            inference_container_override(Some("tillandsias-dev-inference")),
            Some("tillandsias-dev-inference".to_string())
        );
        // Surrounding whitespace is a shell artefact, not part of a name.
        assert_eq!(
            inference_container_override(Some("  tillandsias-inference \n")),
            Some("tillandsias-inference".to_string())
        );
    }

    /// NEGATIVE CONTROL. Blank is not a name.
    ///
    /// This is DEFENSIVE, not a defect observed in the tree: today
    /// `dev-inference-ensure.sh` writes
    /// `export TILLANDSIAS_INFERENCE_CONTAINER="${…:-$DEV_CONTAINER}"`, which
    /// always carries a real name. The hazard is that an exported-but-empty
    /// variable arrives as `Some("")` rather than `None`, so any future caller
    /// that exports the bare `"${X:-}"` shape would make the probe exec into
    /// `""`, find nothing, and report `accel_proof=-` on a working host —
    /// reintroducing 967-6ax6's silent under-claim through the very hook added
    /// to fix it. Cheap to hold; the failure it prevents is invisible.
    #[test]
    fn blank_is_not_an_override_and_falls_through_to_the_candidates() {
        for raw in [None, Some(""), Some("   "), Some("\t\n")] {
            assert_eq!(
                inference_container_override(raw),
                None,
                "blank override {raw:?} must fall through, not name an empty container"
            );
        }
    }

    /// The compiled candidates must contain the name the dev lane creates.
    /// `scripts/check-inference-container-name-agreement.sh` ratchets this
    /// across the language boundary; this pins the Rust half so a rename here
    /// fails in the crate's own tests too, not only in the shell guard.
    #[test]
    fn candidates_include_both_the_product_and_dev_lane_containers() {
        assert!(
            INFERENCE_CONTAINER_CANDIDATES.contains(&"tillandsias-inference"),
            "the product container must remain a candidate"
        );
        assert!(
            INFERENCE_CONTAINER_CANDIDATES.contains(&"tillandsias-dev-inference"),
            "the dev lane's container must remain a candidate — dropping it is \
             precisely the 967-6ax6 defect, and it fails SILENTLY"
        );
    }
}

#[cfg(test)]
mod tests {

    /// YOGA'S SECOND REFINEMENT, pinned as a rule rather than a comment: a stat
    /// proves the DEVICE is reachable; only PLACEMENT proves a lane.
    ///
    /// Their measured case is the reason this rung exists — real AMD hardware,
    /// real render node, correct PCI ids, /dev/kfd and /dev/dri/renderD128
    /// stat-able INSIDE the container, and size_vram still 0.00GB with decode
    /// unchanged at 12.2 tok/s. Every signal short of placement said yes.
    #[cfg(target_os = "linux")]
    #[test]
    fn only_placement_proves_a_lane_reachable_is_not_enough() {
        assert!(!super::Proof::Enumerated.proves_a_lane());
        assert!(
            !super::Proof::Reachable.proves_a_lane(),
            "REACHABLE MUST NOT PROVE A LANE — yoga's host had device nodes in \
             the container and size_vram=0; this is the exact assertion that \
             stops the next reader treating a successful stat as a working lane"
        );
        assert!(super::Proof::Placed.proves_a_lane());
        // The rungs are ordered, so a future caller can ask "at least
        // Reachable" for diagnosis without that ordering implying a lane.
        assert!(super::Proof::Enumerated < super::Proof::Reachable);
        assert!(super::Proof::Reachable < super::Proof::Placed);
    }

    /// 793-zumy REMAINING 2, first half: the Reachable rung now has a producer,
    /// and the rule that makes it mean anything is the vantage restriction.
    ///
    /// Four arms, three of them negative, because a producer that only ever
    /// upgrades is indistinguishable from one that ignores its inputs.
    #[test]
    fn reachable_upgrades_only_from_container_vantage_and_only_when_the_node_exists() {
        use super::{DrmRenderNode, Proof, Vantage};
        let dir = std::env::temp_dir().join(format!("tz-reach-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        std::fs::write(dir.join("renderD128"), b"").expect("node");

        let mk = |node: &str, vantage| DrmRenderNode {
            node: node.to_string(),
            vendor_id: 0x1002,
            device_id: 0x1114,
            driver: "amdgpu".to_string(),
            vantage,
            proof: Proof::Enumerated,
        };

        // ARM 1 — container vantage, node present: UPGRADES.
        let mut a = vec![mk("renderD128", Vantage::Container)];
        assert_eq!(super::upgrade_reachable_at(&mut a, &dir), 1);
        assert_eq!(a[0].proof, Proof::Reachable);

        // ARM 2 — HOST vantage, same node present: STAYS Enumerated. A host stat
        // is not weak evidence for the container lane, it is evidence about a
        // different question.
        let mut b = vec![mk("renderD128", Vantage::Host)];
        assert_eq!(super::upgrade_reachable_at(&mut b, &dir), 0);
        assert_eq!(
            b[0].proof,
            Proof::Enumerated,
            "a host-vantage stat must never claim the container lane's rung"
        );

        // ARM 3 — container vantage, node ABSENT: stays Enumerated.
        let mut c = vec![mk("renderD129", Vantage::Container)];
        assert_eq!(super::upgrade_reachable_at(&mut c, &dir), 0);
        assert_eq!(c[0].proof, Proof::Enumerated);

        // ARM 4 — never downgrades: a node already Placed stays Placed even
        // though this function only ever knows how to reach Reachable.
        let mut d = vec![mk("renderD128", Vantage::Container)];
        d[0].proof = Proof::Placed;
        assert_eq!(super::upgrade_reachable_at(&mut d, &dir), 0);
        assert_eq!(d[0].proof, Proof::Placed);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 793-zumy REMAINING 2, second half. Five arms, four negative, because the
    /// rung that proves a lane is the one where a wrong upgrade costs most.
    #[test]
    fn placed_upgrades_only_on_unambiguous_attribution() {
        use super::{DrmRenderNode, Proof, Vantage};
        let mk = |node: &str, proof| DrmRenderNode {
            node: node.to_string(),
            vendor_id: 0x1002,
            device_id: 0x1114,
            driver: "amdgpu".to_string(),
            vantage: Vantage::Container,
            proof,
        };

        // ARM 1 — one reachable node, non-zero residency: UPGRADES.
        let mut a = vec![mk("renderD128", Proof::Reachable)];
        assert_eq!(super::upgrade_placed(&mut a, 572_228_893), Some(0));
        assert_eq!(a[0].proof, Proof::Placed);

        // ARM 2 — residency ZERO: nothing. This is exactly where yoga's host sat
        // with the device statted and size_vram still 0.
        let mut b = vec![mk("renderD128", Proof::Reachable)];
        assert_eq!(super::upgrade_placed(&mut b, 0), None);
        assert_eq!(b[0].proof, Proof::Reachable);

        // ARM 3 — TWO reachable nodes: refuses. /api/ps reports per MODEL, not
        // per DEVICE, so attributing to one of two would be a guess wearing the
        // only rung that proves a lane.
        let mut c = vec![
            mk("renderD128", Proof::Reachable),
            mk("renderD129", Proof::Reachable),
        ];
        assert_eq!(super::upgrade_placed(&mut c, 572_228_893), None);
        assert!(c.iter().all(|n| n.proof == Proof::Reachable));

        // ARM 4 — only ENUMERATED nodes: refuses. A runtime cannot have placed
        // weights on a device the work's vantage cannot stat.
        let mut d2 = vec![mk("renderD128", Proof::Enumerated)];
        assert_eq!(super::upgrade_placed(&mut d2, 572_228_893), None);
        assert_eq!(d2[0].proof, Proof::Enumerated);

        // ARM 5 — one reachable among unreachable siblings: the enumerated ones
        // are not candidates, so attribution stays unambiguous and it upgrades.
        let mut e = vec![
            mk("renderD128", Proof::Enumerated),
            mk("renderD129", Proof::Reachable),
        ];
        assert_eq!(super::upgrade_placed(&mut e, 1), Some(1));
        assert_eq!(e[1].proof, Proof::Placed);
        assert_eq!(e[0].proof, Proof::Enumerated);
    }

    /// The container blob the producer parses, as one fixture the arms share.
    ///
    /// Shaped exactly like [`super::CONTAINER_PROOF_SH`]'s output: TAB-separated,
    /// `DRM` rows carrying the four sysfs reads and `DEV` rows the `/dev/dri`
    /// listing. Written out here rather than generated, so a change to the shell
    /// that broke the contract would leave this fixture disagreeing with it
    /// instead of silently following it.
    /// Field values carry NO trailing newline, matching the shell: `$(cat ...)`
    /// strips them, so a fixture that kept sysfs's newline would model a blob
    /// the container never sends and split every row across two lines.
    fn container_blob(drm: &[(&str, &str, &str, &str)], dev: &[&str]) -> String {
        let mut out = String::new();
        for (n, v, d, dr) in drm {
            out.push_str(&format!("DRM\t{n}\t{v}\t{d}\t{dr}\n"));
        }
        for e in dev {
            out.push_str(&format!("DEV\t{e}\n"));
        }
        out
    }

    /// 793-zumy REMAINING 2. The transport parses, and it claims the bottom rung
    /// and nothing more - reading four files sees hardware, never access.
    #[test]
    fn the_container_transport_parses_and_claims_only_the_enumerated_rung() {
        let blob = container_blob(
            &[("renderD128", "0x1002", "0x1114", "amdgpu")],
            &["card1", "renderD128"],
        );
        let (nodes, dev) = super::parse_container_proof_output(&blob, super::Vantage::Container);
        assert_eq!(nodes.len(), 1);
        assert_eq!(nodes[0].node, "renderD128");
        assert_eq!(nodes[0].vendor_id, 0x1002);
        assert_eq!(nodes[0].device_id, 0x1114);
        assert_eq!(nodes[0].driver, "amdgpu");
        assert_eq!(nodes[0].vantage, super::Vantage::Container);
        assert_eq!(
            nodes[0].proof,
            super::Proof::Enumerated,
            "catting sysfs from inside a container still only sees hardware"
        );
        assert_eq!(dev, vec!["card1".to_string(), "renderD128".to_string()]);
    }

    /// A TRUNCATED blob yields fewer nodes, never a node with invented fields.
    /// The identity rule is [`super::assemble_render_node`]'s and this pins that
    /// the transport did not quietly acquire its own.
    #[test]
    fn the_container_transport_skips_rows_it_cannot_identify() {
        let blob = concat!(
            "DRM\trenderD128\t0x1002\t0x1114\tamdgpu\n",
            "DRM\trenderD129\t\t0x1114\tamdgpu\n", // unreadable vendor
            "DRM\trenderD130\t0x1002\tnothex\tamdgpu\n", // unparseable device
            "DRM\trenderD131\t0x1002\n",           // truncated mid-row
            "garbage\n",
            "DEV\t\n",
        );
        let (nodes, dev) = super::parse_container_proof_output(blob, super::Vantage::Container);
        assert_eq!(
            nodes.iter().map(|n| n.node.as_str()).collect::<Vec<_>>(),
            vec!["renderD128"],
            "a record claiming vendor 0x0000 is still a claim"
        );
        assert!(dev.is_empty());
    }

    /// The listing-based Reachable upgrade obeys the SAME rules as the
    /// filesystem one: container vantage only, only nodes the listing names,
    /// never a downgrade. Four arms, three negative.
    #[test]
    fn reachable_from_a_listing_obeys_the_same_rules_as_the_filesystem_stat() {
        use super::{DrmRenderNode, Proof, Vantage};
        let mk = |node: &str, vantage, proof| DrmRenderNode {
            node: node.to_string(),
            vendor_id: 0x1002,
            device_id: 0x1114,
            driver: "amdgpu".to_string(),
            vantage,
            proof,
        };
        let listing = vec!["card1".to_string(), "renderD128".to_string()];

        // ARM 1 - container vantage, node listed: UPGRADES.
        let mut a = vec![mk("renderD128", Vantage::Container, Proof::Enumerated)];
        assert_eq!(super::upgrade_reachable_from_listing(&mut a, &listing), 1);
        assert_eq!(a[0].proof, Proof::Reachable);

        // ARM 2 - HOST vantage, same node listed: stays Enumerated.
        let mut b = vec![mk("renderD128", Vantage::Host, Proof::Enumerated)];
        assert_eq!(super::upgrade_reachable_from_listing(&mut b, &listing), 0);
        assert_eq!(
            b[0].proof,
            Proof::Enumerated,
            "a host-vantage record must never claim the container lane's rung"
        );

        // ARM 3 - container vantage, node NOT in the listing: stays Enumerated.
        // This is the /dev/dri-not-passed case, which is the whole point.
        let mut c = vec![mk("renderD129", Vantage::Container, Proof::Enumerated)];
        assert_eq!(super::upgrade_reachable_from_listing(&mut c, &listing), 0);
        assert_eq!(c[0].proof, Proof::Enumerated);

        // ARM 4 - never downgrades.
        let mut d = vec![mk("renderD128", Vantage::Container, Proof::Placed)];
        assert_eq!(super::upgrade_reachable_from_listing(&mut d, &listing), 0);
        assert_eq!(d[0].proof, Proof::Placed);
    }

    /// UNKNOWN AND ZERO ARE DIFFERENT FACTS. `upgrade_placed` treats zero as a
    /// definite refusal, so a parser that reported an unanswerable question as
    /// zero would be an affirmative denial derived from a failed question.
    #[test]
    fn residency_reports_unknown_and_zero_as_different_answers() {
        // A real two-model /api/ps body, one offloaded and one not.
        let body = r#"{"models":[
            {"name":"qwen2.5:3b","size":2000000000,"size_vram":572228893},
            {"name":"nomic-embed-text","size":300000000,"size_vram":0}]}"#;
        assert_eq!(super::parse_ollama_resident_bytes(body), Some(572_228_893));

        // Nothing resident on any accelerator: a definite ZERO. This is exactly
        // where yoga's gfx1152 host sat with the device statted.
        let zero = r#"{"models":[{"name":"qwen2.5:3b","size_vram":0}]}"#;
        assert_eq!(super::parse_ollama_resident_bytes(zero), Some(0));

        // No models loaded at all is still an ANSWER: zero.
        assert_eq!(
            super::parse_ollama_resident_bytes(r#"{"models":[]}"#),
            Some(0)
        );

        // A CPU-resident model omits size_vram entirely; it contributes 0
        // rather than poisoning the sum.
        assert_eq!(
            super::parse_ollama_resident_bytes(r#"{"models":[{"name":"x"}]}"#),
            Some(0)
        );

        // UNKNOWN: not JSON, or no `models` key at all. Never Some(0).
        assert_eq!(super::parse_ollama_resident_bytes("not json"), None);
        assert_eq!(super::parse_ollama_resident_bytes("{}"), None);
        assert_eq!(super::parse_ollama_resident_bytes(r#"{"models":{}}"#), None);
    }

    /// 793-zumy REMAINING 2, THE PACKET'S OWN CRITERION: the rungs are no longer
    /// inert. Five arms over the composition, because "something produces
    /// Reachable and Placed" is the claim being made and every way it could be
    /// vacuously true is a way this test could pass while the fix does not
    /// exist.
    #[test]
    fn the_producer_actually_emits_reachable_and_placed() {
        use super::Proof;
        let blob = container_blob(
            &[("renderD128", "0x1002", "0x1114", "amdgpu")],
            &["card1", "renderD128"],
        );
        let ps = r#"{"models":[{"name":"qwen2.5:3b","size_vram":572228893}]}"#;

        // ARM 1 - device passed in AND a runtime with weights on it: PLACED.
        // The rung that proves a lane, produced end to end.
        let placed =
            super::produce_container_proofs_with(|| Some(blob.clone()), || Some(ps.to_string()));
        assert_eq!(placed.len(), 1);
        assert_eq!(placed[0].proof, Proof::Placed);
        assert!(placed[0].proof.proves_a_lane());

        // ARM 2 - YOGA'S MEASURED STATE, and the one that must not inflate:
        // device nodes stat-able inside the container, size_vram still 0 because
        // the image ships no runtime that can drive them. REACHABLE, not Placed.
        let reachable = super::produce_container_proofs_with(
            || Some(blob.clone()),
            || Some(r#"{"models":[{"name":"q","size_vram":0}]}"#.to_string()),
        );
        assert_eq!(reachable[0].proof, Proof::Reachable);
        assert!(
            !reachable[0].proof.proves_a_lane(),
            "reachable is necessary and NOT sufficient"
        );

        // ARM 3 - hardware enumerates but /dev/dri was never passed in: the
        // bottom rung, and the runtime is not even asked.
        let mut asked = false;
        let enumerated = super::produce_container_proofs_with(
            || {
                Some(container_blob(
                    &[("renderD128", "0x1002", "0x1114", "amdgpu")],
                    &[],
                ))
            },
            || {
                asked = true;
                Some(ps.to_string())
            },
        );
        assert_eq!(enumerated[0].proof, Proof::Enumerated);
        assert!(
            !asked,
            "with no reachable node the residency answer cannot change a rung"
        );

        // ARM 4 - the runtime could not be asked at all. UNKNOWN residency must
        // leave the node where it was, never inflate and never downgrade.
        let unknown = super::produce_container_proofs_with(|| Some(blob.clone()), || None);
        assert_eq!(unknown[0].proof, Proof::Reachable);

        // ARM 5 - no container to ask: an EMPTY vec, never a fabricated row.
        let none = super::produce_container_proofs_with(|| None, || Some(ps.to_string()));
        assert!(none.is_empty());
    }

    /// The produced rung REACHES A CONSUMER. Without this the producers would be
    /// as inert as the model was: something computes a rung and nothing can see
    /// it. Also pins `-` for "nobody asked", which must stay distinct from
    /// `enumerated`.
    #[test]
    fn the_envelope_carries_the_highest_produced_rung() {
        use super::{DrmRenderNode, Proof, Vantage};
        let mk = |node: &str, proof| DrmRenderNode {
            node: node.to_string(),
            vendor_id: 0x1002,
            device_id: 0x1114,
            driver: "amdgpu".to_string(),
            vantage: Vantage::Container,
            proof,
        };
        let mut doc = doc_with(Vec::new());

        // ASKED AND FOUND NOTHING. A container lane was present and had no
        // render node to offer: a finding.
        assert!(
            super::accel_envelope(&doc).contains("accel_proof=none"),
            "a probed container lane with no nodes is a finding"
        );

        // NOBODY TO ASK. Yoga measured these two collapsed on 2026-09-02 and a
        // host whose container lane was WORKING read identically to one with no
        // accelerator at all — silent, and under-claiming.
        doc.enumeration_gaps.push("container-lane".to_string());
        assert!(
            super::accel_envelope(&doc).contains("accel_proof=unknown"),
            "no container to ask is a gap, not an affirmative denial"
        );
        doc.enumeration_gaps.clear();

        // The HIGHEST rung wins, not the first node's.
        doc.render_nodes = vec![
            mk("renderD128", Proof::Enumerated),
            mk("renderD129", Proof::Placed),
        ];
        assert!(super::accel_envelope(&doc).contains("accel_proof=placed"));

        doc.render_nodes = vec![mk("renderD128", Proof::Reachable)];
        let env = super::accel_envelope(&doc);
        assert!(env.contains("accel_proof=reachable"));
        // APPENDED, never inserted: every existing grep/sed consumer reads the
        // keys before it at the offsets it has always read them at.
        assert!(
            env.find("accel_ram_gb=").unwrap() < env.find("accel_proof=").unwrap(),
            "accel_proof must stay the last key"
        );
    }

    /// A sysfs walk may claim ONLY the bottom rung. It cannot see a container's
    /// device list and cannot see size_vram, so any higher claim would be the
    /// substitution this packet exists to end.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_sysfs_enumeration_claims_only_the_enumerated_rung() {
        let root = drm_fixture(&[("renderD128", "0x1002\n", "0x1638\n", "amdgpu")]);
        let nodes = super::enumerate_render_nodes_at(&root, super::Vantage::Host);
        assert_eq!(nodes[0].proof, super::Proof::Enumerated);
        assert!(
            !nodes[0].proof.proves_a_lane(),
            "an enumeration must never advertise a lane"
        );
        // Even asked from the container's vantage, a sysfs walk is still only
        // an enumeration — the vantage improves WHERE, not HOW FAR.
        let inside = super::enumerate_render_nodes_at(&root, super::Vantage::Container);
        assert_eq!(inside[0].vantage.token(), "container");
        assert_eq!(
            inside[0].proof,
            super::Proof::Enumerated,
            "vantage and proof are independent axes; a better vantage is not a higher rung"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// ORDER 793-zumy. Fixture trees, never the real /sys — a test that read
    /// this machine would assert whatever it happens to be, which is the
    /// vacuous-green shape yolanda caught on this very packet: a test that
    /// built its own fixture, never touched production, and stayed GREEN when
    /// production was reverted to a wrong value.
    #[cfg(target_os = "linux")]
    fn drm_fixture(spec: &[(&str, &str, &str, &str)]) -> std::path::PathBuf {
        // Key the root on a per-call sequence, NOT on spec.len(): every test
        // in this binary shares one process, so (pid, len) collides for any
        // two tests with same-sized specs — the first line below then deletes
        // the sibling's live fixture, and which victim loses depends on
        // thread interleaving. Latent until 2026-09-01, when an unrelated
        // +1 test shifted the schedule and made the collision deterministic.
        static FIXTURE_SEQ: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let seq = FIXTURE_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!("drm-fixture-{}-{}", std::process::id(), seq));
        let _ = std::fs::remove_dir_all(&root);
        for (node, vendor, device, driver) in spec {
            let dev = root.join(node).join("device");
            std::fs::create_dir_all(&dev).unwrap();
            std::fs::write(dev.join("vendor"), vendor).unwrap();
            std::fs::write(dev.join("device"), device).unwrap();
            if !driver.is_empty() {
                let drv = root.join("drivers").join(driver);
                std::fs::create_dir_all(&drv).unwrap();
                let _ = std::os::unix::fs::symlink(&drv, dev.join("driver"));
            }
        }
        root
    }

    /// THE ENUMERATION GAP 793-zumy WAS FILED AGAINST. `/dev/dri exists` is one
    /// bit and cannot represent two GPUs. This is lenovinha's real hardware,
    /// measured 2026-08-30 — the fleet's only dual-vendor fixture.
    #[cfg(target_os = "linux")]
    #[test]
    fn enumeration_represents_two_gpus_where_file_existence_cannot() {
        let root = drm_fixture(&[
            ("renderD128", "0x1002\n", "0x1638\n", "amdgpu"),
            ("renderD129", "0x10de\n", "0x24dd\n", "nvidia"),
        ]);
        let nodes = super::enumerate_render_nodes_at(&root, super::Vantage::Host);
        assert_eq!(nodes.len(), 2, "two render nodes must yield two records");
        assert_eq!(nodes[0].vendor(), "amd");
        assert_eq!(nodes[0].driver, "amdgpu");
        assert_eq!(nodes[1].vendor(), "nvidia");
        assert_eq!(nodes[1].driver, "nvidia");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// EXIT CRITERION 3, SATISFIED STRUCTURALLY RATHER THAN BY A BLOCKLIST.
    /// lavapipe/llvmpipe are USERSPACE-ONLY Vulkan ICDs: they create no DRM
    /// render node, so an enumeration of render nodes cannot see them at all.
    /// A host with Mesa's full ICD set installed and no GPU enumerates ZERO —
    /// which is why no driver-name blocklist is needed, and why this cannot rot
    /// when a new software rasterizer appears.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_software_rasterizer_cannot_satisfy_the_gpu_check() {
        let root = drm_fixture(&[]);
        std::fs::create_dir_all(&root).unwrap();
        let nodes = super::enumerate_render_nodes_at(&root, super::Vantage::Host);
        assert!(
            nodes.is_empty(),
            "a tree with no render node must enumerate nothing — llvmpipe has no node to find"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A NODE WHOSE IDENTITY CANNOT BE READ IS SKIPPED, NOT DEFAULTED. A record
    /// claiming vendor 0x0000 is still a claim, and the whole packet is about
    /// not making claims the evidence does not support.
    #[cfg(target_os = "linux")]
    #[test]
    fn an_unreadable_node_is_skipped_rather_than_reported_as_vendor_zero() {
        let root = std::env::temp_dir().join(format!("drm-partial-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("renderD128").join("device")).unwrap();
        // vendor present, device absent
        std::fs::write(root.join("renderD128/device/vendor"), "0x10de\n").unwrap();
        let nodes = super::enumerate_render_nodes_at(&root, super::Vantage::Host);
        assert!(
            nodes.is_empty(),
            "a half-readable node must not become a record"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// YOGA'S TIGHTENING, pinned: a record carries WHERE it was observed, and a
    /// host enumeration must never read as a container-lane claim. Their
    /// machine reported accel_gpu=usable from the host while the container had
    /// no /dev/kfd, no /dev/dri and size_vram=0 on every model — both true, and
    /// nothing distinguished them.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_record_carries_the_vantage_it_was_observed_from() {
        let root = drm_fixture(&[("renderD128", "0x1002\n", "0x1638\n", "amdgpu")]);
        let host = super::enumerate_render_nodes_at(&root, super::Vantage::Host);
        assert_eq!(host[0].vantage.token(), "host");
        let inside = super::enumerate_render_nodes_at(&root, super::Vantage::Container);
        assert_eq!(inside[0].vantage.token(), "container");
        assert_ne!(
            super::Vantage::Host,
            super::Vantage::Container,
            "the two vantages must not be interchangeable"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// LIVE, on whatever this host is. Deliberately NOT an assertion about
    /// lenovinha's hardware — it asserts an INVARIANT that must hold on every
    /// host: whatever enumerates, its identity is readable and its vantage is
    /// host. On a machine with no GPU it passes vacuously, which is correct.
    #[cfg(target_os = "linux")]
    #[test]
    fn live_enumeration_is_self_consistent_on_whatever_host_this_is() {
        let nodes = super::enumerate_render_nodes_at(
            std::path::Path::new("/sys/class/drm"),
            super::Vantage::Host,
        );
        for n in &nodes {
            assert_ne!(n.vendor_id, 0, "a reported node must have a real vendor id");
            assert!(!n.node.is_empty());
            assert_eq!(n.vantage.token(), "host");
        }
        eprintln!(
            "[793-zumy] live enumeration on this host: {} node(s)",
            nodes.len()
        );
        for n in &nodes {
            eprintln!(
                "  {} vendor={} (0x{:04x}) device=0x{:04x} driver={} vantage={}",
                n.node,
                n.vendor(),
                n.vendor_id,
                n.device_id,
                n.driver,
                n.vantage.token()
            );
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn pci_ids_parse_with_and_without_the_prefix_and_reject_garbage() {
        assert_eq!(super::parse_pci_id("0x10de\n"), Some(0x10de));
        assert_eq!(super::parse_pci_id("1002"), Some(0x1002));
        assert_eq!(super::parse_pci_id(""), None);
        assert_eq!(super::parse_pci_id("not-a-number"), None);
    }

    /// A VULKAN vendorID IS NOT A PCI ID, and this pins the consequence rather
    /// than the intention. lavapipe/llvmpipe reports 0x10005 — Khronos-assigned,
    /// uint32_t, deliberately outside the PCI range — and it does not fit a
    /// u16, so this parser returns None and the `?` in the caller drops the
    /// whole node. A dropped row and a device that never enumerated are the
    /// same record, so reusing this parser for Vulkan would turn the EXPLICIT
    /// software-rasterizer rejection 793-zumy criterion 2 asks for into a
    /// silent disappearance.
    ///
    /// This test does not argue that; it makes the boundary executable, so a
    /// future Vulkan field that reaches for the nearest parser that compiles
    /// has to read this first. The fix when that day comes is a separate u32
    /// field with its own parser, never a widening of this one.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_vulkan_vendor_id_does_not_fit_a_pci_id_and_must_not_be_parsed_as_one() {
        // Not a PCI id: 0x10005 is 65541, one namespace over and 6 past u16::MAX.
        assert_eq!(super::parse_pci_id("0x10005"), None);
        assert_eq!(super::parse_pci_id("0x10000"), None);
        // The last value that IS a PCI id, so the boundary is pinned on both
        // sides and a widened type would red this pair, not just the one above.
        assert_eq!(super::parse_pci_id("0xffff"), Some(0xffff));
    }

    /// ORDER 935-jhh5. The old `cdi_ok = effective_tier == "gpu-cuda"` was
    /// CIRCULAR — the tier derives from the same `nvidia-smi` the caller already
    /// ran — so it could never report a missing spec on a host with a working
    /// driver. These pin the replacement against real spec SHAPES, using a
    /// temp dir rather than this machine's state, because on a host where CDI
    /// already works BOTH the broken and the fixed check answer true and a test
    /// that read the live filesystem would pass either way.
    #[cfg(target_os = "linux")]
    #[test]
    fn cdi_deliverable_requires_a_device_node_not_merely_the_kind() {
        use std::io::Write;
        let dir = std::env::temp_dir().join(format!("cdi-probe-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let write = |name: &str, body: &str| {
            let p = dir.join(name);
            let mut f = std::fs::File::create(&p).unwrap();
            f.write_all(body.as_bytes()).unwrap();
            p
        };

        // Names the kind but declares no node: cannot deliver a GPU.
        let bare = write(
            "bare.yaml",
            "kind: nvidia.com/gpu\ndevices:\n  - name: all\n",
        );
        assert!(
            !super::spec_file_delivers_nvidia(&bare),
            "a spec with no /dev/nvidiaN node must not count as deliverable"
        );

        // The shape a bad --dev-root produced here: the node exists but under a
        // self-referential prefix, so it lands at the wrong in-container path
        // and the inference entrypoint's `[ -e /dev/nvidia0 ]` finds nothing.
        let prefixed = write(
            "prefixed.yaml",
            "kind: nvidia.com/gpu\ndevices:\n  - name: all\n    deviceNodes:\n      - path: /run/host/dev/nvidia0\n",
        );
        assert!(
            !super::spec_file_delivers_nvidia(&prefixed),
            "a /run/host-prefixed node lands at the wrong container path — not deliverable"
        );

        // The good shape.
        let good = write(
            "good.yaml",
            "kind: nvidia.com/gpu\ndevices:\n  - name: all\n    deviceNodes:\n      - path: /dev/nvidia0\n",
        );
        assert!(
            super::spec_file_delivers_nvidia(&good),
            "a spec naming the kind and a real /dev/nvidia0 IS deliverable"
        );

        // A spec for someone else's device must not answer for NVIDIA.
        let other = write(
            "other.yaml",
            "kind: amd.com/gpu\ndevices:\n  - name: all\n    deviceNodes:\n      - path: /dev/dri/card0\n",
        );
        assert!(!super::spec_file_delivers_nvidia(&other));

        let _ = std::fs::remove_dir_all(&dir);
    }
    use super::*;

    /// ORDER 880-tdwn: pin the podman seam to /bin/false for a test's
    /// lifetime, under a module lock, restoring the prior value on drop.
    /// `run_probe` reaches `inference_image_present()` → real podman
    /// resolution; /bin/false makes that read a deterministic "no image"
    /// (the function's own documented degraded answer) instead of a
    /// live-daemon read — or, under the CI tripwire, a panic. Every test
    /// that walks run_probe MUST hold this guard.
    fn podman_seam() -> PodmanSeamGuard {
        // CANONICAL lock, not a private one. A module-local mutex here
        // serialised this module against itself and against nothing else,
        // while main.rs's fake-podman fixtures wrote the same var under a
        // different mutex.
        let lock = crate::runtime_assets::podman_seam_lock();
        // ALSO the env lock, seam-then-env, because this write is an env
        // mutation like any other: `remote_projects` repoints the same var
        // holding only `env_lock`, so the seam lock alone excludes main.rs's
        // fixtures and NOT that module. Both guards, or the gap just moves.
        let env = crate::runtime_assets::env_lock();
        let prev = std::env::var_os("TILLANDSIAS_PODMAN_BIN");
        unsafe { std::env::set_var("TILLANDSIAS_PODMAN_BIN", "/bin/false") };
        PodmanSeamGuard {
            _lock: lock,
            _env: env,
            prev,
        }
    }
    struct PodmanSeamGuard {
        _lock: std::sync::MutexGuard<'static, ()>,
        _env: std::sync::MutexGuard<'static, ()>,
        prev: Option<std::ffi::OsString>,
    }
    impl Drop for PodmanSeamGuard {
        fn drop(&mut self) {
            unsafe {
                match self.prev.take() {
                    Some(v) => std::env::set_var("TILLANDSIAS_PODMAN_BIN", v),
                    None => std::env::remove_var("TILLANDSIAS_PODMAN_BIN"),
                }
            }
        }
    }

    /// Build a document with exactly the devices a case needs.
    /// ORDER 1254-47xd. Build the exact contradiction yoga measured: a render
    /// node proven from inside a container, beside the GPU whose node it is,
    /// still recorded as having no container lane.
    fn node(name: &str, vantage: super::Vantage, proof: super::Proof) -> super::DrmRenderNode {
        super::DrmRenderNode {
            node: name.to_string(),
            vendor_id: 0x1002,
            device_id: 0x1114,
            driver: "amdgpu".to_string(),
            vantage,
            proof,
        }
    }

    fn gpu_at(node_path: &str) -> DeviceRecord {
        let mut d = device(
            "gpu",
            "Krackan [Radeon 840M / 860M Graphics]",
            &["host-native"],
            Some("container-lane-unverified"),
        );
        d.device_node = Some(node_path.to_string());
        d
    }

    /// EXIT CRITERION 1. Pre-fix this failed on yoga with `proof=placed`
    /// sitting beside `lanes ["host-native"]` in the SAME document.
    #[test]
    fn a_proven_container_node_reaches_the_device_record() {
        let mut doc = doc_with(vec![gpu_at("/dev/dri/renderD128")]);
        doc.render_nodes = vec![node(
            "renderD128",
            super::Vantage::Container,
            super::Proof::Placed,
        )];

        super::promote_proven_container_lanes(&mut doc);

        let gpu = &doc.devices[0];
        assert!(
            gpu.lanes.iter().any(|l| l == "container"),
            "a container-vantage placement on this device's own node must reach its lanes: {:?}",
            gpu.lanes
        );
        assert_eq!(
            gpu.unusable_reason, None,
            "the reason named exactly this gap; leaving it beside a container lane is a second \
             contradiction in the same record"
        );
        assert!(
            gpu.lanes.iter().any(|l| l == "host-native"),
            "promotion ADDS a lane and never removes host-native (this row's named unscoreable)"
        );
    }

    /// EXIT CRITERION 3, THE NEGATIVE CONTROL. Absence of proof is not proof of
    /// reach; promoting an unproven lane is the same defect pointed the other
    /// way and would route work to a host that cannot run it.
    #[test]
    fn an_unproven_container_lane_stays_unproven() {
        // Host vantage is the exact evidence 793-zumy refused to promote on.
        let mut doc = doc_with(vec![gpu_at("/dev/dri/renderD128")]);
        doc.render_nodes = vec![node(
            "renderD128",
            super::Vantage::Host,
            super::Proof::Placed,
        )];
        super::promote_proven_container_lanes(&mut doc);
        assert!(
            !doc.devices[0].lanes.iter().any(|l| l == "container"),
            "host-vantage evidence cannot support a container-lane claim"
        );
        assert_eq!(
            doc.devices[0].unusable_reason.as_deref(),
            Some("container-lane-unverified"),
            "an unpromoted device keeps the reason the disposition wrote"
        );

        // No node at all: the same answer, for the same reason.
        let mut doc = doc_with(vec![gpu_at("/dev/dri/renderD128")]);
        super::promote_proven_container_lanes(&mut doc);
        assert!(!doc.devices[0].lanes.iter().any(|l| l == "container"));

        // ANOTHER DEVICE'S PROVEN NODE IS NOT THIS DEVICE'S PROOF. Keying on
        // "a GPU exists and some node was proven" would promote this one.
        let mut doc = doc_with(vec![gpu_at("/dev/dri/renderD129")]);
        doc.render_nodes = vec![node(
            "renderD128",
            super::Vantage::Container,
            super::Proof::Placed,
        )];
        super::promote_proven_container_lanes(&mut doc);
        assert!(
            !doc.devices[0].lanes.iter().any(|l| l == "container"),
            "the proof belongs to renderD128; renderD129 was never reached"
        );
    }

    /// EXIT CRITERION 6. The vocabulary is honoured rather than collapsed, and
    /// the bar is stated: `Reachable` promotes. On yoga the field escalated
    /// reachable -> placed between two runs with NO host change, so a rule keyed
    /// on the literal `Placed` would grant and withdraw the lane as a model
    /// happened to be resident.
    #[test]
    fn reachable_promotes_and_enumerated_does_not() {
        for proof in [super::Proof::Reachable, super::Proof::Placed] {
            let mut doc = doc_with(vec![gpu_at("/dev/dri/renderD128")]);
            doc.render_nodes = vec![node("renderD128", super::Vantage::Container, proof)];
            super::promote_proven_container_lanes(&mut doc);
            assert!(
                doc.devices[0].lanes.iter().any(|l| l == "container"),
                "{proof:?} from inside a container is evidence the namespace reaches the device"
            );
        }

        // `Enumerated` says the hardware exists and NOTHING about any lane.
        let mut doc = doc_with(vec![gpu_at("/dev/dri/renderD128")]);
        doc.render_nodes = vec![node(
            "renderD128",
            super::Vantage::Container,
            super::Proof::Enumerated,
        )];
        super::promote_proven_container_lanes(&mut doc);
        assert!(
            !doc.devices[0].lanes.iter().any(|l| l == "container"),
            "enumeration is not reach"
        );
    }

    /// A DEVICE WITH A DIFFERENT COMPLAINT KEEPS IT. The promotion answers one
    /// reason and must not clear a reason it did not address — a device that is
    /// container-reachable and has no engine is still engine-missing.
    #[test]
    fn promotion_clears_only_the_reason_it_answers() {
        let mut d = gpu_at("/dev/dri/renderD128");
        d.unusable_reason = Some("engine-missing".to_string());
        let mut doc = doc_with(vec![d]);
        doc.render_nodes = vec![node(
            "renderD128",
            super::Vantage::Container,
            super::Proof::Placed,
        )];
        super::promote_proven_container_lanes(&mut doc);
        assert_eq!(
            doc.devices[0].unusable_reason.as_deref(),
            Some("engine-missing"),
            "a reason this function did not answer is not ours to clear"
        );
    }

    fn doc_with(devices: Vec<DeviceRecord>) -> CapabilityDocument {
        CapabilityDocument {
            schema_version: SCHEMA_VERSION,
            legacy_tier: "cpu".to_string(),
            probe_identity: Some(probe_identity()),
            enumeration_gaps: Vec::new(),
            hardware_fingerprint: None,
            render_nodes: Vec::new(),
            envelope_source: Some(EnvelopeSource::Measured),
            devices,
            engines: Vec::new(),
            measurements: Vec::new(),
            host: HostInfo {
                is_battery_present: Some(false),
                kernel_release: "test".to_string(),
                host_id: "test-host".to_string(),
                host_id_source: "input".to_string(),
                host_kind: "linux".to_string(),
                side: Some("native-linux".to_string()),
            },
            timestamp: "1970-01-01T00:00:00Z".to_string(),
        }
    }

    fn device(class: &str, name: &str, lanes: &[&str], reason: Option<&str>) -> DeviceRecord {
        DeviceRecord {
            device_class: class.to_string(),
            vendor: "test".to_string(),
            name: name.to_string(),
            device_node: None,
            fw_version: None,
            driver: None,
            usable: true,
            unusable_reason: reason.map(|r| r.to_string()),
            policy_unscheduled: None,
            lanes: lanes.iter().map(|l| l.to_string()).collect(),
            memory_bandwidth_gbps: None,
            memory_bandwidth_source: "unknown".to_string(),
            cpu_flags: None,
            cpu_cores: None,
            system_ram_gb: None,
            memory_model: None,
            // 1137-rgfm: None = this fixture states no provenance, so the
            // pre-field deny-list still judges it, exactly as before.
            name_source: None,
        }
    }

    fn engine(classes: &[&str], lanes: Option<&[&str]>) -> EngineRecord {
        EngineRecord {
            name: "test-engine".to_string(),
            backend: "test".to_string(),
            supported_device_classes: classes.iter().map(|c| c.to_string()).collect(),
            lanes: lanes.map(|ls| ls.iter().map(|l| l.to_string()).collect()),
        }
    }

    /// An NPU record as the enumerators now emit it: hardware found, verdict
    /// NOT decided (usable false, no reason). Both push sites produce this.
    fn undecided_npu() -> DeviceRecord {
        let mut d = device("npu", "AMD XDNA NPU", &["host-native"], None);
        d.usable = false;
        d
    }

    /// 1253-54zj ARM 1, the arm that proves the derivation is real: a host
    /// whose engines declare an npu-capable engine reads usable:true. Before
    /// the fix this was unreachable on every host, because both push sites
    /// wrote usable:false as a literal and nothing ever changed it.
    #[test]
    fn npu_with_an_npu_capable_engine_is_usable() {
        let mut devs = vec![undecided_npu()];
        derive_npu_usability(
            &mut devs,
            &[engine(&["cpu", "gpu"], None), engine(&["npu"], None)],
        );
        assert!(
            devs[0].usable,
            "an npu-capable engine must make the NPU usable"
        );
        assert_eq!(devs[0].unusable_reason, None);
    }

    /// 1253-54zj ARM 2: hardware present, only cpu/gpu engines (yoga's measured
    /// state) -> engine-missing, now DERIVED. The input record carries NO reason,
    /// so the word can only have come from the derivation; a test that checked
    /// the string on the old literal record would pass unchanged pre-fix.
    #[test]
    fn npu_without_an_npu_engine_is_engine_missing_by_derivation() {
        let mut devs = vec![undecided_npu()];
        assert_eq!(
            devs[0].unusable_reason, None,
            "precondition: the input carries no verdict"
        );
        derive_npu_usability(&mut devs, &[engine(&["cpu", "gpu"], None)]);
        assert!(!devs[0].usable);
        assert_eq!(devs[0].unusable_reason.as_deref(), Some("engine-missing"));
    }

    /// 1253-54zj ARM 3, NEGATIVE CONTROL: no NPU hardware stays `none`, even
    /// with an npu-capable engine installed. Absence must never be promoted to
    /// present-but-undriveable (the confusion gpu_engine()'s doc names).
    #[test]
    fn no_npu_hardware_reads_none_even_with_an_npu_engine() {
        let mut devs = vec![device("gpu", "GPU", &["host-native"], None)];
        let engines = vec![engine(&["npu"], None)];
        derive_npu_usability(&mut devs, &engines);
        assert!(
            devs.iter().all(|d| d.device_class != "npu"),
            "the derivation must not invent a record"
        );
        let mut doc = doc_with(devs);
        doc.engines = engines;
        let env = super::accel_envelope(&doc);
        assert!(
            env.contains("accel_npu=none"),
            "absent NPU must render none: {env}"
        );
    }

    /// 1253-54zj: the lane matters, as in phase_device_usable. An engine
    /// reachable only in the container cannot drive a host-native NPU.
    #[test]
    fn a_container_only_npu_engine_does_not_drive_a_host_native_npu() {
        let mut devs = vec![undecided_npu()];
        derive_npu_usability(&mut devs, &[engine(&["npu"], Some(&["container"]))]);
        assert!(!devs[0].usable);
        assert_eq!(devs[0].unusable_reason.as_deref(), Some("engine-missing"));
    }

    /// 1253-54zj: a health fact the OS reported (native Windows, PnP status
    /// not OK) is kept; an engine cannot make an unhealthy device usable.
    #[test]
    fn a_device_not_ok_npu_stays_unusable_with_its_health_reason() {
        let mut devs = vec![device(
            "npu",
            "NPU",
            &["host-native"],
            Some(NPU_DEVICE_NOT_OK),
        )];
        derive_npu_usability(&mut devs, &[engine(&["npu"], None)]);
        assert!(!devs[0].usable);
        assert_eq!(devs[0].unusable_reason.as_deref(), Some(NPU_DEVICE_NOT_OK));
    }

    /// 805-r98w. The fingerprint exists so two hosts can be SHOWN identical
    /// rather than asserted identical. The load-bearing arm is substrate
    /// independence: the SAME device records must hash the same however the
    /// OS, kernel, driver and lanes differ, because the substrate is the other
    /// axis of the matrix, not part of the hardware's identity.
    ///
    /// CORRECTED 2026-09-02. This arm used to name its two documents "yolanda"
    /// and "yoga" and call them "the twin pair". They are NOT twins — measured
    /// by the yoga host: Ryzen AI 5 340 / 6c12t / Radeon 840M against Ryzen AI
    /// 7 350 / 8c16t / Radeon 860M. The fleet asserted that pair was identical
    /// for weeks and this test had quietly become the assertion's last refuge.
    /// The hosts are generic here now; the real pair is the fixture of
    /// `fingerprint_separates_the_hosts_the_fleet_called_twins` below, which
    /// requires them to DIFFER.
    #[test]
    fn hardware_fingerprint_ignores_substrate_and_separates_real_hardware() {
        let gpu = |name: &str| {
            let mut d = device("gpu", name, &["host-native"], None);
            d.vendor = "amd".to_string();
            d.system_ram_gb = Some(15.2);
            d
        };

        // ARM 1 — SUBSTRATE INDEPENDENCE. Identical device records, and
        // everything the substrate owns differs: kernel, host_kind, host_id,
        // driver, usable, lanes. These must fingerprint IDENTICALLY, or a
        // same-hardware pair could never isolate the substrate.
        let mut a = doc_with(vec![gpu("AMD Radeon 860M")]);
        a.host.kernel_release = "6.18.33.2-microsoft-standard-WSL2".to_string();
        a.host.host_kind = "windows".to_string();
        a.host.host_id = "host-a".to_string();
        a.devices[0].driver = Some("amdgpu-wsl".to_string());
        a.devices[0].lanes = vec!["container".to_string()];

        let mut b = doc_with(vec![gpu("AMD Radeon 860M")]);
        b.host.kernel_release = "6.11.0-amd64".to_string();
        b.host.host_kind = "linux".to_string();
        b.host.host_id = "host-b".to_string();
        b.devices[0].driver = Some("amdgpu".to_string());
        b.devices[0].usable = false;

        assert_eq!(
            super::hardware_fingerprint(&a),
            super::hardware_fingerprint(&b),
            "the twin pair must fingerprint identically across substrates — \
             otherwise same-fingerprint rows can never isolate the substrate, \
             which is the only thing this fingerprint is for"
        );

        // ARM 2 — DIFFERENT GPU: must differ. A fingerprint that collides on
        // real hardware differences licenses the comparison it exists to gate.
        let c = doc_with(vec![gpu("NVIDIA RTX A5000")]);
        assert_ne!(
            super::hardware_fingerprint(&a),
            super::hardware_fingerprint(&c)
        );

        // ARM 3 — RAM IS BUCKETED. 15.2 and 15.9 GB are the same class; firmware
        // reservations must not split a twin pair on a number nobody chose.
        let mut d = doc_with(vec![gpu("AMD Radeon 860M")]);
        d.devices[0].system_ram_gb = Some(15.9);
        assert_eq!(
            super::hardware_fingerprint(&a),
            super::hardware_fingerprint(&d)
        );

        // ARM 4 — a genuinely different RAM class DOES separate.
        let mut e = doc_with(vec![gpu("AMD Radeon 860M")]);
        e.devices[0].system_ram_gb = Some(64.0);
        assert_ne!(
            super::hardware_fingerprint(&a),
            super::hardware_fingerprint(&e)
        );

        // ARM 5 — ENUMERATION ORDER IS NOT A PROPERTY OF THE MACHINE.
        let f = doc_with(vec![
            gpu("AMD Radeon 860M"),
            device("npu", "XDNA2", &["host-native"], None),
        ]);
        let g = doc_with(vec![
            device("npu", "XDNA2", &["host-native"], None),
            gpu("AMD Radeon 860M"),
        ]);
        assert_eq!(
            super::hardware_fingerprint(&f),
            super::hardware_fingerprint(&g),
            "device order must not change the fingerprint"
        );
    }

    /// 805-r98w, from the yoga host's measurement 2026-08-30, relayed
    /// 2026-09-02. These two machines were called a twin pair fleet-wide for
    /// weeks. They are not: different SKU, different core counts, different
    /// iGPU bin.
    ///
    /// THE TRAP THIS PINS. AMD ships the Radeon 840M and the 860M under ONE
    /// PCI name, "Krackan [Radeon 840M / 860M Graphics]", so the GPU model
    /// string is IDENTICAL on both hosts and a fingerprint resting on it would
    /// bless a false twin — and every accel number keyed on that control would
    /// have silently inherited a hardware difference. The CPU fields are what
    /// actually separate them. `scripts/hardware-fingerprint.sh` documents the
    /// same trap; this is the Rust side of it.
    #[test]
    fn fingerprint_separates_the_hosts_the_fleet_called_twins() {
        let host = |cpu_name: &str, phys: u32, log: u32| {
            let mut c = device("cpu", cpu_name, &["host-native"], None);
            c.vendor = "amd".to_string();
            c.cpu_cores = Some(CpuCores {
                physical: phys,
                logical: log,
            });
            c.system_ram_gb = Some(15.2);
            // The SHARED, deceiving string: one PCI name for both bins.
            let mut g = device(
                "gpu",
                "Krackan [Radeon 840M / 860M Graphics]",
                &["host-native"],
                None,
            );
            g.vendor = "amd".to_string();
            doc_with(vec![c, g])
        };

        let yoga = host("AMD Ryzen AI 5 340 w/ Radeon 840M", 6, 12);
        let yolanda = host("AMD Ryzen AI 7 350 w/ Radeon 860M", 8, 16);

        assert_ne!(
            super::hardware_fingerprint(&yoga),
            super::hardware_fingerprint(&yolanda),
            "these hosts differ in SKU and core count; a fingerprint that collides on them blesses a false substrate control"
        );

        // CONTROL — the trap is real, not hypothetical. Strip the CPU records
        // and the two documents become indistinguishable, because everything
        // that remains is the shared PCI name. This is what a GPU-keyed
        // fingerprint would have done, and it pins WHICH fields the assertion
        // above is resting on: without it, that assert_ne could pass for a
        // reason unrelated to the CPU.
        let gpu_only = |d: &CapabilityDocument| {
            let mut x = d.clone();
            x.devices.retain(|dev| dev.device_class == "gpu");
            super::hardware_fingerprint(&x)
        };
        assert_eq!(
            gpu_only(&yoga),
            gpu_only(&yolanda),
            "control failed: the GPU name was expected to be identical on both              hosts — if this ever differs, AMD split the PCI name and the              comment above needs revisiting"
        );
    }

    /// 805-r98w. The comparison rule, single-implementation, so the shell's
    /// `compare` mode calls it rather than restating it.
    #[test]
    fn comparison_refuses_cross_vantage_and_carries_no_verdict() {
        let machine = |kind: &str| {
            let mut c = device(
                "cpu",
                "AMD Ryzen AI 7 350 w/ Radeon 860M",
                &["host-native"],
                None,
            );
            c.vendor = "amd".to_string();
            c.cpu_cores = Some(CpuCores {
                physical: 8,
                logical: 16,
            });
            c.system_ram_gb = Some(15.2);
            let mut d = doc_with(vec![c]);
            d.host.host_kind = kind.to_string();
            d
        };

        // Same records, different vantage: MUST refuse, not report "same".
        // Reporting equality here would be as wrong as reporting difference —
        // the documents are not commensurable, whichever way they come out.
        let err = super::compare_documents(&machine("windows"), &machine("linux"))
            .expect_err("a cross-vantage pair must be refused");
        assert!(
            matches!(err, super::ComparisonRefusal::CrossVantage { .. }),
            "wrong refusal: {err:?}"
        );

        // THE PROPERTY yoga asked for: a refusal hands back NO hardware answer.
        // The type enforces it — Err carries no fingerprint — so this asserts
        // the rendering does not leak one either.
        let rendered = err.to_string();
        assert!(
            !rendered.contains("hw"),
            "a refusal must not also emit a verdict: {rendered}"
        );

        // Vantage is checked BEFORE identifiability: a caller inspecting only
        // the error type must not conclude the vantage was validated.
        let mut blind = machine("linux");
        blind.devices[0].name = "Host CPU".to_string();
        blind.devices[0].vendor = "unknown".to_string();
        blind.devices[0].system_ram_gb = None;
        let err = super::compare_documents(&machine("windows"), &blind)
            .expect_err("cross-vantage must win over unidentifiable");
        assert!(
            matches!(err, super::ComparisonRefusal::CrossVantage { .. }),
            "vantage must be checked first: {err:?}"
        );

        // A blind document within ONE vantage refuses as unidentifiable.
        let err = super::compare_documents(&machine("linux"), &blind)
            .expect_err("an unidentifiable document must be refused");
        assert!(
            matches!(err, super::ComparisonRefusal::Unidentifiable { .. }),
            "wrong refusal: {err:?}"
        );

        // CONTROL — a legitimate comparison still succeeds, so the refusals
        // above are not simply refusing everything.
        assert!(matches!(
            super::compare_documents(&machine("linux"), &machine("linux")),
            Ok(super::FingerprintComparison::Same(_))
        ));
    }

    /// 805-r98w / NPU parity, 2026-09-02. `none` must mean "looked and found
    /// nothing", never "could not look".
    ///
    /// MEASURED, not hypothetical: native Windows on this host rendered
    /// `accel_gpu=none accel_npu=none accel_reason=-` while the machine has a
    /// Radeon 860M and an XDNA2 NPU that Lemonade was serving models on at that
    /// moment. enumerate_gpus has Linux and macOS arms and no Windows arm;
    /// enumerate_npus reads /sys/class/accel. Both return empty and SUCCEED.
    #[test]
    fn absent_accelerators_read_unknown_where_the_probe_cannot_look() {
        let bare = || doc_with(vec![device("cpu", "Host CPU", &["host-native"], None)]);

        // LOOKED AND FOUND NOTHING: no gaps recorded, so `none` is a finding.
        let found_none = super::accel_envelope(&bare());
        assert!(found_none.contains("accel_gpu=none"), "{found_none}");
        assert!(found_none.contains("accel_npu=none"), "{found_none}");

        // COULD NOT LOOK: the probe recorded that it failed to enumerate, so
        // the same empty device list must NOT render as an absence.
        let mut blind = bare();
        blind.enumeration_gaps = vec!["gpu".to_string(), "npu".to_string()];
        let env = super::accel_envelope(&blind);
        assert!(
            env.contains("accel_gpu=unknown"),
            "a probe that could not look must not claim none: {env}"
        );
        assert!(
            env.contains("accel_npu=unknown"),
            "a probe that could not look must not claim none: {env}"
        );
        assert!(
            env.contains("not-enumerable-on-this-platform"),
            "cpu-only must never be a bare verdict here: {env}"
        );

        // ONE CLASS ONLY: a gap in gpu must not make the npu unknown too.
        let mut gpu_blind = bare();
        gpu_blind.enumeration_gaps = vec!["gpu".to_string()];
        let env = super::accel_envelope(&gpu_blind);
        assert!(env.contains("accel_gpu=unknown"), "{env}");
        assert!(
            env.contains("accel_npu=none"),
            "an npu that WAS enumerated stays a finding: {env}"
        );

        // A REAL device still reports its own state even when its class was
        // listed as a gap — an enumerated device outranks the gap record, and
        // this pins that the change cannot turn present hardware into unknown.
        let mut gpu = device("gpu", "AMD Radeon 860M", &["container"], None);
        gpu.vendor = "amd".to_string();
        let mut with_gpu = doc_with(vec![device("cpu", "Host CPU", &["host-native"], None), gpu]);
        with_gpu.enumeration_gaps = vec!["gpu".to_string()];
        let env2 = super::accel_envelope(&with_gpu);
        assert!(
            env2.contains("accel_gpu=usable"),
            "an enumerated device must still report its real state: {env2}"
        );
    }

    /// 805-r98w, hazard adopted from yoga 2026-09-02. THIS TEST DOCUMENTS A
    /// LIMITATION, NOT A GUARANTEE — it passes by asserting the fingerprint is
    /// NOT substrate-independent in the case that matters most.
    ///
    /// `hardware_fingerprint_ignores_substrate_and_separates_real_hardware`
    /// asserts that identical device records hash identically however the
    /// kernel, driver and lanes differ. True, and useless on its own: the
    /// substrate does not merely decorate the device records, it CHANGES them.
    /// The same machine reports its iGPU as "WSL2 paravirtual GPU (/dev/dxg)"
    /// under WSL2 — the PATH, not the silicon — and emits no GPU device at all
    /// probed natively on Windows. So that test's premise (identical inputs)
    /// assumes exactly what it is meant to prove.
    ///
    /// Consequence, pinned here so it is never rediscovered as a surprise:
    /// comparing documents from different `host.host_kind` is NOT a valid
    /// hardware comparison, and a mismatch across that boundary is not evidence
    /// of different hardware. The compare path must refuse such a pair rather
    /// than report a difference.
    ///
    /// gpu_model is deliberately NOT dropped to make the invariant hold: on
    /// Linux it is a real discriminator, and trading a loud known limitation
    /// for a quiet loss of signal is the worse bargain.
    #[test]
    fn same_machine_across_substrates_does_not_yet_fingerprint_alike() {
        let cpu = || {
            let mut c = device(
                "cpu",
                "AMD Ryzen AI 7 350 w/ Radeon 860M",
                &["host-native"],
                None,
            );
            c.vendor = "amd".to_string();
            c.cpu_cores = Some(CpuCores {
                physical: 8,
                logical: 16,
            });
            c.system_ram_gb = Some(15.2);
            c
        };

        // ONE machine, seen three ways by three probes.
        let mut native_windows = doc_with(vec![cpu()]);
        native_windows.host.host_kind = "windows".to_string();

        let mut under_wsl2 = doc_with(vec![
            cpu(),
            device(
                "gpu",
                "WSL2 paravirtual GPU (/dev/dxg)",
                &["container"],
                None,
            ),
        ]);
        under_wsl2.host.host_kind = "windows".to_string();

        let mut native_linux = doc_with(vec![
            cpu(),
            device(
                "gpu",
                "Krackan [Radeon 840M / 860M Graphics]",
                &["host-native"],
                None,
            ),
        ]);
        native_linux.host.host_kind = "linux".to_string();

        let w = super::hardware_fingerprint(&native_windows);
        let x = super::hardware_fingerprint(&under_wsl2);
        let l = super::hardware_fingerprint(&native_linux);

        assert_ne!(
            w, x,
            "documented limitation: the WSL2 probe adds a paravirtual GPU record the native probe lacks"
        );
        assert_ne!(
            x, l,
            "documented limitation: the WSL2 GPU string names the PATH, the Linux one names the silicon"
        );

        // The refusal guard does NOT paper over this: all three documents carry
        // a real CPU model, so all three are accepted and hashed. The hazard is
        // therefore live in exactly the case the guard cannot catch, which is
        // why it is written down rather than left to be met in the field.
        for (label, doc) in [
            ("native_windows", &native_windows),
            ("under_wsl2", &under_wsl2),
            ("native_linux", &native_linux),
        ] {
            assert!(
                super::hardware_fingerprint_checked(doc).is_ok(),
                "{label} should be accepted — the guard catches blind probes, not this"
            );
        }
    }

    /// 805-r98w. Measured on native Windows 2026-09-02: the probe emits ONE
    /// device, `cpu/unknown/Host CPU`, no GPU, no NPU, no RAM — and the raw
    /// hasher returned a confident `hw1-...` for it. That string is shared by
    /// every Windows host with the same logical-core count, so publishing it
    /// as an identity manufactures twins that do not exist.
    #[test]
    fn placeholder_document_is_refused_rather_than_hashed() {
        let mut cpu = device("cpu", "Host CPU", &["host-native"], None);
        cpu.vendor = "unknown".to_string();
        cpu.cpu_cores = Some(CpuCores {
            physical: 16,
            logical: 16,
        });
        let windows_today = doc_with(vec![cpu]);

        let refusal = super::hardware_fingerprint_checked(&windows_today)
            .expect_err("a placeholder-only document must be refused");
        assert!(
            refusal.missing.iter().any(|m| m.contains("cpu model name")),
            "the refusal must name the placeholder CPU: {refusal:?}"
        );
        assert!(
            refusal
                .missing
                .iter()
                .any(|m| m.contains("secondary discriminator")),
            "the refusal must name the absent gpu/npu/ram: {refusal:?}"
        );

        // CONTROL: a document that CAN identify the machine still succeeds,
        // so the guard refuses the placeholder and not the feature.
        let mut cpu = device(
            "cpu",
            "AMD Ryzen AI 7 350 w/ Radeon 860M",
            &["host-native"],
            None,
        );
        cpu.vendor = "amd".to_string();
        cpu.cpu_cores = Some(CpuCores {
            physical: 8,
            logical: 16,
        });
        cpu.system_ram_gb = Some(15.2);
        let real = doc_with(vec![cpu]);
        assert!(
            super::hardware_fingerprint_checked(&real).is_ok(),
            "a document carrying a real CPU model and RAM must be accepted"
        );
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn envelope_reports_workstation_gpu_when_the_container_lane_is_open() {
        let d = doc_with(vec![device(
            "gpu",
            "NVIDIA RTX A5000",
            &["container", "host-native"],
            None,
        )]);
        let env = accel_envelope(&d);
        assert!(
            env.contains("accel_class=workstation-gpu"),
            "a container-deliverable GPU is the workstation tier: {env}"
        );
        assert!(env.contains("accel_gpu=usable"), "{env}");
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn envelope_refuses_to_call_a_gpu_usable_when_only_the_host_lane_is_open() {
        // The NVIDIA-without-CDI record this codebase actually constructs:
        // usable=true AND unusable_reason=cdi-spec-missing, host-native only.
        // Reading `usable` would advertise a GPU no forge can touch.
        let d = doc_with(vec![device(
            "gpu",
            "NVIDIA RTX A5000",
            &["host-native"],
            Some("cdi-spec-missing"),
        )]);
        let env = accel_envelope(&d);
        assert!(
            env.contains("accel_class=cpu-only"),
            "a GPU the container cannot receive must not set a GPU class: {env}"
        );
        assert!(env.contains("accel_gpu=present-unusable"), "{env}");
        assert!(
            env.contains("accel_reason=cdi-spec-missing"),
            "cpu-only must never be a bare verdict — name the obstruction: {env}"
        );
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn envelope_reports_the_mobile_npu_tier_and_the_hybrid_tier() {
        let npu_only = doc_with(vec![
            device("npu", "AMD XDNA", &["container"], None),
            device("gpu", "iGPU", &["host-native"], Some("engine-missing")),
        ]);
        assert!(
            accel_envelope(&npu_only).contains("accel_class=mobile-npu"),
            "{}",
            accel_envelope(&npu_only)
        );

        let both = doc_with(vec![
            device("npu", "AMD XDNA", &["container"], None),
            device("gpu", "NVIDIA RTX A5000", &["container"], None),
        ]);
        assert!(
            accel_envelope(&both).contains("accel_class=hybrid-gpu-npu"),
            "{}",
            accel_envelope(&both)
        );
    }

    // ORDER 1139-xe5m. THE CLOSURE THESE PIN, stated so it is not weakened
    // later: a served envelope must be distinguishable from a measured one by
    // reading THE ENVELOPE ALONE — no filesystem access, no second run, no
    // knowledge of the producing host. A test that told them apart by checking
    // whether a cache file exists would pass while leaving every folded matrix
    // row exactly as ambiguous as it is today.

    #[test]
    // @trace order:1139-xe5m, spec:accel-capability-probe
    fn a_served_document_says_served_and_keeps_the_original_timestamp() {
        let dir = tempfile::tempdir().expect("tempdir");
        let cache = dir.path().join("capabilities.json");
        let stored = doc_with(Vec::new());
        write_capability_cache(&cache, &stored).expect("write cache");

        let got = load_or_probe_at(&cache, "cpu", Freshness::Cached);

        assert_eq!(
            got.envelope_source,
            Some(EnvelopeSource::Served),
            "a cache hit must say so on the copy it returns"
        );
        // The defect, in one assertion: the timestamp is the PRODUCING run's
        // and is served verbatim, so it can never be the discriminator.
        assert_eq!(got.timestamp, stored.timestamp);
        assert!(
            accel_envelope(&got).contains("accel_source=served"),
            "the one line a forge receives must carry it too"
        );
    }

    #[test]
    // @trace order:1139-xe5m, spec:accel-capability-probe
    fn the_stored_document_claims_neither_measured_nor_served() {
        // Persisting `measured` would replay the CLAIM along with the document
        // on every later serve — the defect again, wearing an authoritative
        // field. The stored form says `null`, and the serve path stamps.
        let dir = tempfile::tempdir().expect("tempdir");
        let cache = dir.path().join("capabilities.json");
        let mut measured = doc_with(Vec::new());
        measured.envelope_source = Some(EnvelopeSource::Measured);
        write_capability_cache(&cache, &measured).expect("write cache");

        let raw = std::fs::read_to_string(&cache).expect("read back");
        let back: CapabilityDocument = serde_json::from_str(&raw).expect("parse");
        assert_eq!(back.envelope_source, None, "raw: {raw}");
    }

    #[test]
    // @trace order:1139-xe5m, spec:accel-capability-probe
    fn a_document_written_before_this_order_reads_unknown_not_measured() {
        // Promoting silence into a measurement is the inference this order
        // exists to stop: every row the fleet has already folded is silent.
        let mut legacy = serde_json::to_value(doc_with(Vec::new())).expect("to value");
        legacy
            .as_object_mut()
            .expect("object")
            .remove("envelope_source");
        let doc: CapabilityDocument = serde_json::from_value(legacy).expect("parse legacy");

        assert_eq!(doc.envelope_source, None);
        assert!(accel_envelope(&doc).contains("accel_source=unknown"));
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn envelope_stays_one_parsable_line_even_with_hostile_device_names() {
        // `nvidia-smi -L` yields names with spaces, colons and parentheses. A
        // raw name would split the space-separated grammar and corrupt every
        // key after it.
        let d = doc_with(vec![device(
            "gpu",
            "GPU 0: NVIDIA RTX A5000 (UUID: GPU-dead beef)",
            &["container"],
            None,
        )]);
        let env = accel_envelope(&d);
        assert_eq!(env.lines().count(), 1, "envelope must be a single line");
        let keys: Vec<&str> = env
            .split(' ')
            .filter(|f| !f.is_empty())
            .map(|f| f.split('=').next().unwrap_or(""))
            .collect();
        assert_eq!(
            keys,
            vec![
                "accel_class",
                "accel_gpu",
                "accel_gpu_name",
                "accel_npu",
                "accel_npu_name",
                "accel_reason",
                "accel_cpu_cores",
                "accel_ram_gb",
                // 793-zumy REMAINING 2, appended last so every offset above it
                // is the one existing consumers already read.
                "accel_proof",
                // Orders 793-qr4t + 793-qc6q, APPENDED. The list is asserted in
                // ORDER, so this test is also the pin that the additive
                // extension stayed additive: any key inserted among the eight
                // above — a rename or a reorder wearing an addition's
                // clothes — fails here rather than at whichever consumer
                // splits on position.
                "accel_side",
                "accel_gpu_path",
                "accel_gpu_engine",
                "accel_mem_model",
                "accel_mem_budget_gb",
                "accel_prefill_dev",
                "accel_decode_dev",
                "accel_decode_crossover_b",
                // Order 1139-xe5m, appended last.
                "accel_source",
            ],
            "every field must survive a hostile name: {env}"
        );
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn cache_path_never_resolves_into_the_working_directory() {
        // Order 495: generated evidence must never land in the tracked checkout.
        // With no HOME the old fallback was ".", so a build or `cargo test`
        // wrote capabilities.json into the crate directory — dirt the NEXT
        // agent's forge dirty-start guard refuses, for a file they did not
        // create. Absolute-and-not-under-CWD is the property that matters.
        let path = capabilities_cache_path();
        assert!(
            path.is_absolute(),
            "cache path must be absolute, got {path:?}"
        );
        if let Ok(cwd) = std::env::current_dir() {
            assert!(
                !path.starts_with(&cwd) || cwd == Path::new("/"),
                "cache path {path:?} must not resolve inside the working directory {cwd:?}"
            );
        }
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn nvidia_model_name_drops_the_index_prefix_and_the_hardware_uuid() {
        // Verbatim shape of `nvidia-smi -L` on this workstation.
        let raw = "GPU 0: NVIDIA RTX A5000 (UUID: GPU-354dc81c-189c-4074-1cb4-6cb1ae80f68b)";
        assert_eq!(nvidia_model_name(raw), "NVIDIA RTX A5000");
        assert!(
            !nvidia_model_name(raw).contains("354dc81c"),
            "the GPU UUID is a stable hardware identifier and must not travel \
             into every forge's env and context file"
        );
        // An unfamiliar format degrades to noisy, never to empty.
        assert_eq!(
            nvidia_model_name("Some Future Format"),
            "Some Future Format"
        );
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn envelope_on_a_bare_cpu_host_is_cpu_only_with_no_phantom_devices() {
        let env = accel_envelope(&doc_with(vec![device("cpu", "CPU", &["container"], None)]));
        assert!(env.contains("accel_class=cpu-only"), "{env}");

        // THE PROPERTY THIS TEST OWNS is that no device is MANUFACTURED: the
        // class stays cpu-only and neither name field names anything.
        assert!(env.contains("accel_gpu_name=-"), "{env}");
        assert!(env.contains("accel_npu_name=-"), "{env}");

        // The STATE, however, is platform-dependent, and asserting `none`
        // unconditionally is what this test used to get wrong (2026-09-02). It
        // silently assumed the running platform can enumerate accelerators. On
        // native Windows it cannot — no Windows arm in enumerate_gpus, and
        // enumerate_npus reads a Linux-only sysfs path — so `none` there was
        // the probe denying hardware it had never looked for. "Looked and found
        // nothing" and "cannot look here" are different facts and only the
        // first is `none`.
        // This document records NO gaps, so an empty device list here is a
        // genuine finding and `none` is the honest rendering on every platform.
        assert!(env.contains("accel_gpu=none"), "{env}");
        assert!(env.contains("accel_npu=none"), "{env}");
    }

    #[test]
    #[cfg(target_os = "linux")]
    // @trace spec:accel-capability-probe
    fn wsl2_paravirtual_gpu_fires_only_on_the_unambiguous_wsl2_shape() {
        // The whole decision table. The one true case: /dev/dxg present, no DRI
        // render node, nothing better already found.
        assert!(wsl2_paravirtual_gpu(true, false, false), "the WSL2 shape");

        // Bare-metal Linux has no /dev/dxg — this must never manufacture a
        // phantom device there, which is what
        // envelope_on_a_bare_cpu_host_is_cpu_only_with_no_phantom_devices pins.
        assert!(!wsl2_paravirtual_gpu(false, false, false), "no dxg, no dri");
        assert!(
            !wsl2_paravirtual_gpu(false, true, false),
            "bare-metal with DRI"
        );
        assert!(
            !wsl2_paravirtual_gpu(false, true, true),
            "bare-metal, gpu found"
        );
        assert!(
            !wsl2_paravirtual_gpu(false, false, true),
            "no dxg, gpu found"
        );

        // A WSL2 host that DOES expose a render node is the /dev/dri arm's job;
        // emitting here too would double-count one GPU.
        assert!(
            !wsl2_paravirtual_gpu(true, true, false),
            "dxg with a DRI node"
        );
        assert!(
            !wsl2_paravirtual_gpu(true, true, true),
            "dxg, DRI, gpu found"
        );

        // nvidia-smi answered first (a WSL2 host with a CUDA passthrough), so a
        // better record already exists and this must defer to it.
        assert!(
            !wsl2_paravirtual_gpu(true, false, true),
            "defers to a found gpu"
        );
    }

    // @trace spec:accel-capability-probe
    /// ORDER 793-zumy criterion 2, pinned against the PRODUCTION value.
    ///
    /// Measured on yolanda 2026-08-29: /dev/dxg present, /dev/dri absent, and no
    /// Vulkan loader at all — vulkaninfo off PATH, /usr/share/vulkan/icd.d
    /// absent. The old reason, `wsl2-no-dri-render-node`, named a render node
    /// WSL2 is never expected to create, so it described normal WSL2 while
    /// reading to a scheduler as a hardware verdict. The real obstruction is a
    /// missing translation layer, which is provisioning, not silicon.
    ///
    /// Read the sibling test below before trusting either: it renders a
    /// TEST-SUPPLIED reason and therefore cannot pin production at all.
    ///
    /// RETARGETED 793-zumy: this asserted `wsl2_paravirtual_gpu_reason()`, which
    /// was a constant and is now a DETECTION reading the live filesystem. Left
    /// as it was, the test would pass on any host without a Vulkan loader —
    /// including this one — and go RED on esmeraldinha, which carries a loader
    /// and an ICD set and is the only host that can verify this packet at all.
    /// A test that reds on the verification host and greens everywhere else is
    /// worse than no test. It now drives the PURE half with supplied facts, so
    /// its verdict is a property of the code rather than of whoever ran it.
    ///
    /// REGIME: pure function, no IO, no host state, no wall-clock.
    #[test]
    fn the_wsl2_unusable_reason_names_the_missing_engine_not_the_missing_render_node() {
        // BOTH missing arms must carry criterion 2's verbatim word.
        for (loader, icds, arm) in [(false, 0usize, "no loader"), (true, 0, "loader, no ICD")] {
            let reason = wsl2_paravirtual_gpu_reason_from(loader, icds);
            assert!(
                reason.starts_with("engine-missing"),
                "criterion 2 requires the verbatim word `engine-missing` for the {arm} arm; got {reason}"
            );
            // The red herring must not come back.
            assert!(
                !reason.contains("dri-render-node"),
                "the reason blames a render node WSL2 never creates: {reason}"
            );
            // A provisioning statement should name its own remedy, like the
            // sibling rocm-runtime-missing / intel-compute-runtime-missing do.
            assert!(
                reason.contains("vulkan"),
                "the reason should name WHICH engine is missing: {reason}"
            );
        }

        // AND THE TWO MISSING ARMS MUST BE DISTINGUISHABLE. Before this packet
        // every dxg device got `no-vulkan-icd` whether or not a loader existed,
        // so the reason named a remedy that would not have helped a host with
        // no loader at all.
        assert_ne!(
            wsl2_paravirtual_gpu_reason_from(false, 0),
            wsl2_paravirtual_gpu_reason_from(true, 0),
            "a missing loader and a missing ICD need different remedies and must not share a reason"
        );
    }

    /// 793-zumy: the arm that makes this a detection rather than a constant.
    /// esmeraldinha HAS a loader and an ICD set, so `engine-missing` is simply
    /// false there — it was the shipped answer anyway, on every host.
    ///
    /// REGIME: pure function, no IO, no host state, no wall-clock.
    #[test]
    fn a_present_loader_and_icd_is_not_reported_as_a_missing_engine() {
        let reason = wsl2_paravirtual_gpu_reason_from(true, 1);
        assert!(
            !reason.starts_with("engine-missing"),
            "with a loader and an ICD present the engine is not missing; got {reason}"
        );
        assert!(
            reason.contains("unverified"),
            "the honest statement is that nothing has enumerated it yet; got {reason}"
        );
    }

    /// A device as the loader described it, for the tests below.
    #[cfg(test)]
    fn vk_device(device_type: u32, driver_id: u32, name: &str) -> VulkanPhysicalDevice {
        VulkanPhysicalDevice {
            device_type,
            driver_id,
            name: name.to_string(),
        }
    }

    /// 793-zumy CRITERION 3, pinned: "Devices of type PHYSICAL_DEVICE_TYPE_CPU
    /// or driverID DRIVER_ID_MESA_LLVMPIPE are rejected, with a test pinning
    /// the rejection."
    ///
    /// THE VALUES ARE MEASURED, NOT INVENTED. esmeraldinha, 2026-09-18, one
    /// enumeration over /dev/dxg with the stock Mesa ICD set installed:
    ///   device[0] type=INTEGRATED_GPU(1) driverID=23 "Microsoft Direct3D12 (Intel(R) UHD Graphics)"
    ///   device[1] type=CPU(4)            driverID=13 "llvmpipe (LLVM 22.1.8, 256 bits)"
    /// That is the exact pair criterion 3 describes — the software rasterizer
    /// offered BESIDE the real part, not instead of it — so a probe that takes
    /// the first device the loader lists would report a slow CPU path as a GPU.
    ///
    /// The two rejection predicates are asserted SEPARATELY as well as
    /// together, because on today's Mesa they always co-occur and a check that
    /// only ever sees them together cannot tell which one it is relying on.
    ///
    /// REGIME: pure function, no IO, no host state, no wall-clock.
    #[test]
    fn a_software_rasterizer_never_satisfies_the_gpu_check() {
        let dozen = vk_device(1, 23, "Microsoft Direct3D12 (Intel(R) UHD Graphics)");
        let llvmpipe = vk_device(4, 13, "llvmpipe (LLVM 22.1.8, 256 bits)");

        // ARM 1: lavapipe alone is a refusal, not a GPU.
        match wsl2_vulkan_verdict_from(Some(std::slice::from_ref(&llvmpipe)), true, 12) {
            Wsl2VulkanVerdict::Unusable { reason } => assert!(
                reason.contains("software-rasterizer"),
                "the refusal must name the rasterizer, not a missing ICD: {reason}"
            ),
            other => panic!("a software rasterizer was accepted as a GPU: {other:?}"),
        }

        // ARM 2: type=CPU alone, with a driverID that is NOT llvmpipe — a
        // second software rasterizer (SwiftShader reports 10) must not slip
        // through a driverID-only check.
        assert!(
            matches!(
                wsl2_vulkan_verdict_from(Some(&[vk_device(4, 10, "SwiftShader Device")]), true, 12),
                Wsl2VulkanVerdict::Unusable { .. }
            ),
            "PHYSICAL_DEVICE_TYPE_CPU must be rejected on its own"
        );

        // ARM 3: driverID=MESA_LLVMPIPE alone, with a type that is NOT CPU — a
        // rasterizer that mislabels its own type must not slip through a
        // type-only check.
        assert!(
            matches!(
                wsl2_vulkan_verdict_from(Some(&[vk_device(0, 13, "llvmpipe")]), true, 12),
                Wsl2VulkanVerdict::Unusable { .. }
            ),
            "DRIVER_ID_MESA_LLVMPIPE must be rejected on its own"
        );

        // ARM 4: THE MEASURED MIXED CASE. The real part is present and the
        // rasterizer must not mask it — and equally must not be the one picked.
        match wsl2_vulkan_verdict_from(Some(&[llvmpipe, dozen]), true, 12) {
            Wsl2VulkanVerdict::Usable { name } => assert!(
                name.contains("Direct3D12"),
                "the enumerated GPU's own name must reach the record, not the rasterizer's: {name}"
            ),
            other => panic!("the real Dozen device was rejected: {other:?}"),
        }
    }

    /// 793-zumy CRITERION 2's opening clause: detection by ENUMERATION, and
    /// the three answers an enumeration can give kept distinct.
    ///
    /// THE `None` ARM IS THE ONE THAT PROTECTS CRITERION 4. Every host that
    /// cannot enumerate — no loader, no instance, no properties2 — must produce
    /// the byte-identical reason it produced before this change, or the "no
    /// regression on the hosts that were already correct" criterion is broken
    /// by the fix for the others.
    ///
    /// REGIME: pure function, no IO, no host state, no wall-clock.
    #[test]
    fn nobody_enumerated_and_enumerated_nothing_are_different_answers() {
        // NOBODY ASKED: delegates to the filesystem reading, verbatim.
        for (loader, icds) in [(false, 0usize), (true, 0), (true, 12)] {
            assert_eq!(
                wsl2_vulkan_verdict_from(None, loader, icds),
                Wsl2VulkanVerdict::Unusable {
                    reason: wsl2_paravirtual_gpu_reason_from(loader, icds)
                },
                "with no enumeration the verdict must be the pre-793-zumy reason unchanged"
            );
        }

        // ASKED, AND THE LOADER OFFERED NOTHING. A different fact, so a
        // different token — and it must not borrow the not-enumerated wording,
        // because something DID enumerate.
        let empty = wsl2_vulkan_verdict_from(Some(&[]), true, 12);
        let not_asked = wsl2_vulkan_verdict_from(None, true, 12);
        assert_ne!(
            empty, not_asked,
            "`asked and found none` must not render as `nobody asked`"
        );
        match empty {
            Wsl2VulkanVerdict::Unusable { reason } => {
                assert!(
                    reason.starts_with("engine-missing"),
                    "criterion 2 requires the verbatim word for hardware with no runtime: {reason}"
                );
                assert!(
                    !reason.contains("not-enumerated"),
                    "it WAS enumerated; the reason must not claim otherwise: {reason}"
                );
            }
            other => panic!("an empty enumeration was accepted as a GPU: {other:?}"),
        }
    }

    /// 793-zumy, the IO half against a FIXTURE TREE — never the real /usr,
    /// which would assert whatever this machine happens to carry.
    ///
    /// REGIME: hermetic, tempdir-rooted, no host state, no wall-clock.
    #[test]
    fn wsl2_vulkan_facts_read_the_icd_directories_the_loader_reads() {
        let root = std::env::temp_dir().join(format!(
            "tillandsias-vulkan-facts-{}-{}",
            std::process::id(),
            line!()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let share = root.join("usr/share/vulkan/icd.d");
        let etc = root.join("etc/vulkan/icd.d");
        std::fs::create_dir_all(&share).unwrap();
        std::fs::create_dir_all(&etc).unwrap();

        // Empty directories are NOT an ICD set.
        let (loader, icds) = wsl2_vulkan_facts_at(&root);
        assert!(!loader, "fixture has no loader");
        assert_eq!(icds, 0, "empty icd.d directories are not an ICD");

        // A non-json file must not count — the loader reads manifests, and a
        // README in that directory is not one.
        std::fs::write(share.join("README"), b"not a manifest").unwrap();
        assert_eq!(
            wsl2_vulkan_facts_at(&root).1,
            0,
            "a non-json file in icd.d must not read as an ICD"
        );

        // BOTH directories count, because the loader reads both.
        std::fs::write(share.join("dzn_icd.x86_64.json"), b"{}").unwrap();
        std::fs::write(etc.join("local_override.json"), b"{}").unwrap();
        assert_eq!(
            wsl2_vulkan_facts_at(&root).1,
            2,
            "packaged and local ICD manifests must both be seen"
        );

        // The loader arm keys on the SONAME, not the -dev symlink.
        std::fs::create_dir_all(root.join("usr/lib64")).unwrap();
        std::fs::write(root.join("usr/lib64/libvulkan.so"), b"").unwrap();
        assert!(
            !wsl2_vulkan_facts_at(&root).0,
            "libvulkan.so without the version suffix is the -dev symlink, not a loadable runtime"
        );
        std::fs::write(root.join("usr/lib64/libvulkan.so.1"), b"").unwrap();
        assert!(
            wsl2_vulkan_facts_at(&root).0,
            "libvulkan.so.1 is the loader the ICD is dlopened by"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// NOTE: this test cannot pin the production reason — it supplies its own.
    /// Kept for what it does cover (present-unusable never collapsing to none,
    /// and the class staying cpu-only). See the test above for the reason pin.
    #[test]
    fn a_wsl2_paravirtual_gpu_renders_as_present_unusable_never_as_none() {
        // The point of 806-2r4s: this host has a healthy AMD Radeon 860M that
        // WSL2 exposes only as /dev/dxg. Before the probe emitted this record
        // the envelope read `accel_gpu=none accel_reason=-`, which is
        // indistinguishable from a machine with no GPU at all — and the fleet
        // capability matrix cannot be built on that.
        let mut gpu = device(
            "gpu",
            "WSL2 paravirtual GPU (/dev/dxg)",
            &[],
            Some("engine-missing:no-vulkan-icd"),
        );
        gpu.usable = false;

        let env = accel_envelope(&doc_with(vec![
            device("cpu", "CPU", &["container"], None),
            gpu,
        ]));

        assert!(env.contains("accel_gpu=present-unusable"), "{env}");
        assert!(!env.contains("accel_gpu=none"), "{env}");
        assert!(env.contains("engine-missing"), "{env}");
        // Capacity is still cpu-only — an unreachable GPU must not inflate the
        // class, or a scheduler would place GPU work on a host that cannot run it.
        assert!(env.contains("accel_class=cpu-only"), "{env}");
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn test_probe_produces_valid_document() {
        let _seam = podman_seam();
        let doc = run_probe("gpu-cuda");
        assert_eq!(doc.schema_version, SCHEMA_VERSION);
        assert_eq!(doc.legacy_tier, "gpu-cuda");
        assert!(!doc.devices.is_empty());
        let cpu = doc
            .devices
            .iter()
            .find(|d| d.device_class == "cpu")
            .expect("CPU present");
        assert!(cpu.usable);
        assert!(cpu.lanes.contains(&"container".to_string()));
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn test_serialization_roundtrip() {
        let _seam = podman_seam();
        let doc = run_probe("cpu");
        let json = serde_json::to_string_pretty(&doc).expect("serialize");
        let deserialized: CapabilityDocument = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(doc, deserialized);
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn test_npu_vendor_resolution() {
        let npu_amd = parse_npu_record(Some("amdxdna"));
        assert_eq!(npu_amd.vendor, "AMD XDNA");
        assert!(!npu_amd.usable);
        assert_eq!(npu_amd.unusable_reason.as_deref(), Some("engine-missing"));

        let npu_intel = parse_npu_record(Some("intel_vpu"));
        assert_eq!(npu_intel.vendor, "Intel NPU");
        assert!(!npu_intel.usable);

        let npu_unknown = parse_npu_record(Some("custom_accel"));
        assert_eq!(npu_unknown.vendor, "unknown");
        assert!(!npu_unknown.usable);
    }

    fn parse_npu_record(driver: Option<&str>) -> DeviceRecord {
        let (vendor, name_str) = match driver {
            Some("amdxdna") => ("AMD XDNA".to_string(), "AMD XDNA NPU".to_string()),
            Some("intel_vpu") => ("Intel NPU".to_string(), "Intel NPU".to_string()),
            Some(other) => ("unknown".to_string(), format!("Unknown NPU ({other})")),
            None => ("unknown".to_string(), "Unknown Accel Device".to_string()),
        };
        DeviceRecord {
            device_class: "npu".to_string(),
            vendor,
            name: name_str,
            device_node: Some("/dev/accel/accel0".to_string()),
            fw_version: None,
            driver: driver.map(|s| s.to_string()),
            usable: false,
            unusable_reason: Some("engine-missing".to_string()),
            policy_unscheduled: None,
            lanes: vec!["host-native".to_string()],
            memory_bandwidth_gbps: None,
            memory_bandwidth_source: "unknown".to_string(),
            cpu_flags: None,
            cpu_cores: None,
            system_ram_gb: None,
            memory_model: None,
            // 1137-rgfm: None = this fixture states no provenance, so the
            // pre-field deny-list still judges it, exactly as before.
            name_source: None,
        }
    }

    /// ORDER 803-rbqf. WHAT THIS TEST USED TO BE, and why it proved nothing:
    ///
    ///     let metal_device = DeviceRecord { ... lanes: vec!["host-native"] ... };
    ///     assert!(!metal_device.lanes.contains(&"container".to_string()));
    ///
    /// It built its own `DeviceRecord` literal and asserted on THAT. The
    /// production arm in `enumerate_gpus` was never called, so the test was a
    /// tautology over a value the test itself had just written: if the real
    /// macOS arm started advertising `container` tomorrow, this test would stay
    /// green, because the literal it inspects is not the code that ships.
    ///
    /// A guard assembled only from what its author already believed inherits
    /// every omission in that belief. The fix is not a stronger assertion, it
    /// is a different SUBJECT — the probe's output instead of the test's input.
    ///
    /// Split in two because the subject is only observable on one platform:
    /// this arm runs the real probe where it exists, and
    /// [`the_macos_arm_cannot_advertise_the_container_lane`] pins the same
    /// clause by source everywhere else, so a Linux CI run still refuses the
    /// regression.
    #[test]
    #[cfg(target_os = "macos")]
    // @trace order:803-rbqf, spec:accel-capability-probe
    fn test_macos_metal_lane_isolation() {
        let gpus = enumerate_gpus();
        let metal = gpus
            .iter()
            .find(|d| d.vendor == "apple")
            .expect("the macOS arm must enumerate an Apple GPU on a macOS host");

        // PROBE-7, asserted against what the probe actually emitted.
        assert!(
            !metal.lanes.contains(&"container".to_string()),
            "PROBE-7: Metal must not be offered on the container lane: {:?}",
            metal.lanes
        );
        assert!(
            metal.lanes.contains(&"host-native".to_string()),
            "Metal is reachable host-native: {:?}",
            metal.lanes
        );

        // 803-rbqf: the lane exclusion must NAME its obstruction.
        assert!(
            metal.unusable_reason.is_some(),
            "a device excluded by lane must say why it is excluded"
        );

        // 803-r8u4: unified memory, and a budget to go with it.
        assert_eq!(
            metal.memory_model.as_deref(),
            Some("unified"),
            "Apple silicon shares one memory budget"
        );
        assert!(
            metal.system_ram_gb.unwrap_or(0.0) > 0.0,
            "unified memory is only a budget if the budget is recorded"
        );
    }

    /// ORDER 803-r8u4, the host-fact half. Runs the REAL `enumerate_host` and
    /// `enumerate_cpu` on a macOS host and refuses the two nulls the fleet's
    /// first macOS capability row filed (macneo, relayed onto 657-zm2n
    /// 2026-09-04: `system_ram_gb null, is_battery_present false`).
    ///
    /// It asserts `is_some()` rather than `Some(true)` ON PURPOSE. A Mac mini
    /// has no battery and must be free to answer `Some(false)`; what is being
    /// refused is `None`, which now means "nothing looked" and was the true
    /// state of every macOS host before this arm existed. Pinning `true` here
    /// would pass on this laptop and red on a desktop Mac for being correct.
    ///
    /// MEASURED on tlatoanis-macbook-air (Apple M5) 2026-09-12:
    /// `is_battery_present: true`, `system_ram_gb: 16.0`.
    /// ORDER 1137-rgfm. The CPU name must be THIS Mac's part, not the family
    /// literal every Apple silicon host shares.
    ///
    /// It asserts against `machdep.cpu.brand_string` read independently, rather
    /// than against a hard-coded "Apple M5" — pinning the string would red on
    /// every other Mac in the fleet for being a different correct machine, and
    /// pinning `!= "Apple Silicon CPU"` would accept any OTHER placeholder,
    /// which is the deny-list mistake this order exists to remove.
    ///
    /// MEASURED on tlatoanis-macbook-air 2026-09-13: brand_string `Apple M5`;
    /// before this change the record read `Apple Silicon CPU`, identical on
    /// every Apple silicon Mac, so the fingerprint's cpu component carried no
    /// information at all.
    #[test]
    #[cfg(target_os = "macos")]
    // @trace order:1137-rgfm, spec:accel-capability-probe
    fn macos_cpu_name_is_the_real_part_not_a_family_placeholder() {
        let brand =
            macos_cpu_brand().expect("machdep.cpu.brand_string must answer on a macOS host");
        let cpu = enumerate_cpu();

        assert_eq!(
            cpu.name, brand,
            "the record must carry the measured part name, not a family literal"
        );
        assert_eq!(
            cpu.name_source.as_deref(),
            Some("measured"),
            "a measured name must SAY it was measured; the deny-list could not \
             tell a new placeholder from a real part (1137-rgfm)"
        );

        // The fingerprint must now accept this document. Before 1137-rgfm it
        // accepted it too — for the wrong reason, because "Apple Silicon CPU"
        // was simply not on the deny-list.
        assert!(
            !cpu.name.is_empty() && cpu.name != "Apple Silicon CPU",
            "the family literal survives only as the unmeasured fallback"
        );
    }

    /// ORDER 1137-rgfm, the half that does NOT need a macOS host: a device
    /// declaring `placeholder` is refused however specific its name looks, and
    /// a device declaring nothing falls back to the old deny-list so documents
    /// filed before the field keep their behaviour.
    #[test]
    // @trace order:1137-rgfm, spec:accel-capability-probe
    fn a_declared_placeholder_is_refused_however_plausible_the_name() {
        let mut doc = schedulable_gpu_doc();

        // A name no deny-list would ever carry, declared as a placeholder.
        for d in doc.devices.iter_mut().filter(|d| d.device_class == "cpu") {
            d.name = "Apple M5".to_string();
            d.name_source = Some("placeholder".to_string());
        }
        assert!(
            hardware_fingerprint_checked(&doc).is_err(),
            "a declared placeholder must be refused even when the string looks \
             like a real part — that is the whole point of asking the probe"
        );

        // The same document, measured, is identifying.
        for d in doc.devices.iter_mut().filter(|d| d.device_class == "cpu") {
            d.name_source = Some("measured".to_string());
        }
        assert!(
            hardware_fingerprint_checked(&doc).is_ok(),
            "a measured name must be accepted"
        );

        // Provenance absent: the pre-field deny-list still judges it.
        for d in doc.devices.iter_mut().filter(|d| d.device_class == "cpu") {
            d.name_source = None;
            d.name = "Host CPU".to_string();
        }
        assert!(
            hardware_fingerprint_checked(&doc).is_err(),
            "an old document naming a known placeholder is refused as before"
        );
    }

    #[test]
    #[cfg(target_os = "macos")]
    // @trace order:803-r8u4, spec:accel-capability-probe
    fn macos_host_facts_are_measured_not_defaulted() {
        assert!(
            enumerate_host().is_battery_present.is_some(),
            "macOS must LOOK for a battery; None means nothing did (803-r8u4)"
        );
        let cpu = enumerate_cpu();
        assert!(
            cpu.system_ram_gb.unwrap_or(0.0) > 0.0,
            "macOS must report physical RAM; null was the pre-803-r8u4 answer"
        );
    }

    /// The source-level half of [`test_macos_metal_lane_isolation`], so the
    /// clause is guarded on hosts that cannot run the macOS arm (order
    /// 803-rbqf). Same technique, and for the same reason, as 1090-8nh4's
    /// source assertion on `detect_inference_tier`: the fleet lands through
    /// Linux hosts, and a macOS-only test is no guard at all on the branch
    /// where most commits arrive.
    #[test]
    // @trace order:803-rbqf, spec:accel-capability-probe
    fn the_macos_arm_cannot_advertise_the_container_lane() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/accel_probe.rs"));

        // ANCHOR FIRST. A scan that silently finds nothing is a guard that
        // never fires, and it looks exactly like a guard that passes.
        let marker = "PROBE-7: macOS Metal is host-native ONLY";
        let start = source
            .find(marker)
            .expect("the macOS arm's PROBE-7 marker moved; re-anchor this guard");
        let arm = &source[start..];
        let end = arm
            .find("});")
            .expect("could not find the end of the macOS DeviceRecord literal");
        let arm = &arm[..end];

        assert!(
            !arm.contains("\"container\""),
            "the macOS GPU arm names the container lane; Metal does not cross \
             the linux-aarch64 guest boundary (PROBE-7, 803-rbqf)"
        );
        assert!(
            arm.contains("\"host-native\""),
            "the macOS GPU arm must still offer the host-native lane"
        );
        assert!(
            arm.contains("unusable_reason: Some("),
            "a lane-excluded device must name its obstruction (803-rbqf)"
        );
        assert!(
            arm.contains("memory_model: Some(\"unified\""),
            "Apple silicon is unified memory (803-r8u4)"
        );
    }

    // ---- order 808-43mw: host identity and measurement labelling ----

    /// THE COMPATIBILITY GUARD, and the reason the new fields are optional.
    ///
    /// This is byte-for-byte the payload `scripts/bench-accel-lane.sh` pipes
    /// into `--record-measurement` today (its `jq -nc` object, same key order).
    /// That script belongs to another host. If widening this struct made the
    /// current payload unparseable, the first host to run a new binary against
    /// the unchanged script would stop recording measurements — and would do it
    /// QUIETLY, because the script's own `|| echo note:...record-failed` arm
    /// keeps the bench exiting 0.
    #[test]
    fn todays_bench_payload_still_deserializes() {
        let payload = r#"{"device":"cpu","engine":"ollama","prefill_tps":1024.5,
            "decode_tps":87.2,"joules_per_token":null,"degraded":false,
            "degraded_reason":null}"#;

        let rec: MeasurementRecord =
            serde_json::from_str(payload).expect("the CURRENT bench payload must still parse");

        assert_eq!(rec.device, "cpu");
        assert_eq!(rec.engine, "ollama");
        assert_eq!(
            rec.workload_suite, None,
            "an unlabelled record must read as UNLABELLED, never as a default suite"
        );
        assert_eq!(rec.locus, None, "same for locus: absent is not a value");
    }

    /// And a labelled payload round-trips, so the writer has something to aim at.
    #[test]
    fn a_labelled_measurement_round_trips() {
        let rec = MeasurementRecord {
            device: "cpu".to_string(),
            engine: "ollama".to_string(),
            prefill_tps: Some(1024.5),
            decode_tps: Some(87.2),
            joules_per_token: None,
            degraded: false,
            degraded_reason: None,
            workload_suite: Some("802-2536-v1".to_string()),
            locus: Some("in-guest".to_string()),
            model: None,
            model_params_b: None,
        };
        let json = serde_json::to_string(&rec).expect("serializes");
        let back: MeasurementRecord = serde_json::from_str(&json).expect("round-trips");
        assert_eq!(back, rec);
    }

    /// A v1 document has no host_id, so it must be REJECTED rather than read
    /// as a host whose name happens to be empty. `load_or_probe` treats a parse
    /// failure as "re-probe", which is the correct outcome: a document that
    /// cannot name itself is not a row the matrix can accept.
    #[test]
    fn a_v1_document_without_host_identity_is_refused() {
        let v1 = r#"{"schema_version":1,"legacy_tier":"cpu","devices":[],
            "engines":[],"measurements":[],
            "host":{"is_battery_present":false,"kernel_release":"6.18.33.2-microsoft-standard-WSL2"},
            "timestamp":"1970-01-01T00:00:00Z"}"#;
        assert!(
            serde_json::from_str::<CapabilityDocument>(v1).is_err(),
            "a document with no host_id must not deserialize into one with a blank host_id"
        );
    }

    /// Two WSL2 guests share a kernel release EXACTLY — measured, not assumed:
    /// this host's guest reports `6.18.33.2-microsoft-standard-WSL2`, and so
    /// does any other guest on the same WSL kernel. This test states why
    /// `kernel_release` could not have been the fold key.
    #[test]
    fn kernel_release_does_not_distinguish_two_wsl2_hosts() {
        let shared = "6.18.33.2-microsoft-standard-WSL2".to_string();
        let a = HostInfo {
            is_battery_present: Some(false),
            kernel_release: shared.clone(),
            host_id: "yolanda".to_string(),
            host_id_source: "node-name".to_string(),
            host_kind: "linux".to_string(),
            side: Some("native-linux".to_string()),
        };
        let b = HostInfo {
            host_id: "esmeraldinha".to_string(),
            ..a.clone()
        };
        assert_eq!(a.kernel_release, b.kernel_release, "the collision is real");
        assert_ne!(a.host_id, b.host_id, "and host_id is what separates them");
    }

    #[test]
    fn node_names_are_shortened_and_lowercased() {
        assert_eq!(normalize_node_name("Yolanda").as_deref(), Some("yolanda"));
        assert_eq!(
            normalize_node_name("YOGA.localdomain\n").as_deref(),
            Some("yoga"),
            "the domain is stripped, matching the shell probe"
        );
        assert_eq!(normalize_node_name("  \n ").as_deref(), None);
        assert_eq!(normalize_node_name(".leading-dot").as_deref(), None);
    }

    /// The INPUT wins over the derived chain, and is normalised on the way in —
    /// otherwise `TILLANDSIAS_HOST_ID=Yolanda` and a derived `yolanda` would be
    /// two keys for one machine, which is the defect this field exists to fix.
    #[test]
    fn the_input_overrides_the_derived_name_and_is_normalised() {
        // The input is passed, not planted in the process environment: this
        // test and `the_probe_always_yields_a_foldable_key` run as threads of
        // one process, and mutating `HOST_ID_ENV` from both raced about one
        // run in fifteen (1146-z8ux).
        let (id, source) = resolve_host_id_from(Some("Esmeraldinha.LOCAL"));
        assert_eq!(id, "esmeraldinha");
        assert_eq!(source, "input");
    }

    /// Whatever this machine is, the probe must produce a usable key: never
    /// empty, always lowercase, and always with a source that says how it was
    /// obtained.
    #[test]
    fn the_probe_always_yields_a_foldable_key() {
        // No input: the derived chain (hostname -> uname -n -> /etc/hostname)
        // must answer. Nothing in the environment is touched (1146-z8ux).
        let (id, source) = resolve_host_id_from(None);
        assert!(
            !id.is_empty(),
            "an empty key would fold every unknown host into one row"
        );
        assert_eq!(id, id.to_ascii_lowercase());
        assert!(
            ["input", "node-name", "unknown"].contains(&source.as_str()),
            "unexpected host_id_source {source}"
        );
    }

    /// `host_kind` speaks the ledger's vocabulary, not Rust's — the ledger says
    /// `macos`, `std::env::consts::OS` says `macos` too but only by luck of
    /// spelling, and a consumer folding the matrix must not have to know which.
    #[test]
    fn host_kind_uses_the_ledgers_vocabulary() {
        assert!(
            ["linux", "windows", "macos"].contains(&host_kind()),
            "host_kind() returned {} which is not a fleet host vocabulary term",
            host_kind()
        );
    }

    /// PINS THE KNOWN GAP so it cannot be mistaken for a bug later, and so the
    /// day someone fixes it the test says what changed.
    ///
    /// A document produced inside a WSL2 guest carries `host_kind: "linux"`
    /// while describing a machine whose spec is a Windows laptop's. The pair
    /// (kernel_release says WSL2, host_kind says linux) is currently the ONLY
    /// in-document signal that a row was observed from a guest — it is not a
    /// substitute for the host-side contribution 809-7e4m specifies, and this
    /// test asserts the gap rather than pretending it is closed.
    #[test]
    fn a_wsl2_row_cannot_yet_say_its_machine_is_windows() {
        let guest_row = HostInfo {
            is_battery_present: Some(true),
            kernel_release: "6.18.33.2-microsoft-standard-WSL2".to_string(),
            host_id: "yolanda".to_string(),
            host_id_source: "node-name".to_string(),
            host_kind: "linux".to_string(),
            side: Some("native-linux".to_string()),
        };
        assert!(
            guest_row.kernel_release.contains("microsoft-standard-WSL2"),
            "the kernel is the only hint the context is a guest"
        );
        assert_eq!(
            guest_row.host_kind, "linux",
            "KNOWN GAP (809-7e4m): the context is linux, the machine is windows"
        );
    }

    /// 808-43mw's `verifiable_closure`, executed rather than asserted:
    /// "a capability document round-trips a host_id, and a measurement carries
    /// suite + locus; two documents from different loci are machine-
    /// distinguishable without reading any prose".
    #[test]
    fn closure_808_43mw_documents_are_machine_distinguishable_by_host_and_locus() {
        let measured_at = |host: &str, locus: &str| CapabilityDocument {
            schema_version: SCHEMA_VERSION,
            legacy_tier: "cpu".to_string(),
            probe_identity: Some(probe_identity()),
            enumeration_gaps: Vec::new(),
            hardware_fingerprint: None,
            render_nodes: Vec::new(),
            envelope_source: Some(EnvelopeSource::Measured),
            devices: Vec::new(),
            engines: Vec::new(),
            measurements: vec![MeasurementRecord {
                device: "cpu".to_string(),
                engine: "ollama".to_string(),
                prefill_tps: Some(1024.0),
                decode_tps: Some(87.0),
                joules_per_token: None,
                degraded: false,
                degraded_reason: None,
                workload_suite: Some("802-2536-v1".to_string()),
                locus: Some(locus.to_string()),
                model: None,
                model_params_b: None,
            }],
            host: HostInfo {
                is_battery_present: Some(true),
                kernel_release: "6.18.33.2-microsoft-standard-WSL2".to_string(),
                host_id: host.to_string(),
                host_id_source: "node-name".to_string(),
                host_kind: "linux".to_string(),
                side: Some("native-linux".to_string()),
            },
            timestamp: "1970-01-01T00:00:00Z".to_string(),
        };

        // (a) the document round-trips its host_id through JSON
        let yolanda = measured_at("yolanda", "in-guest");
        let json = serde_json::to_string(&yolanda).expect("serializes");
        let back: CapabilityDocument = serde_json::from_str(&json).expect("round-trips");
        assert_eq!(back, yolanda);
        assert_eq!(back.host.host_id, "yolanda");

        // (b) the measurement carries suite AND locus
        let m = &back.measurements[0];
        assert_eq!(m.workload_suite.as_deref(), Some("802-2536-v1"));
        assert_eq!(m.locus.as_deref(), Some("in-guest"));

        // (c) two documents at different loci differ in a MACHINE-READABLE
        //     field — not merely in a comment a human has to notice.
        let mirrored = measured_at("yolanda", "host-side-via-mirror");
        assert_eq!(
            yolanda.host.host_id, mirrored.host.host_id,
            "same machine, so the fold key must agree"
        );
        assert_ne!(
            yolanda.measurements[0].locus, mirrored.measurements[0].locus,
            "and the locus is what tells a consumer these are not comparable"
        );

        // (d) and two machines sharing a kernel remain separable
        let esmeraldinha = measured_at("esmeraldinha", "in-guest");
        assert_eq!(
            yolanda.host.kernel_release,
            esmeraldinha.host.kernel_release
        );
        assert_ne!(yolanda.host.host_id, esmeraldinha.host.host_id);
    }

    #[test]
    // @trace order:803-825k, spec:accel-capability-probe
    fn test_enumerate_engines_empty_when_no_engine_available() {
        let engines = enumerate_engines_with(|_| false, || false);
        assert!(
            engines.is_empty(),
            "a host with no inference engine installed must not advertise any engine records"
        );
    }

    #[test]
    // @trace order:803-825k, spec:accel-capability-probe
    fn test_enumerate_engines_detects_ollama_and_llama_server() {
        let only_ollama = enumerate_engines_with(|bin| bin == "ollama", || false);
        assert_eq!(only_ollama.len(), 1);
        assert_eq!(only_ollama[0].name, "ollama");
        assert_eq!(only_ollama[0].backend, "llama-server");
        assert_eq!(only_ollama[0].supported_device_classes, vec!["cpu", "gpu"]);
        assert_eq!(
            only_ollama[0].lanes, None,
            "host-PATH engines cover every lane"
        );

        let only_llama = enumerate_engines_with(|bin| bin == "llama-server", || false);
        assert_eq!(only_llama.len(), 1);
        assert_eq!(only_llama[0].name, "llama-server");
        assert_eq!(only_llama[0].backend, "llama.cpp");
        assert_eq!(only_llama[0].supported_device_classes, vec!["cpu", "gpu"]);

        let both = enumerate_engines_with(|bin| bin == "ollama" || bin == "llama-server", || false);
        assert_eq!(both.len(), 2);
        assert_eq!(both[0].name, "ollama");
        assert_eq!(both[1].name, "llama-server");
    }

    #[test]
    // @trace order:850-bif2, spec:accel-capability-probe
    fn test_containerized_engine_is_container_lane_only_and_never_shadows_host_ollama() {
        // The inference image present with no host binaries: one ollama
        // record, scoped to the container lane. This is the record whose
        // absence made a usable RTX A5000 read "schedulable: none".
        let containerized = enumerate_engines_with(|_| false, || true);
        assert_eq!(containerized.len(), 1);
        assert_eq!(containerized[0].name, "ollama");
        assert_eq!(
            containerized[0].lanes,
            Some(vec!["container".to_string()]),
            "an engine inside an image must not claim host-native reach"
        );

        // Host ollama present too: the host record (all lanes) wins and the
        // container record is not duplicated.
        let host_wins = enumerate_engines_with(|bin| bin == "ollama", || true);
        assert_eq!(host_wins.len(), 1);
        assert_eq!(host_wins[0].lanes, None);
    }

    /// ORDER 1011-zp59 — THE TWO-HOST ARM, plus the one that makes it mean
    /// something.
    ///
    /// The packet names scripts/test-capability-row-check.sh as the home for
    /// this. It is not: that fixture drives check-capability-row.sh and tests
    /// whether a row is PRESENT and FRESH, which is a different property from
    /// how a device is CLASSIFIED, and it cannot reach this decision without
    /// fabricating a sysfs tree for the Rust probe to walk. The discriminator
    /// is a pure function, so it is pinned where it lives. Recorded rather than
    /// silently relocated.
    ///
    /// Arm 3 is the one I asked for and the reason the tier label is not the
    /// key. `effective_inference_tier()` downgrades gpu-cuda to cpu when no CDI
    /// spec exists; on that host the iGPU is the ONLY accelerator. Keying on
    /// `tier == gpu-cuda` would stamp "deliberately not scheduled, the discrete
    /// card is better" onto the best device the host has. Arm 3 fails against
    /// that implementation and passes against this one, which is the only
    /// reason arms 1 and 2 are worth having.
    #[test]
    // @trace order:1011-zp59, spec:accel-capability-probe
    fn igpu_beside_a_schedulable_discrete_card_is_policy_unscheduled() {
        // ARM 1 — lenovinha. Integrated part, discrete card present and
        // schedulable: the policy reason fires and carries its measurement.
        let r = igpu_policy_unscheduled_reason(true, true);
        let reason = r.expect("an iGPU beside a schedulable discrete card is policy-unscheduled");
        assert!(
            reason.starts_with("policy:discrete-gpu-preferred"),
            "the reason must name the policy first; got {reason}"
        );
        assert!(
            reason.contains("size_vram==size"),
            "the reason must carry the fully-resident clause, or the ratio reads \
             as a partial-offload artefact rather than a fair comparison; got {reason}"
        );

        // ARM 2 — yoga. The integrated GPU is the ONLY GPU. Classification is
        // unchanged: nothing better exists, so nothing deprioritises it.
        assert_eq!(
            igpu_policy_unscheduled_reason(true, false),
            None,
            "a host whose only GPU is integrated must be untouched by this rule"
        );

        // ARM 3 — the discrete card itself is never policy-unscheduled by its
        // own presence.
        assert_eq!(igpu_policy_unscheduled_reason(false, true), None);
    }

    /// ORDER 1011-zp59 — THE CDI-ABSENT HOST. This is the arm that
    /// discriminates this implementation from a tier-keyed one, and it has to
    /// live here rather than beside arms 1-3: `igpu_policy_unscheduled_reason`
    /// takes a BOOLEAN, so "no discrete card" and "a discrete card that cannot
    /// be scheduled" are the same input to it and asserting the case there
    /// would be a test passing for a reason other than the one it names.
    #[test]
    // @trace order:1011-zp59, spec:accel-capability-probe
    fn a_present_but_unschedulable_discrete_card_deprioritises_nothing() {
        fn gpu(usable: bool, lanes: Vec<String>, mm: &str) -> DeviceRecord {
            DeviceRecord {
                device_class: "gpu".to_string(),
                vendor: "nvidia".to_string(),
                name: "test dGPU".to_string(),
                device_node: None,
                fw_version: None,
                driver: None,
                usable,
                unusable_reason: None,
                policy_unscheduled: None,
                lanes,
                memory_bandwidth_gbps: None,
                memory_bandwidth_source: "unknown".to_string(),
                cpu_flags: None,
                cpu_cores: None,
                system_ram_gb: None,
                memory_model: Some(mm.to_string()),
                // 1137-rgfm: None = this fixture states no provenance, so the
                // pre-field deny-list still judges it, exactly as before.
                name_source: None,
            }
        }

        // The positive control: a usable discrete card with a lane IS
        // schedulable, or the negatives below would pass vacuously.
        assert!(
            discrete_gpu_is_schedulable(&[gpu(true, vec!["container".to_string()], "discrete")]),
            "a usable discrete card with a lane must count as schedulable"
        );

        // THE CDI-ABSENT HOST. effective_inference_tier() downgrades gpu-cuda
        // to cpu when no CDI spec exists. The card is PRESENT and unusable, so
        // the integrated part is the best lane the host has and must not be
        // labelled deliberately-deprioritised.
        assert!(
            !discrete_gpu_is_schedulable(&[gpu(false, vec!["container".to_string()], "discrete")]),
            "a present-but-unusable discrete card must not deprioritise the iGPU"
        );

        // Usable but with no lane proven is equally not a better option.
        assert!(
            !discrete_gpu_is_schedulable(&[gpu(true, vec![], "discrete")]),
            "a discrete card with no lane must not deprioritise the iGPU"
        );

        // And an integrated card never deprioritises another integrated card.
        assert!(
            !discrete_gpu_is_schedulable(&[gpu(true, vec!["container".to_string()], "unified")]),
            "only a DISCRETE card may deprioritise the integrated one"
        );
    }

    #[test]
    // @trace order:850-bif2, spec:accel-capability-probe
    fn test_amd_gpu_disposition_fails_closed_without_rocm_runtime() {
        // rocm-smi presence alone is not evidence; without a gfx agent the
        // device is present-unusable with the reason named.
        let (usable, lanes, reason) = amd_gpu_disposition(false, true, true);
        assert!(!usable);
        assert_eq!(lanes, vec!["host-native"]);
        assert_eq!(reason.as_deref(), Some("rocm-runtime-missing"));

        let (usable, _, reason) = amd_gpu_disposition(true, false, true);
        assert!(!usable);
        assert_eq!(reason.as_deref(), Some("kfd-missing"));

        let (usable, lanes, reason) = amd_gpu_disposition(true, true, false);
        assert!(!usable);
        assert!(lanes.is_empty(), "no render node = no lane to reach it on");
        assert_eq!(reason.as_deref(), Some("render-node-missing"));

        // ORDER 793-zumy: THIS ASSERTION CHANGED, AND IT WAS PINNING THE DEFECT.
        //
        // It previously required lanes == ["container", "host-native"] and
        // reason == None for a host with rocm + kfd + a render node. All three
        // of those inputs are read FROM THE HOST, and yoga measured 2026-08-30
        // that a host satisfying all three had, inside the container that
        // actually runs inference: no /dev/kfd, no /dev/dri, size_vram=0.00GB
        // for every model, and a runtime reporting library=cpu. After the
        // device nodes WERE passed in, size_vram was still 0.00GB because the
        // image ships no ROCm backend.
        //
        // So the old expectation encoded exactly the substitution this packet
        // exists to end — host evidence standing in for a container-lane claim
        // — and a test asserting it made the defect look verified. Updating it
        // is the point, not collateral: the probe now reports the lane it can
        // prove and NAMES the one it cannot.
        let (usable, lanes, reason) = amd_gpu_disposition(true, true, true);
        assert!(usable, "the DEVICE is usable — that part was never wrong");
        assert_eq!(
            lanes,
            vec!["host-native"],
            "a host-vantage probe cannot claim the container lane"
        );
        assert_eq!(
            reason.as_deref(),
            Some("container-lane-unverified"),
            "and it must SAY the lane is unverified rather than silently omit it"
        );
    }

    #[test]
    // @trace order:855-wrr3, spec:accel-capability-probe
    fn test_intel_gpu_disposition_fails_closed_without_a_compute_runtime() {
        // A render node is a DISPLAY driver, not a compute lane. Without an
        // Intel compute runtime the device is present-unusable, reason named.
        let (usable, lanes, reason) = intel_gpu_disposition(false, true);
        assert!(!usable);
        assert_eq!(lanes, vec!["host-native"]);
        assert_eq!(reason.as_deref(), Some("intel-compute-runtime-missing"));

        let (usable, lanes, reason) = intel_gpu_disposition(true, false);
        assert!(!usable);
        assert!(lanes.is_empty(), "no render node = no lane to reach it on");
        assert_eq!(reason.as_deref(), Some("render-node-missing"));

        let (usable, lanes, reason) = intel_gpu_disposition(true, true);
        assert!(usable);
        assert_eq!(lanes, vec!["container", "host-native"]);
        assert_eq!(reason, None);
    }

    #[test]
    // @trace order:852-dk9z, spec:accel-capability-probe
    fn test_cache_from_different_probe_code_is_reprobed_not_served() {
        let _seam = podman_seam();
        // The 852-dk9z regression, measured twice for real: a rebuilt binary
        // served its predecessor's document because schema_version and
        // legacy_tier both still matched. Stamp a cache with a FOREIGN probe
        // identity and it must be re-probed.
        let dir = tempfile::tempdir().expect("tempdir");
        let cache = dir.path().join("capabilities.json");

        let mut stale = run_probe("cpu");
        stale.probe_identity = Some("0.0.0+deadbeefdeadbeef".to_string());
        stale.legacy_tier = "cpu".to_string();
        // A marker the real probe can never produce, so "served from cache" is
        // distinguishable from "re-probed and happened to look the same".
        stale.host.host_id = "STALE-CACHE-MARKER".to_string();
        fs::write(&cache, serde_json::to_string_pretty(&stale).unwrap()).unwrap();

        let got = load_or_probe_at(&cache, "cpu", Freshness::Cached);
        assert_ne!(
            got.host.host_id, "STALE-CACHE-MARKER",
            "a document from different probe code must never be served"
        );
        assert_eq!(
            got.probe_identity.as_deref(),
            Some(probe_identity().as_str())
        );

        // And a pre-852-dk9z cache (no identity at all) is likewise refused.
        let mut legacy = run_probe("cpu");
        legacy.probe_identity = None;
        legacy.host.host_id = "LEGACY-CACHE-MARKER".to_string();
        fs::write(&cache, serde_json::to_string_pretty(&legacy).unwrap()).unwrap();
        let got = load_or_probe_at(&cache, "cpu", Freshness::Cached);
        assert_ne!(got.host.host_id, "LEGACY-CACHE-MARKER");
    }

    #[test]
    // @trace order:852-dk9z, spec:accel-capability-probe
    fn test_negative_control_unchanged_binary_still_serves_its_own_cache() {
        let _seam = podman_seam();
        // The cache must keep working for the server's hot path — this fix is
        // an invalidation rule, not a removal.
        let dir = tempfile::tempdir().expect("tempdir");
        let cache = dir.path().join("capabilities.json");

        let mut mine = run_probe("cpu");
        mine.host.host_id = "MY-OWN-CACHE".to_string();
        assert_eq!(
            mine.probe_identity.as_deref(),
            Some(probe_identity().as_str())
        );
        fs::write(&cache, serde_json::to_string_pretty(&mine).unwrap()).unwrap();

        let got = load_or_probe_at(&cache, "cpu", Freshness::Cached);
        assert_eq!(
            got.host.host_id, "MY-OWN-CACHE",
            "same probe identity must still hit the cache"
        );

        // ...and Freshness::Force ignores it, which is what publication uses.
        let got = load_or_probe_at(&cache, "cpu", Freshness::Force);
        assert_ne!(got.host.host_id, "MY-OWN-CACHE");
    }

    #[test]
    // @trace order:855-wrr3, spec:accel-capability-probe
    fn test_intel_igpu_with_only_a_render_node_is_not_a_workstation_gpu() {
        // The live regression from order 855-wrr3: host pirria, a 4-core
        // Alder Lake-N N150 that is the fleet's declared LOWER BOUND, published
        // accel_class=workstation-gpu because /dev/dri/renderD128 exists — while
        // the same binary's --inference-tier answered `tier:cpu` and the engine
        // reported initial_count=0 devices, total_vram=0 B.
        let mut d = device(
            "gpu",
            "Alder Lake-N [Intel Graphics]",
            &["host-native"],
            Some("intel-compute-runtime-missing"),
        );
        d.usable = false;
        let env = accel_envelope(&doc_with(vec![d]));
        assert!(env.contains("accel_class=cpu-only"), "{env}");
        assert!(env.contains("accel_gpu=present-unusable"), "{env}");
        assert!(
            env.contains("accel_reason=intel-compute-runtime-missing"),
            "{env}"
        );
    }

    #[test]
    // @trace order:850-bif2, spec:accel-capability-probe
    // EXIT CRITERION 4 (negative control): a host with no accelerator still
    // produces a VALID document — a CPU device and a named host — rather
    // than an empty or absent one. Silence and "nothing here" must stay
    // distinguishable; this runs on every host that gates a push.
    fn test_cpu_only_probe_yields_a_valid_document_not_silence() {
        let _seam = podman_seam();
        let doc = run_probe("cpu");
        assert_eq!(doc.schema_version, SCHEMA_VERSION);
        assert!(
            doc.devices.iter().any(|d| d.device_class == "cpu"),
            "even an accelerator-less host records its CPU"
        );
        assert!(
            !doc.host.host_id.is_empty() && doc.host.host_id != "unknown",
            "a row without a host_id folds to nothing in the matrix"
        );
        let json = serde_json::to_string(&doc).expect("document serializes");
        assert!(json.contains(&format!("\"schema_version\":{SCHEMA_VERSION}")));
        // Order 793-qr4t: the side is part of what makes the document valid
        // rather than merely well-formed. A row that cannot say where it was
        // probed cannot have its `none`s read, which is the whole finding.
        assert!(
            doc.host.side.is_some(),
            "a document must state which side produced it"
        );
    }

    // ================================================================
    // Order 793-qr4t — the envelope is side- and engine-qualified.
    // ================================================================

    fn field<'a>(env: &'a str, key: &str) -> &'a str {
        env.split(' ')
            .find_map(|f| f.strip_prefix(&format!("{key}=")))
            .unwrap_or_else(|| panic!("envelope has no {key}: {env}"))
    }

    fn doc_on_side(side: &str, devices: Vec<DeviceRecord>) -> CapabilityDocument {
        let mut d = doc_with(devices);
        d.host.side = Some(side.to_string());
        d
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// EXIT CRITERION 1, both halves in one test because the criterion is the
    /// DISTINCTION and either half alone is satisfiable by a blanket relabel.
    ///
    /// The guest case is measured: an XDNA2 NPU healthy on the Windows side
    /// (VEN_1022&DEV_17F0, driver 32.0.20102.3930) reported `accel_npu=none`
    /// in the WSL2 guest, because `enumerate_npus` reads `/sys/class/accel`
    /// and a WSL2 kernel has no accel class. `none` reads as "this machine
    /// cannot do NPU work", which is false and mis-plans a whole tier.
    fn an_accelerator_across_a_boundary_is_unobservable_never_none() {
        let guest = doc_on_side(
            "wsl2-guest",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        assert_eq!(
            field(&accel_envelope(&guest), "accel_npu"),
            "unobservable-from-this-side",
            "a guest's enumeration is evidence about the guest, not the machine"
        );

        let native = doc_on_side(
            "native-linux",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        assert_eq!(
            field(&accel_envelope(&native), "accel_npu"),
            "none",
            "a native host that looked and found nothing keeps its affirmative denial"
        );
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// The THIRD absent-state, kept distinct from the other two.
    ///
    /// tlatoanis-macbook-air's correction, and it is the reason this is not a
    /// two-value field: the Apple Neural Engine is present, CoreML-drivable and
    /// on the SAME side as the probe. `unobservable-from-this-side` would be as
    /// false there as `none` is. It is `unknown` — recorded as an enumeration
    /// gap — because the probe has no arm for that platform.
    fn a_same_side_device_the_probe_cannot_look_for_is_unknown_not_unobservable() {
        let mut mac = doc_on_side(
            "macos-host",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        mac.enumeration_gaps.push("npu".to_string());
        let env = accel_envelope(&mac);
        assert_eq!(field(&env, "accel_npu"), "unknown", "{env}");
        assert_eq!(
            field(&env, "accel_reason"),
            "npu-not-enumerable-on-this-platform",
            "cpu-only is never a bare verdict: {env}"
        );
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// EXIT CRITERION 2. "No GPU here", "a GPU with no driver stack", and "a
    /// GPU that belongs to the other side" are three different engineering
    /// problems — buy hardware, ship a lane, cross a boundary — and the
    /// envelope collapsed all three into one token.
    fn no_gpu_a_driverless_gpu_and_a_far_side_gpu_are_three_answers() {
        let none = doc_on_side(
            "native-linux",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        let env = accel_envelope(&none);
        assert_eq!(field(&env, "accel_gpu"), "none");
        assert_eq!(field(&env, "accel_gpu_engine"), "none", "{env}");

        // A real, container-deliverable GPU that nothing can drive. This is
        // macuahuitl's row: a usable RTX A5000 with `engines: []`, which the
        // matrix rendered as `schedulable: none` while ollama was serving
        // models on that very machine.
        let driverless = doc_on_side(
            "native-linux",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "NVIDIA RTX A5000", &["container"], None),
            ],
        );
        let env = accel_envelope(&driverless);
        assert_eq!(field(&env, "accel_gpu"), "usable");
        assert_eq!(
            field(&env, "accel_gpu_engine"),
            "engine-missing",
            "a present device nothing can drive must say so: {env}"
        );

        let far = doc_on_side(
            "container",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        assert_eq!(
            field(&accel_envelope(&far), "accel_gpu"),
            "unobservable-from-this-side"
        );
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// The engine is named when we recognise it and slugged when we do not.
    ///
    /// An unrecognised engine forced into the nearest known bucket would be
    /// the confident half-answer this packet exists to remove — and `ollama`,
    /// the engine on the host that implemented this, is exactly such a case.
    fn a_recognised_engine_is_named_and_an_unrecognised_one_keeps_its_own_slug() {
        let mut d = doc_on_side(
            "native-linux",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "Radeon", &["container"], None),
            ],
        );
        d.engines.push(EngineRecord {
            name: "llama.cpp".to_string(),
            backend: "rocm".to_string(),
            supported_device_classes: vec!["gpu".to_string()],
            lanes: None,
        });
        assert_eq!(field(&accel_envelope(&d), "accel_gpu_engine"), "rocm");

        d.engines[0] = EngineRecord {
            name: "ollama".to_string(),
            backend: "container".to_string(),
            supported_device_classes: vec!["gpu".to_string()],
            lanes: Some(vec!["container".to_string()]),
        };
        assert_eq!(field(&accel_envelope(&d), "accel_gpu_engine"), "ollama");
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// EXIT CRITERION 3. The envelope emits exactly ONE memory number, so a
    /// 522 sizing consumer has nothing to add to it.
    ///
    /// Measured on windows/Yolanda: `accel_ram_gb=7` (the guest's slice) beside
    /// a dzn-advertised 7.58 GiB DEVICE_LOCAL heap — the same physical DRAM
    /// counted twice, and neither of them the machine's installed 15.2 GB.
    fn a_unified_node_publishes_one_budget_and_declares_itself_unified() {
        // Apple silicon: unified BY CONSTRUCTION, with no discrete alternative
        // to confuse it with, and no sysfs for the evidence ladder to read — so
        // it is the one architectural assertion the renderer still makes.
        let mut mac = doc_on_side(
            "macos-host",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "Apple Metal GPU", &["container"], None),
            ],
        );
        mac.devices[1].vendor = "apple".to_string();
        let env = accel_envelope(&mac);
        assert_eq!(field(&env, "accel_mem_model"), "unified", "{env}");
        assert_eq!(
            env.split(' ')
                .filter(|f| f.starts_with("accel_mem_budget_gb=") || f.starts_with("accel_ram_gb="))
                .count(),
            2,
            "exactly one budget, rendered under both the old and the new key: {env}"
        );

        let mut nv = doc_on_side(
            "native-linux",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "RTX 3070", &["container"], None),
            ],
        );
        nv.devices[1].vendor = "nvidia".to_string();
        nv.devices[1].memory_model = Some("discrete".to_string());
        assert_eq!(field(&accel_envelope(&nv), "accel_mem_model"), "discrete");

        // An AMD/Intel DRM device is genuinely undecidable from what
        // DeviceRecord records — no VRAM size, no integrated flag — and
        // `unknown` is the answer that keeps a consumer from summing.
        // Order 964-r98h moved this from a VENDOR question to an EVIDENCE
        // question. An AMD device whose record carries no classification is
        // `undetermined` — the classifier ran and refused — which is a
        // different fact from `unobservable-from-this-side` (it could not run)
        // and from `no-gpu` (there was nothing to classify).
        let mut amd = nv.clone();
        amd.devices[1].vendor = "amd".to_string();
        amd.devices[1].memory_model = None;
        assert_eq!(
            field(&accel_envelope(&amd), "accel_mem_model"),
            "undetermined"
        );
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// The side is read from the DOCUMENT, so a transported row keeps its own
    /// facts — the same property `enumeration_gaps` already has, and the
    /// reason the fleet matrix can fold rows probed elsewhere at all.
    fn a_pre_schema3_document_reads_unknown_side_never_a_default() {
        let mut old = doc_with(vec![device("cpu", "cpu", &["container"], None)]);
        old.host.side = None;
        assert_eq!(accel_side(&old), "unknown-side");
        // And it must NOT thereby become a boundary side: a document that does
        // not say where it stood cannot have its absences upgraded.
        assert_eq!(field(&accel_envelope(&old), "accel_npu"), "none");
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// The WSL2 test wants BOTH signals. `/dev/dxg` alone is the node the GPU
    /// arm reads, so reusing it would make the SIDE depend on whether a GPU
    /// happened to be paravirtualised; a `microsoft` kernel release alone is
    /// the string two WSL2 guests already share verbatim and survives into any
    /// image built from that kernel.
    fn side_evidence_needs_both_signals_and_container_wins_the_innermost() {
        assert_eq!(
            side_from_evidence(false, true, "6.18.33.2-microsoft-standard-WSL2"),
            "wsl2-guest"
        );
        assert_eq!(
            side_from_evidence(false, true, "6.16.4-200.fc44.x86_64"),
            "native-linux"
        );
        assert_eq!(
            side_from_evidence(false, false, "6.18.33.2-microsoft-standard-WSL2"),
            "native-linux"
        );
        // A forge inside a container on a WSL2 guest is both, and the answer a
        // consumer needs is the INNERMOST boundary — that is the one whose far
        // side holds the devices it cannot reach.
        assert_eq!(
            side_from_evidence(true, true, "6.18.33.2-microsoft-standard-WSL2"),
            "container"
        );
    }

    // ================================================================
    // Order 793-qc6q — per-phase routing from measured crossovers.
    // ================================================================

    fn decode_row(device: &str, params_b: f64, tps: f64) -> MeasurementRecord {
        MeasurementRecord {
            device: device.to_string(),
            engine: "ollama".to_string(),
            prefill_tps: None,
            decode_tps: Some(tps),
            joules_per_token: None,
            degraded: false,
            degraded_reason: None,
            workload_suite: Some("802-2536-v1".to_string()),
            locus: Some("in-guest".to_string()),
            model: Some(format!("qwen2.5:{params_b}b")),
            model_params_b: Some(params_b),
        }
    }

    /// A host whose GPU is both container-deliverable and driveable.
    fn schedulable_gpu_doc() -> CapabilityDocument {
        let mut d = doc_on_side(
            "wsl2-guest",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "Radeon 860M", &["container"], None),
            ],
        );
        d.engines.push(EngineRecord {
            name: "ollama".to_string(),
            backend: "vulkan-dozen".to_string(),
            supported_device_classes: vec!["gpu".to_string()],
            lanes: Some(vec!["container".to_string()]),
        });
        d
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// EXIT CRITERION 1. The measured numbers are windows/Yolanda's, medians
    /// of 3 unique-prompt reps on ollama 0.32.9: decode 0.5B is CPU 78.68 vs
    /// GPU 63.75 t/s (the CPU wins by 1.23x) and decode 3B is CPU 19.64 vs GPU
    /// 26.96 (the GPU wins by 1.37x). Routing 0.5B decode to the iGPU is a
    /// silent 1.23x REGRESSION on exactly the model class the semantic-layer
    /// floor work depends on.
    fn a_small_models_decode_is_not_sent_to_the_igpu() {
        let mut d = schedulable_gpu_doc();
        d.measurements = vec![
            decode_row("cpu", 0.5, 78.68),
            decode_row("gpu", 0.5, 63.75),
            decode_row("cpu", 3.0, 19.64),
            decode_row("gpu", 3.0, 26.96),
        ];
        assert_eq!(decode_crossover_b(&d), DecodeCrossover::AtOrAbove(3.0));

        let small = route_phase(&d, Phase::Decode, Some(0.5), RoutingLocus::Container);
        assert_eq!(small.device, "cpu", "{}", small.reason);
        let large = route_phase(&d, Phase::Decode, Some(3.0), RoutingLocus::Container);
        assert_eq!(large.device, "gpu", "{}", large.reason);

        // Prefill is compute-bound and goes to the accelerator at BOTH sizes —
        // which is the point of routing per phase rather than per host: the
        // same host and the same 0.5B model want different devices for the two
        // phases.
        assert_eq!(
            route_phase(&d, Phase::Prefill, Some(0.5), RoutingLocus::Container).device,
            "gpu"
        );
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// EXIT CRITERION 4: the threshold is DERIVED, so it moves when the
    /// measurements move. A hard-coded 1.5 would pass the test above and fail
    /// this one — that is the whole reason this test exists beside it.
    fn the_crossover_follows_the_measurements_and_is_never_a_constant() {
        let mut d = schedulable_gpu_doc();
        // A machine whose GPU wins decode from 1B upward.
        d.measurements = vec![
            decode_row("cpu", 0.5, 80.0),
            decode_row("gpu", 0.5, 60.0),
            decode_row("cpu", 1.0, 40.0),
            decode_row("gpu", 1.0, 55.0),
        ];
        assert_eq!(decode_crossover_b(&d), DecodeCrossover::AtOrAbove(1.0));
        assert_eq!(
            route_phase(&d, Phase::Decode, Some(1.0), RoutingLocus::Container).device,
            "gpu"
        );

        // A machine where the CPU wins at every size measured. Distinct from
        // never having looked, and it must not become a licence to guess.
        d.measurements = vec![
            decode_row("cpu", 0.5, 80.0),
            decode_row("gpu", 0.5, 60.0),
            decode_row("cpu", 3.0, 20.0),
            decode_row("gpu", 3.0, 15.0),
        ];
        assert_eq!(decode_crossover_b(&d), DecodeCrossover::CpuWinsThroughout);
        assert_eq!(
            route_phase(&d, Phase::Decode, Some(70.0), RoutingLocus::Container).device,
            "cpu"
        );

        // An unmeasured host: the GPU is usable and decode still goes to the
        // CPU, because the only threshold available would be a constant.
        let unmeasured = schedulable_gpu_doc();
        assert_eq!(decode_crossover_b(&unmeasured), DecodeCrossover::Unmeasured);
        let p = route_phase(
            &unmeasured,
            Phase::Decode,
            Some(3.0),
            RoutingLocus::Container,
        );
        assert_eq!(p.device, "cpu");
        assert_eq!(
            p.reason,
            "decode-crossover-unmeasured-on-this-host-in-container"
        );

        // A degraded run is evidence the run went wrong, not evidence about
        // the device; folding it in would move a threshold on a failure.
        let mut degraded = schedulable_gpu_doc();
        degraded.measurements = vec![decode_row("cpu", 3.0, 19.64), {
            let mut m = decode_row("gpu", 3.0, 26.96);
            m.degraded = true;
            m.degraded_reason = Some("cold-load-stall".to_string());
            m
        }];
        assert_eq!(decode_crossover_b(&degraded), DecodeCrossover::Unmeasured);
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// EXIT CRITERION 2 (620-ca7g preserved). There is no input that yields a
    /// device this host cannot run on. The doc below has no accelerator, no
    /// engine and no measurement — the worst case — and every phase still
    /// lands somewhere runnable.
    fn the_cpu_is_the_floor_for_every_phase_and_no_accelerator_is_ever_required() {
        let bare = doc_on_side(
            "native-linux",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        for phase in [Phase::Prefill, Phase::Decode, Phase::Embed, Phase::Rerank] {
            let p = route_phase(&bare, phase, Some(70.0), RoutingLocus::Container);
            assert_eq!(p.device, "cpu", "{phase:?} must fall to the floor");
            assert!(
                !p.reason.is_empty() && p.reason != "-",
                "EXIT CRITERION 3: a fallback is never silent, {phase:?} said {:?}",
                p.reason
            );
        }
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// A device with a container lane and NO engine is not a routing target.
    ///
    /// This is 793-qr4t's engine-qualification being consumed rather than
    /// merely published. Routing that read only the lane would send work to
    /// macuahuitl's RTX A5000 and land on the same `library=cpu` silence that
    /// cost windows/Yolanda a day.
    fn a_lane_without_an_engine_is_not_a_routing_target() {
        let mut d = schedulable_gpu_doc();
        d.engines.clear();
        d.measurements = vec![decode_row("cpu", 3.0, 19.64), decode_row("gpu", 3.0, 26.96)];
        let p = route_phase(&d, Phase::Decode, Some(3.0), RoutingLocus::Container);
        assert_eq!(p.device, "cpu", "{}", p.reason);
        assert_eq!(p.reason, "no-usable-gpu-for-decode-in-container");
        assert_eq!(
            route_phase(&d, Phase::Prefill, None, RoutingLocus::Container).device,
            "cpu"
        );
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// Embed NEVER goes to the GPU, and the guard is unconditional rather than
    /// conditioned on `accel_mem_model` reaching `unified` — which it does not
    /// on any AMD or Intel DRM host, i.e. on exactly the host the measurement
    /// (CPU 8.7ms vs GPU 10.2ms) came from.
    fn embed_never_reaches_the_gpu_even_on_a_host_whose_memory_model_is_unknown() {
        let mut d = schedulable_gpu_doc();
        d.measurements = vec![decode_row("cpu", 0.5, 60.0), decode_row("gpu", 0.5, 90.0)];
        // Not `unified` — this WSL2 row cannot reach the evidence at all — and
        // the embed guard must hold anyway. That is the point of it being
        // unconditional rather than keyed on the memory model.
        assert_eq!(
            field(&accel_envelope(&d), "accel_mem_model"),
            "unobservable-from-this-side"
        );
        let p = route_phase(&d, Phase::Embed, Some(0.5), RoutingLocus::Container);
        assert_eq!(p.device, "cpu", "{}", p.reason);
    }

    /// A row measured somewhere other than [`decode_row`]'s `in-guest`.
    fn decode_row_at(locus: &str, device: &str, params_b: f64, tps: f64) -> MeasurementRecord {
        let mut m = decode_row(device, params_b, tps);
        m.locus = Some(locus.to_string());
        m
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// THE macOS CASE, and the defect this locus parameter was added for.
    ///
    /// Metal is real, driveable and wins both phases — host-native. A forge
    /// container cannot reach it, so the document says so, and that record is
    /// CORRECT. What was wrong was the question: routing hard-coded the
    /// container lane, believed the accurate container-lane answer, and sent
    /// both phases to the CPU on a host whose GPU wins decode 1.27-1.64x and
    /// prefill 3.2-3.8x (measured 2026-09-03, the fleet's only unified-memory
    /// host). The same document must now answer both questions differently.
    fn a_host_native_accelerator_is_invisible_to_the_container_question_and_not_to_its_own() {
        let mut d = doc_on_side(
            "native-macos",
            vec![
                device("cpu", "Apple M-series", &["container", "host-native"], None),
                // Present and perfectly usable — on the host side only.
                device("gpu", "Apple M-series GPU", &["host-native"], None),
            ],
        );
        d.engines.push(EngineRecord {
            name: "ollama".to_string(),
            backend: "metal".to_string(),
            supported_device_classes: vec!["gpu".to_string()],
            lanes: Some(vec!["host-native".to_string()]),
        });
        d.measurements = vec![
            decode_row("cpu", 0.5, 60.0),
            decode_row("gpu", 0.5, 76.2), // 1.27x, and it holds at 0.5B here
        ];

        // The container question. `cpu` is the RIGHT answer for a forge, and
        // the reason must say which lane decided it — otherwise this is
        // indistinguishable from a host with no GPU at all, which is exactly
        // how the defect stayed invisible.
        let in_container = route_phase(&d, Phase::Decode, Some(0.5), RoutingLocus::Container);
        assert_eq!(in_container.device, "cpu", "{}", in_container.reason);
        assert_eq!(in_container.reason, "no-usable-gpu-for-decode-in-container");
        assert_eq!(
            route_phase(&d, Phase::Prefill, None, RoutingLocus::Container).device,
            "cpu"
        );

        // The host-native question, same document, same instant.
        let host_native = route_phase(&d, Phase::Decode, Some(0.5), RoutingLocus::HostNative);
        assert_eq!(host_native.device, "gpu", "{}", host_native.reason);
        assert!(
            host_native.reason.ends_with("-in-host-native"),
            "the lane belongs in the reason: {:?}",
            host_native.reason
        );
        assert_eq!(
            route_phase(&d, Phase::Prefill, None, RoutingLocus::HostNative).device,
            "gpu"
        );
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// AN ENGINE IS LANE-BOUND TOO, and checking only the device would move
    /// the defect one field along instead of fixing it.
    ///
    /// Here the GPU genuinely reaches both lanes, and the only engine that can
    /// drive it lives in a container. The host-native question therefore has
    /// no answer but the floor — a device with nothing to drive it is not a
    /// target, which is 793-qr4t's rule applied per lane.
    fn a_container_only_engine_does_not_qualify_a_device_for_the_host_native_lane() {
        let mut d = doc_on_side(
            "native-linux",
            vec![
                device("cpu", "cpu", &["container", "host-native"], None),
                device("gpu", "RTX 3070", &["container", "host-native"], None),
            ],
        );
        d.engines.push(EngineRecord {
            name: "ollama".to_string(),
            backend: "cuda".to_string(),
            supported_device_classes: vec!["gpu".to_string()],
            lanes: Some(vec!["container".to_string()]),
        });
        d.measurements = vec![decode_row("cpu", 3.0, 19.64), decode_row("gpu", 3.0, 26.96)];

        assert_eq!(
            route_phase(&d, Phase::Decode, Some(3.0), RoutingLocus::Container).device,
            "gpu"
        );
        let host_native = route_phase(&d, Phase::Decode, Some(3.0), RoutingLocus::HostNative);
        assert_eq!(host_native.device, "cpu", "{}", host_native.reason);
        assert_eq!(
            host_native.reason, "no-usable-gpu-for-decode-in-host-native",
            "EXIT CRITERION 3: the fallback names the lane it was decided in"
        );

        // An engine with no `lanes` at all means EVERY lane — the pre-existing
        // semantics for a host PATH binary. A document filed before 850-bif2
        // must not change meaning under the locus read.
        d.engines[0].lanes = None;
        assert_eq!(
            route_phase(&d, Phase::Decode, Some(3.0), RoutingLocus::HostNative).device,
            "gpu"
        );
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// A CPU ROW AND A GPU ROW FROM DIFFERENT LOCI ARE NOT A PAIR.
    ///
    /// The crossover is a subtraction between two curves, and the hop between
    /// loci costs 5-10% by itself — enough, on this fleet, to have inverted a
    /// reported conclusion once already. Rows here cross at 0.5B if the locus
    /// is ignored and are unpaired the moment it is not, so this test fails
    /// against the pre-793-qc6q derivation and passes against the fixed one.
    fn the_crossover_never_pairs_a_cpu_row_with_a_gpu_row_from_another_locus() {
        let mut d = schedulable_gpu_doc();
        d.measurements = vec![
            decode_row_at("in-guest", "cpu", 0.5, 60.0),
            decode_row_at("host-side-via-mirror", "gpu", 0.5, 76.0),
        ];
        assert_eq!(
            decode_crossover_b(&d),
            DecodeCrossover::Unmeasured,
            "two rows that never met must not become a threshold"
        );
        assert_eq!(
            route_phase(&d, Phase::Decode, Some(0.5), RoutingLocus::Container).device,
            "cpu"
        );

        // Complete the pair WITHIN one locus and the same host is measured.
        d.measurements
            .push(decode_row_at("in-guest", "gpu", 0.5, 76.0));
        assert_eq!(decode_crossover_b(&d), DecodeCrossover::AtOrAbove(0.5));

        // An unattributed row forms its own group rather than joining one:
        // absent is not a value, and pairing it would silently reintroduce the
        // cross-boundary subtraction for exactly the rows nobody labelled.
        let mut unattributed = schedulable_gpu_doc();
        unattributed.measurements = vec![
            {
                let mut m = decode_row("cpu", 0.5, 60.0);
                m.locus = None;
                m
            },
            decode_row_at("in-guest", "gpu", 0.5, 76.0),
        ];
        assert_eq!(
            decode_crossover_b(&unattributed),
            DecodeCrossover::Unmeasured
        );
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// WHEN TWO LOCI DISAGREE, the answer that sends less work to the GPU
    /// wins. 620-ca7g's floor is the standing tie-break: erring toward the CPU
    /// costs a measured fraction, and erring the other way is the silent 1.23x
    /// regression this packet exists to prevent.
    fn disagreeing_loci_resolve_to_the_most_conservative_threshold() {
        let mut d = schedulable_gpu_doc();
        d.measurements = vec![
            // in-guest: the GPU takes the lead at 0.5B.
            decode_row_at("in-guest", "cpu", 0.5, 60.0),
            decode_row_at("in-guest", "gpu", 0.5, 76.0),
            // host-side: it does not lead until 3B.
            decode_row_at("host-side", "cpu", 0.5, 80.0),
            decode_row_at("host-side", "gpu", 0.5, 63.0),
            decode_row_at("host-side", "cpu", 3.0, 19.6),
            decode_row_at("host-side", "gpu", 3.0, 27.0),
        ];
        assert_eq!(decode_crossover_b(&d), DecodeCrossover::AtOrAbove(3.0));

        // And a locus where the CPU wins throughout beats every threshold,
        // because "measured, and the answer is no" is the strongest evidence
        // against routing decode away from the floor.
        d.measurements
            .push(decode_row_at("third-locus", "cpu", 7.0, 10.0));
        d.measurements
            .push(decode_row_at("third-locus", "gpu", 7.0, 8.0));
        assert_eq!(decode_crossover_b(&d), DecodeCrossover::CpuWinsThroughout);
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// The CPU floor survives the locus parameter. 620-ca7g must hold for
    /// EVERY (phase, locus) pair, not just the container lane it was first
    /// tested in — a host-native caller must be no more able to demand an
    /// accelerator than a containerized one.
    fn the_cpu_floor_holds_in_every_locus_and_every_reason_names_its_lane() {
        let bare = doc_on_side(
            "native-linux",
            vec![device("cpu", "cpu", &["container", "host-native"], None)],
        );
        for locus in [RoutingLocus::Container, RoutingLocus::HostNative] {
            for phase in [Phase::Prefill, Phase::Decode, Phase::Embed, Phase::Rerank] {
                let p = route_phase(&bare, phase, Some(70.0), locus);
                assert_eq!(
                    p.device, "cpu",
                    "{phase:?}/{locus:?} must fall to the floor"
                );
                assert!(
                    p.reason.ends_with(&format!("-in-{}", locus.lane())),
                    "EXIT CRITERION 3: {phase:?}/{locus:?} said {:?}, which does not name its lane",
                    p.reason
                );
            }
        }
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// The envelope's routing keys state the POLICY and publish the threshold
    /// beside it, because the renderer does not know a model size.
    fn the_envelope_states_the_policy_and_publishes_the_threshold() {
        let unmeasured = schedulable_gpu_doc();
        let env = accel_envelope(&unmeasured);
        assert_eq!(field(&env, "accel_prefill_dev"), "gpu", "{env}");
        assert_eq!(field(&env, "accel_decode_dev"), "cpu", "{env}");
        assert_eq!(
            field(&env, "accel_decode_crossover_b"),
            "unmeasured",
            "{env}"
        );

        let mut measured = schedulable_gpu_doc();
        measured.measurements = vec![decode_row("cpu", 3.0, 19.64), decode_row("gpu", 3.0, 26.96)];
        let env = accel_envelope(&measured);
        assert_eq!(field(&env, "accel_decode_dev"), "gpu", "{env}");
        assert_eq!(field(&env, "accel_decode_crossover_b"), "3", "{env}");
        assert_eq!(field(&env, "accel_gpu_path"), "dxg-d3d12", "{env}");
        assert_eq!(field(&env, "accel_side"), "wsl2-guest", "{env}");
    }

    // ================================================================
    // Order 964-r98h — a device says whether its memory is its own.
    // ================================================================

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// THE TWO DEVICES IN THIS MACHINE, AS SYSFS ACTUALLY REPORTS THEM, and
    /// they falsify the rule 964-r98h's own context proposed ("mem_info_vram_
    /// total is absent or zero for an integrated part"). It is backwards here:
    /// the DISCRETE card has no such file and the INTEGRATED one has 2 GiB,
    /// because the file belongs to `amdgpu` rather than to dedicated memory and
    /// an APU's BIOS carves a UMA region that amdgpu reports as VRAM.
    ///
    /// A classifier built on that rule would have mislabelled both devices on
    /// this host, in opposite directions, and passed review. This test is the
    /// pin that keeps it from being reintroduced.
    fn the_two_gpus_in_this_machine_classify_from_real_sysfs_values() {
        // card0: NVIDIA RTX 3070. No amdgpu VRAM files at all; an 8192 MiB
        // prefetchable BAR (resizable BAR enabled).
        let rtx3070 = GpuMemoryEvidence {
            vram_total: None,
            vis_vram_total: None,
            largest_prefetchable_bar: Some(8192 * 1024 * 1024),
        };
        assert_eq!(memory_model_from_evidence(&rtx3070), Some("discrete"));

        // card1: AMD Cezanne Vega iGPU. 2 GiB "VRAM", ALL of it CPU-visible,
        // largest prefetchable BAR 256 MiB.
        let vega = GpuMemoryEvidence {
            vram_total: Some(2 * 1024 * 1024 * 1024),
            vis_vram_total: Some(2 * 1024 * 1024 * 1024),
            largest_prefetchable_bar: Some(256 * 1024 * 1024),
        };
        assert_eq!(memory_model_from_evidence(&vega), Some("unified"));
    }

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// The rung that catches a discrete card whose whole VRAM is NOT
    /// CPU-visible — the pre-resizable-BAR configuration, where a 256 MiB
    /// window looks onto 8 GiB. Rung 2 cannot see it (the BAR is small) and
    /// rung 3 would call it unified, so rung 1 has to run first.
    fn a_partially_visible_vram_is_discrete_even_behind_a_small_aperture() {
        let non_rebar_dgpu = GpuMemoryEvidence {
            vram_total: Some(8 * 1024 * 1024 * 1024),
            vis_vram_total: Some(256 * 1024 * 1024),
            largest_prefetchable_bar: Some(256 * 1024 * 1024),
        };
        assert_eq!(
            memory_model_from_evidence(&non_rebar_dgpu),
            Some("discrete"),
            "memory behind an aperture is memory the device owns"
        );
    }

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// EXIT CRITERION 2: no evidence, no answer — and specifically NOT a
    /// vendor-derived guess. This is the case a vendor table would answer for
    /// free and would be wrong about for a discrete Radeon.
    fn a_device_with_no_evidence_refuses_rather_than_guessing() {
        assert_eq!(
            memory_model_from_evidence(&GpuMemoryEvidence::default()),
            None
        );
        // A driver that reports no VRAM never reaches the unified rung, even
        // with a small aperture — a small BAR alone is not evidence of sharing.
        let small_bar_only = GpuMemoryEvidence {
            vram_total: None,
            vis_vram_total: None,
            largest_prefetchable_bar: Some(256 * 1024 * 1024),
        };
        assert_eq!(memory_model_from_evidence(&small_bar_only), None);
        // That case has a NAME, and naming it is the point — see
        // `a_non_rebar_discrete_card_lands_on_undetermined_not_unified`.
        // A zero VRAM total is a driver quirk, not a machine with no memory.
        let zero_vram = GpuMemoryEvidence {
            vram_total: Some(0),
            vis_vram_total: Some(0),
            largest_prefetchable_bar: Some(256 * 1024 * 1024),
        };
        assert_eq!(memory_model_from_evidence(&zero_vram), None);
    }

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// THE ARM I OVERSTATED, made falsifiable rather than fortunate.
    ///
    /// yolanda's question, 2026-09-03: the BAR rung depends on resizable BAR
    /// being ENABLED, which is firmware and driver state rather than a property
    /// of the silicon. Measured on this host, `lspci -vv -s 01:00.0` reports
    /// `Region 1: 64-bit, prefetchable [size=8G]` — ReBAR is on here, so the
    /// discrete arm has been demonstrated against ONE FIRMWARE CONFIGURATION of
    /// the 3070, not against the card.
    ///
    /// The same card with ReBAR disabled: no `mem_info_vram_total` (the
    /// proprietary driver never exports it, so rungs 1 and 3 cannot fire) and a
    /// legacy 256 MiB aperture (below rung 2's floor). It reaches no rung.
    ///
    /// THE FAILURE IS BENIGN AND THAT IS WHAT THIS TEST PINS: it lands on
    /// `undetermined`, which is honest, NOT on `unified`, which would be the
    /// mislabel — and emphatically not on a vendor fallback, which would answer
    /// for it free and correctly and would be the exact trade 964-r98h refused.
    /// The ladder is allowed to be incomplete; it is not allowed to guess.
    fn a_non_rebar_discrete_card_lands_on_undetermined_not_unified() {
        let rtx3070_without_rebar = GpuMemoryEvidence {
            vram_total: None,
            vis_vram_total: None,
            largest_prefetchable_bar: Some(256 * 1024 * 1024),
        };
        assert_eq!(
            memory_model_from_evidence(&rtx3070_without_rebar),
            None,
            "a discrete card the ladder cannot reach must refuse, never guess unified"
        );

        let mut d = doc_on_side(
            "native-linux",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "NVIDIA GeForce RTX 3070", &["container"], None),
            ],
        );
        d.devices[1].vendor = "nvidia".to_string();
        d.devices[1].memory_model = None;
        assert_eq!(
            field(&accel_envelope(&d), "accel_mem_model"),
            "undetermined",
            "and the envelope says the classifier RAN and refused, not that it could not look"
        );
    }

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// The BAR parser reads this host's real `resource` files. A register
    /// window is not an aperture: the RTX 3070's 16 MiB non-prefetchable BAR0
    /// must not count, or every GPU clears a megabyte-scale floor.
    fn the_bar_parser_ignores_register_windows_and_empty_bars() {
        // Verbatim from /sys/bus/pci/devices/0000:01:00.0/resource (RTX 3070):
        // BAR0 16 MiB non-prefetchable, BAR1 8192 MiB prefetchable.
        let rtx = "0x00000000b3000000 0x00000000b3ffffff 0x0000000000040200\n\
                   0x0000004000000000 0x00000041ffffffff 0x000000000014220c\n\
                   0x0000000000000000 0x0000000000000000 0x0000000000000000\n";
        assert_eq!(largest_prefetchable_bar(rtx), 8192 * 1024 * 1024);

        // An all-empty file is 0, never a panic and never a phantom aperture.
        assert_eq!(
            largest_prefetchable_bar("0x0000000000000000 0x0000000000000000 0x0000000000000000\n"),
            0
        );
        assert_eq!(largest_prefetchable_bar(""), 0);
        // Malformed input yields 0 rather than a misparse: a silent wrong
        // number here would produce a confident wrong classification, which is
        // the one outcome worse than `None`.
        assert_eq!(largest_prefetchable_bar("garbage\nalso garbage\n"), 0);
    }

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// YOLANDA'S CORRECTION, and the reason this is five states rather than
    /// three. Their `accel_proof` rendered one token for both "nobody to ask"
    /// and "asked and found nothing", so a working lane read identically to an
    /// absent one. My first version had the same hole one field over.
    fn the_envelope_distinguishes_no_gpu_from_unreachable_from_undecided() {
        let no_gpu = doc_on_side(
            "native-linux",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        assert_eq!(field(&accel_envelope(&no_gpu), "accel_mem_model"), "no-gpu");

        // A real GPU on a host whose evidence path this side cannot reach. WSL2
        // is the live case: a paravirtual GPU on /dev/dxg exposes no DRM sysfs,
        // so this is permanent until a Windows-side arm supplies the value —
        // a true statement about the boundary, not a gap in the probe.
        let guest = doc_on_side(
            "wsl2-guest",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "Radeon 860M", &["container"], None),
            ],
        );
        assert_eq!(
            field(&accel_envelope(&guest), "accel_mem_model"),
            "unobservable-from-this-side"
        );

        // Same GPU, native side: the classifier ran and refused. THIS is the
        // only one of the three that is a defect in the classifier.
        let native = doc_on_side(
            "native-linux",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "Radeon 860M", &["container"], None),
            ],
        );
        assert_eq!(
            field(&accel_envelope(&native), "accel_mem_model"),
            "undetermined"
        );
    }

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// EXIT CRITERION 3: the budget is still exactly one number, and `unified`
    /// remains the only value that licenses reading it as the whole machine.
    fn a_classified_device_reaches_the_envelope_and_the_budget_stays_singular() {
        for (model, expected) in [("unified", "unified"), ("discrete", "discrete")] {
            let mut d = doc_on_side(
                "native-linux",
                vec![
                    device("cpu", "cpu", &["container"], None),
                    device("gpu", "Radeon Vega", &["container"], None),
                ],
            );
            d.devices[1].memory_model = Some(model.to_string());
            let env = accel_envelope(&d);
            assert_eq!(field(&env, "accel_mem_model"), expected, "{env}");
            assert_eq!(
                env.split(' ')
                    .filter(|f| f.starts_with("accel_mem_budget_gb="))
                    .count(),
                1,
                "exactly one budget, nothing to add it to: {env}"
            );
        }
    }
}
