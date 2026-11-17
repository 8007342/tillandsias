//! The audio studio appliance (order 2055-grzz): `audio.transform` and
//! `audio.detect_glitches` on the per-lane MCP socket.
//!
//! @trace order:2055-grzz
//!
//! A TOOLS-ONLY sibling studio (images/studio/registry.lua, id `audio`): no
//! window and no long-running service. Each call runs ONE container of
//! images/audio-studio (`audio-tool`, built on first use) with
//! `--network=none`, every capability dropped, no-new-privileges, uid 1001
//! mapped to the host user, and the lane's AUDIO SCRATCH VOLUME mounted at
//! /work/tmp/audio: the same path the forge sees, so no path is translated.
//!
//! - The tray validates first: the op is one of [`OPS`], every path is a
//!   plain file path under /work/tmp/audio/ (no `..`, no NUL, no symlink
//!   escape: audio-tool resolves it again inside), each param is a
//!   `[a-z_]+` key with a scalar value. Nothing runs on a refusal.
//! - Outputs default to /work/tmp/audio/out/<op>/<stem>-<ticket>.<ext>, so a
//!   call never overwrites (audio-tool refuses an existing output too).
//! - Provenance v1 (provenance.rs) beside every output and findings report:
//!   the tool, audio-tool's version and the versions of ffmpeg, sox,
//!   rubberband and the Python stack, the input's sha256 and parent link, the
//!   op and its parameters, and the exact argv.
//! - No GPU: this slice's tools run on the CPU, so they never take the GPU
//!   queue (gpu_queue.rs). Stem separation (2055-d9sa) and the generative
//!   tools (2055-dihg) are GPU work and go through it.
//! - No egress and no model weights here; audio.separate (audio_separate.rs,
//!   2068-eeti) fetches its licensed weights on the host through
//!   the model-hubs tier, behind the licence gate.
#![cfg_attr(not(feature = "host-services"), allow(dead_code))]

/// The appliance image (images/audio-studio).
pub const IMAGE: &str = "audio-studio";
/// Where the forge and the appliance both see the lane's audio scratch volume.
pub const FORGE_AUDIO: &str = "/work/tmp/audio";
/// The appliance's own user (`useradd -u 1001` in its Containerfile).
pub const STUDIO_UID: u32 = 1001;
/// One call's wall-clock deadline, enforced by conmon (`podman run --timeout`)
/// so the CONTAINER dies with it. Killing only the podman client leaves the
/// container running: on 2026-11-09 runaway detect containers outlived their
/// 30 min client bound and starved every later call, a 4 s file included
/// (2066-azxa). A measured 86 s stereo detect takes ~2 s and a transform ~3 s.
pub const DEADLINE_SECS: u64 = 600;
/// The named transforms, with the extension a default output gets.
pub const OPS: &[(&str, &str)] = &[
    ("loudness_normalise", "wav"),
    ("time_stretch", "wav"),
    ("to_opus", "opus"),
    ("to_aac", "m4a"),
    ("resample", "wav"),
];
/// The fault kinds the detector reports.
pub const KINDS: &[&str] = &["click", "dropout", "spectral_hole", "clipping", "loop_seam"];

/// The lane's audio scratch VOLUME: a podman named volume per forge
/// instance, created at forge launch and removed at teardown, like
/// image.generate's (imagegen_tool::lane_volume). Never a host bind.
pub fn lane_volume(project: &str, instance: &str) -> String {
    let inst = if instance.trim().is_empty() {
        "default"
    } else {
        instance.trim()
    };
    format!("tillandsias-audio-{project}-{inst}")
}

/// The podman run argv (after `podman`) for one audio-tool call. `ro` is
/// (host file, container path) pairs bind-mounted READ-ONLY: audio.separate
/// mounts exactly the verified weights file under /models (2068-cqis); every
/// other call mounts nothing.
pub fn run_args(
    volume: &str,
    image_tag: &str,
    ro: &[(std::path::PathBuf, String)],
    tool_args: &[String],
) -> Vec<String> {
    let mut a: Vec<String> = [
        "run",
        "--rm",
        "--network=none",
        "--pull=never",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "--security-opt=label=disable",
        // Operator ruling 2026-11-13: studios are uncapped like forges.
        "--pids-limit=-1",
        "--oom-score-adj=1000",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    a.push(format!("--timeout={DEADLINE_SECS}"));
    a.push(format!(
        "--userns=keep-id:uid={STUDIO_UID},gid={STUDIO_UID}"
    ));
    a.push("--label".into());
    a.push("tillandsias.audio-studio=1".into());
    a.push("-v".into());
    a.push(format!("{volume}:{FORGE_AUDIO}"));
    for (host, inside) in ro {
        a.push("-v".into());
        a.push(format!("{}:{inside}:ro", host.display()));
    }
    a.push(image_tag.to_string());
    a.extend(tool_args.iter().cloned());
    a
}

#[cfg(feature = "host-services")]
pub use tools::*;

#[cfg(feature = "host-services")]
mod tools {
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use serde_json::{Value, json};

    use super::*;
    use crate::provenance;

    /// What runs `audio-tool <args>` and returns its stdout. Production is
    /// [`PodmanAppliance`]; fixtures stub it.
    pub trait Appliance {
        fn run(&self, tool_args: &[String]) -> Result<String, String>;
    }

    /// One container per call, on the lane's volume.
    pub struct PodmanAppliance {
        pub volume: String,
        pub image_tag: String,
        /// Read-only (host file, container path) mounts: empty except for
        /// audio.separate's weights.
        pub ro: Vec<(PathBuf, String)>,
    }

    impl Appliance for PodmanAppliance {
        fn run(&self, tool_args: &[String]) -> Result<String, String> {
            let started = std::time::Instant::now();
            // The client bound sits past the container's own deadline, so the
            // container is what times out and the client sees its exit.
            let out = crate::podman_command()
                .args(run_args(&self.volume, &self.image_tag, &self.ro, tool_args))
                .output_bounded(Duration::from_secs(DEADLINE_SECS + 60))
                .map_err(|e| format!("engine_failed: podman run {IMAGE}: {e}"))?;
            let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
            // audio-tool prints {"error": ...} on stdout and exits 2 on a refusal.
            if let Ok(v) = serde_json::from_str::<Value>(&stdout)
                && let Some(e) = v["error"].as_str()
            {
                return Err(e.to_string());
            }
            if !out.status.success() {
                return Err(failure_message(
                    out.status.code(),
                    started.elapsed(),
                    &String::from_utf8_lossy(&out.stderr),
                ));
            }
            Ok(stdout)
        }
    }

    /// A failed run, named: past the deadline it is `deadline_exceeded`
    /// (conmon killed the container), otherwise the exit code and stderr.
    pub(crate) fn failure_message(code: Option<i32>, elapsed: Duration, stderr: &str) -> String {
        if elapsed >= Duration::from_secs(DEADLINE_SECS) {
            return format!(
                "deadline_exceeded: {IMAGE} ran past its {DEADLINE_SECS} s deadline and was killed \
                 (exit {code:?}); split the input, or report the file that took this long"
            );
        }
        format!("engine_failed: {IMAGE} exited {code:?}: {}", stderr.trim())
    }

    fn podman_ok(args: &[&str]) -> Result<String, String> {
        let out = crate::podman_command()
            .args(args)
            .output_bounded(Duration::from_secs(30))
            .map_err(|e| format!("podman {}: {e}", args.join(" ")))?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
        } else {
            Err(format!(
                "podman {}: {}",
                args.join(" "),
                String::from_utf8_lossy(&out.stderr).trim()
            ))
        }
    }

    /// Forge launch: a fresh, empty volume (a leftover from a crashed forge is
    /// removed first; one a live forge of this lane still mounts stays).
    pub fn forge_scratch_volume(project: &str, instance: &str) -> Option<String> {
        let name = lane_volume(project, instance);
        let _ = podman_ok(&["volume", "rm", &name]);
        podman_ok(&["volume", "create", "--ignore", &name])
            .ok()
            .map(|_| name)
    }

    /// Forge teardown: the audio goes with the forge.
    pub fn remove_lane_volume(project: &str, instance: &str) {
        let _ = podman_ok(&["volume", "rm", "-f", &lane_volume(project, instance)]);
    }

    /// Where the HOST reads the lane's audio (to hash inputs and write the
    /// provenance sidecars): the volume's mountpoint.
    pub fn lane_host_dir(project: &str, instance: &str) -> Result<PathBuf, String> {
        let name = lane_volume(project, instance);
        podman_ok(&["volume", "create", "--ignore", &name])?;
        podman_ok(&["volume", "inspect", "--format", "{{.Mountpoint}}", &name]).map(PathBuf::from)
    }

    /// A forge path under /work/tmp/audio/ -> its path relative to the volume.
    pub fn forge_rel(field: &str, path: &str) -> Result<String, String> {
        let bad = || {
            format!(
                "invalid_arguments: {field} must be a file path under {FORGE_AUDIO}/, got {path:?}"
            )
        };
        let rel = path
            .strip_prefix(FORGE_AUDIO)
            .and_then(|r| r.strip_prefix('/'))
            .ok_or_else(bad)?;
        if rel.is_empty()
            || rel.contains('\0')
            || rel.ends_with('/')
            || rel
                .split('/')
                .any(|c| c.is_empty() || c == "." || c == "..")
        {
            return Err(bad());
        }
        Ok(rel.to_string())
    }

    fn param_args(params: Option<&Value>) -> Result<(Vec<String>, Value), String> {
        let mut argv = Vec::new();
        let mut echo = serde_json::Map::new();
        let Some(p) = params else {
            return Ok((argv, Value::Object(echo)));
        };
        let obj = p
            .as_object()
            .ok_or("invalid_arguments: params must be an object")?;
        for (k, v) in obj {
            if k.is_empty() || !k.bytes().all(|b| b.is_ascii_lowercase() || b == b'_') {
                return Err(format!(
                    "invalid_arguments: param name {k:?} is not [a-z_]+"
                ));
            }
            let s = match v {
                Value::String(s) if !s.contains('\0') && !s.contains('\n') => s.clone(),
                Value::Number(n) => n.to_string(),
                Value::Bool(b) => b.to_string(),
                _ => return Err(format!("invalid_arguments: param {k} must be a scalar")),
            };
            argv.push("--param".to_string());
            argv.push(format!("{k}={s}"));
            echo.insert(k.clone(), v.clone());
        }
        Ok((argv, Value::Object(echo)))
    }

    pub(crate) fn ticket() -> String {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        format!("{:x}{:04x}", nanos, std::process::id() & 0xffff)
    }

    pub(crate) fn stem(rel: &str) -> String {
        Path::new(rel)
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "audio".to_string())
    }

    pub(crate) fn input_record(
        host_dir: &Path,
        path: &str,
        rel: &str,
    ) -> Result<(provenance::Input, PathBuf), String> {
        let host = host_dir.join(rel);
        if !host.is_file() {
            return Err(format!("input_missing: {path} is not a file"));
        }
        let sha256 = provenance::sha256_file(&host)?;
        Ok((
            provenance::Input {
                name: "input".into(),
                path: path.to_string(),
                sha256,
            },
            host,
        ))
    }

    pub(crate) fn record(
        tool: &'static str,
        input: provenance::Input,
        input_host: &Path,
        versions: Value,
        op: &str,
        params: Value,
        argv: Vec<String>,
    ) -> provenance::Record {
        provenance::Record {
            tool,
            parents: provenance::parents_of([input_host]),
            engine: provenance::Engine::AudioStudio {
                versions,
                op: op.to_string(),
                params,
            },
            workflow: None,
            models: Vec::new(),
            inputs: vec![input],
            seed: 0,
            prompt: String::new(),
            negative_prompt: String::new(),
            tier: None,
            placement: "cpu".into(),
            family: None,
            consent: None,
            cli: Some(argv),
        }
    }

    /// `audio.transform`: run one named op; return the output path, the
    /// measurements and the provenance record (never audio bytes).
    pub fn transform(args: &Value, app: &dyn Appliance, host_dir: &Path) -> Result<Value, String> {
        let op = args["op"]
            .as_str()
            .ok_or("invalid_arguments: op is required")?;
        let ext = OPS
            .iter()
            .find(|(o, _)| *o == op)
            .map(|(_, e)| *e)
            .ok_or_else(|| {
                let names: Vec<&str> = OPS.iter().map(|(o, _)| *o).collect();
                format!(
                    "invalid_arguments: op {op:?} is not one of {}",
                    names.join(", ")
                )
            })?;
        let input = args["input"]
            .as_str()
            .ok_or("invalid_arguments: input is required")?;
        let in_rel = forge_rel("input", input)?;
        let output = match args["output"].as_str() {
            Some(o) => o.to_string(),
            None => format!(
                "{FORGE_AUDIO}/out/{op}/{}-{}.{ext}",
                stem(&in_rel),
                ticket()
            ),
        };
        let out_rel = forge_rel("output", &output)?;
        if out_rel == in_rel {
            return Err("invalid_arguments: output must differ from input".into());
        }
        let (pargs, params) = param_args(args.get("params"))?;
        let (inp, in_host) = input_record(host_dir, input, &in_rel)?;
        if host_dir.join(&out_rel).exists() {
            return Err(format!("output_exists: {output}"));
        }
        let mut argv: Vec<String> = [
            "transform",
            "--op",
            op,
            "--input",
            input,
            "--output",
            &output,
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        argv.extend(pargs);
        let res: Value = serde_json::from_str(&app.run(&argv)?)
            .map_err(|e| format!("engine_failed: audio-tool printed no JSON: {e}"))?;
        let out_host = host_dir.join(&out_rel);
        if !out_host.is_file() {
            return Err(format!("engine_failed: {op} wrote no {output}"));
        }
        let mut full_argv = vec!["audio-tool".to_string()];
        full_argv.extend(argv);
        let prov = record(
            "audio.transform",
            inp,
            &in_host,
            res["versions"].clone(),
            op,
            params.clone(),
            full_argv,
        )
        .write_beside(&out_host)?;
        Ok(json!({
            "op": op,
            "output": output,
            "provenance_path": format!("{output}.provenance.json"),
            "params": params,
            "measurements": res["measurements"].clone(),
            "provenance": prov,
        }))
    }

    /// `audio.detect_glitches`: the five fault kinds with their time ranges;
    /// the findings are also written as a JSON report with provenance.
    pub fn detect(args: &Value, app: &dyn Appliance, host_dir: &Path) -> Result<Value, String> {
        let input = args["input"]
            .as_str()
            .ok_or("invalid_arguments: input is required")?;
        let in_rel = forge_rel("input", input)?;
        let looped = args["loop"].as_bool().unwrap_or(false);
        let (inp, in_host) = input_record(host_dir, input, &in_rel)?;
        let mut argv: Vec<String> = vec!["detect".into(), "--input".into(), input.into()];
        if looped {
            argv.push("--loop".into());
        }
        let res: Value = serde_json::from_str(&app.run(&argv)?)
            .map_err(|e| format!("engine_failed: audio-tool printed no JSON: {e}"))?;
        let findings = res["findings"]
            .as_array()
            .ok_or("engine_failed: audio-tool returned no findings array")?
            .clone();
        for f in &findings {
            let kind = f["kind"].as_str().unwrap_or("");
            if !KINDS.contains(&kind)
                || f["start"].as_f64().is_none()
                || f["end"].as_f64().is_none()
            {
                return Err(format!("engine_failed: malformed finding {f}"));
            }
        }
        let report = format!(
            "{FORGE_AUDIO}/out/detect/{}-{}.findings.json",
            stem(&in_rel),
            ticket()
        );
        let report_rel = forge_rel("report", &report)?;
        let report_host = host_dir.join(&report_rel);
        if let Some(parent) = report_host.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("engine_failed: {e}"))?;
        }
        let body = json!({
            "input": input,
            "loop": looped,
            "duration": res["duration"].clone(),
            "sample_rate": res["sample_rate"].clone(),
            "channels": res["channels"].clone(),
            "findings": findings,
        });
        std::fs::write(
            &report_host,
            serde_json::to_vec_pretty(&body).unwrap_or_default(),
        )
        .map_err(|e| format!("engine_failed: {}: {e}", report_host.display()))?;
        let mut full_argv = vec!["audio-tool".to_string()];
        full_argv.extend(argv);
        let prov = record(
            "audio.detect_glitches",
            inp,
            &in_host,
            res["versions"].clone(),
            "detect",
            json!({ "loop": looped }),
            full_argv,
        )
        .write_beside(&report_host)?;
        Ok(json!({
            "input": input,
            "findings": body["findings"].clone(),
            "clean": body["findings"].as_array().is_some_and(|a| a.is_empty()),
            "report": report,
            "provenance_path": format!("{report}.provenance.json"),
            "provenance": prov,
        }))
    }

    /// Production dispatch: build the image on first use, then run the call
    /// on this lane's volume. `None` when `name` is not an audio tool.
    pub fn call(
        name: &str,
        project: &str,
        instance: &str,
        args: &Value,
    ) -> Option<Result<Value, String>> {
        if name == "audio.separate" {
            // 2068-eeti: the licence gate and the weights fetch come before
            // any image is built; the separator is 2068-cqis.
            return Some(crate::audio_separate::separate(project, instance, args));
        }
        if name != "audio.transform" && name != "audio.detect_glitches" {
            return None;
        }
        Some((|| {
            let version = crate::VERSION.trim();
            let root = crate::resolve_runtime_asset_root(version, false)?;
            let tag = crate::versioned_image_tag(IMAGE, version);
            crate::ensure_image_exists(&root, IMAGE, &tag, false)?;
            let host_dir = lane_host_dir(project, instance)?;
            let app = PodmanAppliance {
                volume: lane_volume(project, instance),
                image_tag: tag,
                ro: Vec::new(),
            };
            if name == "audio.transform" {
                transform(args, &app, &host_dir)
            } else {
                detect(args, &app, &host_dir)
            }
        })())
    }

    pub fn tool_descriptors() -> Vec<Value> {
        let ops: Vec<&str> = OPS.iter().map(|(o, _)| *o).collect();
        vec![
            json!({
                "name": "audio.transform",
                "description": format!(
                    "Run one named audio transform in this project's audio studio (an appliance with no network; built on first use): \
                     loudness_normalise {{target_lufs, default -16; refuses would_clip unless allow_clip=true}}, \
                     time_stretch {{ratio = output/input duration, 0.25..4; pitch_semitones}} with rubberband, \
                     to_opus {{bitrate_kbps, default 128}}, to_aac {{bitrate_kbps, default 192; ffmpeg's native AAC}}, \
                     resample {{rate}} with sox. Files live under {FORGE_AUDIO}/ (copy inputs there first). \
                     Returns the output path (default {FORGE_AUDIO}/out/<op>/<name>-<ticket>.<ext>; never overwrites) and its \
                     provenance (tool versions, input sha256, params), also written beside it as <output>.provenance.json."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "op": { "type": "string", "enum": ops },
                        "input": { "type": "string", "description": format!("An audio file under {FORGE_AUDIO}/.") },
                        "output": { "type": "string", "description": format!("Optional output path under {FORGE_AUDIO}/; its extension must suit the op.") },
                        "params": { "type": "object", "description": "The op's parameters, scalar values only." }
                    },
                    "required": ["op", "input"]
                }
            }),
            json!({
                "name": "audio.detect_glitches",
                "description": format!(
                    "Find faults in an audio file under {FORGE_AUDIO}/, in this project's audio studio (no network): \
                     click, dropout, spectral_hole, clipping, and with loop=true loop_seam (the end does not flow into the start). \
                     Returns findings [{{kind, start, end (seconds), detail}}] (empty means clean) and writes the same as a JSON report \
                     with provenance under {FORGE_AUDIO}/out/detect/. Check by these findings, never by listening."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "input": { "type": "string" },
                        "loop": { "type": "boolean", "default": false }
                    },
                    "required": ["input"]
                }
            }),
            crate::audio_separate::tool_descriptor(),
        ]
    }
}

#[cfg(all(test, feature = "host-services"))]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::cell::RefCell;

    /// A stub appliance: records each argv and answers like audio-tool,
    /// writing the transform's output file into the scratch dir.
    struct Stub {
        root: std::path::PathBuf,
        calls: RefCell<Vec<Vec<String>>>,
        reply: Value,
    }

    impl Appliance for Stub {
        fn run(&self, a: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(a.to_vec());
            if let Some(e) = self.reply["error"].as_str() {
                return Err(e.to_string());
            }
            if a[0] == "transform" {
                let out = &a[a.iter().position(|x| x == "--output").unwrap() + 1];
                let host = self.root.join(forge_rel("output", out).unwrap());
                std::fs::create_dir_all(host.parent().unwrap()).unwrap();
                std::fs::write(host, b"encoded").unwrap();
            }
            Ok(self.reply.to_string())
        }
    }

    fn versions() -> Value {
        json!({ "audio_tool": "1", "ffmpeg": "ffmpeg version 5.1.8", "rubberband": "3.1.2", "sox": "v14.4.2", "numpy": "2.5.4" })
    }

    fn lane() -> (tempfile::TempDir, std::path::PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().to_path_buf();
        std::fs::create_dir_all(root.join("in")).unwrap();
        std::fs::write(root.join("in/song.wav"), b"RIFF....WAVE").unwrap();
        (d, root)
    }

    #[test]
    fn the_appliance_runs_with_no_network_no_capabilities_on_the_lane_volume() {
        let a = run_args(
            "tillandsias-audio-p-default",
            "tillandsias-audio-studio:v1",
            &[],
            &["detect".into()],
        );
        for flag in [
            "--network=none",
            "--cap-drop=ALL",
            "--security-opt=no-new-privileges",
            "--rm",
            "--pull=never",
            // 2066-azxa: conmon kills the container at the deadline.
            "--timeout=600",
        ] {
            assert!(a.iter().any(|x| x == flag), "{flag}: {a:?}");
        }
        assert!(a.contains(&"tillandsias-audio-p-default:/work/tmp/audio".to_string()));
        assert!(a.contains(&"--userns=keep-id:uid=1001,gid=1001".to_string()));
        // The image, then the tool's own argv, last.
        assert_eq!(&a[a.len() - 2..], ["tillandsias-audio-studio:v1", "detect"]);
        assert!(
            !a.iter()
                .any(|x| x.contains("--device") || x.starts_with("-p") || x == "--privileged")
        );
        assert_eq!(
            lane_volume("kumbia", ""),
            "tillandsias-audio-kumbia-default"
        );
        // 2041-jb57: the image declares the egress its argv enforces.
        assert_eq!(crate::egress::declared(IMAGE), Some(vec!["none"]));
        assert!(!crate::egress::wants_proxy(IMAGE));
        // 2068-cqis: a weights mount is read-only, sits before the image,
        // and no call without one mounts anything under /models.
        assert!(!a.iter().any(|x| x.contains("/models")), "{a:?}");
        let w = run_args(
            "v",
            "img",
            &[(
                std::path::PathBuf::from("/cache/audio/demucs/955717e8.safetensors"),
                "/models/955717e8.safetensors".into(),
            )],
            &["separate".into()],
        );
        let at = w
            .iter()
            .position(|x| {
                x == "/cache/audio/demucs/955717e8.safetensors:/models/955717e8.safetensors:ro"
            })
            .expect("the weights mount, read-only");
        assert_eq!(w[at - 1], "-v");
        assert!(at < w.iter().position(|x| x == "img").unwrap());
    }

    #[test]
    fn a_transform_writes_its_output_with_provenance_naming_tool_versions_inputs_and_params() {
        let (_d, root) = lane();
        let stub = Stub {
            root: root.clone(),
            calls: RefCell::new(vec![]),
            reply: json!({ "versions": versions(), "measurements": { "duration_in": 3.0, "duration_out": 4.5 } }),
        };
        let r = transform(
            &json!({ "op": "time_stretch", "input": "/work/tmp/audio/in/song.wav", "params": { "ratio": 1.5 } }),
            &stub,
            &root,
        )
        .unwrap();
        let out = r["output"].as_str().unwrap();
        assert!(
            out.starts_with("/work/tmp/audio/out/time_stretch/song-") && out.ends_with(".wav"),
            "{out}"
        );
        let argv = &stub.calls.borrow()[0];
        assert_eq!(&argv[..3], ["transform", "--op", "time_stretch"]);
        assert!(
            argv.windows(2).any(|w| w == ["--param", "ratio=1.5"]),
            "{argv:?}"
        );
        // The sidecar on disk is the returned record.
        let side = root
            .join(forge_rel("o", out).unwrap())
            .with_extension("wav.provenance.json");
        let on_disk: Value = serde_json::from_slice(&std::fs::read(&side).unwrap()).unwrap();
        for v in [&r["provenance"], &on_disk] {
            assert_eq!(v["schema"], "tillandsias.provenance/v1");
            assert_eq!(v["tool"], "audio.transform");
            assert_eq!(v["engine"]["name"], "audio-studio");
            assert_eq!(v["engine"]["ref"], "1", "audio-tool's version");
            assert_eq!(v["engine"]["versions"]["rubberband"], "3.1.2");
            assert_eq!(v["engine"]["op"], "time_stretch");
            assert_eq!(v["engine"]["params"]["ratio"], 1.5);
            assert_eq!(v["inputs"][0]["path"], "/work/tmp/audio/in/song.wav");
            assert_eq!(
                v["inputs"][0]["sha256"],
                crate::provenance::sha256_hex(b"RIFF....WAVE")
            );
            assert_eq!(v["placement"], "cpu");
            assert_eq!(
                v["output_sha256"],
                crate::provenance::sha256_hex(b"encoded")
            );
        }
    }

    #[test]
    fn detection_returns_the_findings_and_writes_a_report_with_provenance() {
        let (_d, root) = lane();
        let findings = json!([{ "kind": "click", "start": 1.2, "end": 1.2001, "detail": {} },
                              { "kind": "loop_seam", "start": 2.97, "end": 2.98, "detail": {} }]);
        let stub = Stub {
            root: root.clone(),
            calls: RefCell::new(vec![]),
            reply: json!({ "versions": versions(), "findings": findings, "duration": 2.98, "sample_rate": 48000, "channels": 1 }),
        };
        let r = detect(
            &json!({ "input": "/work/tmp/audio/in/song.wav", "loop": true }),
            &stub,
            &root,
        )
        .unwrap();
        assert_eq!(
            stub.calls.borrow()[0],
            ["detect", "--input", "/work/tmp/audio/in/song.wav", "--loop"]
        );
        assert_eq!(r["findings"], findings);
        assert_eq!(r["clean"], false);
        let report = root.join(forge_rel("r", r["report"].as_str().unwrap()).unwrap());
        let body: Value = serde_json::from_slice(&std::fs::read(&report).unwrap()).unwrap();
        assert_eq!(body["findings"], findings);
        assert_eq!(r["provenance"]["tool"], "audio.detect_glitches");
        assert_eq!(r["provenance"]["engine"]["params"]["loop"], true);
        assert!(crate::provenance::sidecar_path(&report).is_file());
    }

    #[test]
    fn bad_calls_are_refused_before_the_appliance_runs() {
        let (_d, root) = lane();
        let stub = Stub {
            root: root.clone(),
            calls: RefCell::new(vec![]),
            reply: json!({}),
        };
        let cases = [
            (
                json!({ "op": "transform_anything", "input": "/work/tmp/audio/in/song.wav" }),
                "is not one of",
            ),
            (
                json!({ "op": "to_opus", "input": "/work/tmp/imagegen/x.wav" }),
                "under /work/tmp/audio/",
            ),
            (
                json!({ "op": "to_opus", "input": "/work/tmp/audio/../../etc/passwd" }),
                "under /work/tmp/audio/",
            ),
            (
                json!({ "op": "to_opus", "input": "/work/tmp/audio/in/missing.wav" }),
                "input_missing",
            ),
            (
                json!({ "op": "to_opus", "input": "/work/tmp/audio/in/song.wav", "params": { "Bitrate": 1 } }),
                "[a-z_]+",
            ),
            (
                json!({ "op": "to_opus", "input": "/work/tmp/audio/in/song.wav", "params": { "x": [1] } }),
                "scalar",
            ),
            (
                json!({ "op": "to_opus", "input": "/work/tmp/audio/in/song.wav", "output": "/work/tmp/audio/in/song.wav" }),
                "differ",
            ),
            (
                json!({ "op": "to_opus", "input": "/work/tmp/audio/in/song.wav", "output": "/work/tmp/audio/in/song.wav.opus/" }),
                "under /work/tmp/audio/",
            ),
        ];
        for (args, want) in cases {
            let e = transform(&args, &stub, &root).unwrap_err();
            assert!(e.contains(want), "{args}: {e}");
        }
        assert!(detect(&json!({ "input": "/etc/passwd" }), &stub, &root).is_err());
        assert!(
            stub.calls.borrow().is_empty(),
            "the appliance ran on a refused call"
        );
        // NEGATIVE CONTROL: a well-formed call does reach it.
        let ok = Stub {
            root: root.clone(),
            calls: RefCell::new(vec![]),
            reply: json!({ "versions": versions() }),
        };
        transform(
            &json!({ "op": "to_opus", "input": "/work/tmp/audio/in/song.wav" }),
            &ok,
            &root,
        )
        .unwrap();
        assert_eq!(ok.calls.borrow().len(), 1);
    }

    #[test]
    fn an_appliance_refusal_and_a_malformed_finding_are_errors_not_results() {
        let (_d, root) = lane();
        let refusing = Stub {
            root: root.clone(),
            calls: RefCell::new(vec![]),
            reply: json!({ "error": "would_clip: reaching -5 LUFS needs a peak of 3.1 dBFS" }),
        };
        let e = transform(
            &json!({ "op": "loudness_normalise", "input": "/work/tmp/audio/in/song.wav" }),
            &refusing,
            &root,
        )
        .unwrap_err();
        assert!(e.starts_with("would_clip"), "{e}");
        let odd = Stub {
            root: root.clone(),
            calls: RefCell::new(vec![]),
            reply: json!({ "versions": versions(), "findings": [{ "kind": "hum", "start": 0.0, "end": 1.0 }] }),
        };
        assert!(
            detect(
                &json!({ "input": "/work/tmp/audio/in/song.wav" }),
                &odd,
                &root
            )
            .unwrap_err()
            .contains("malformed")
        );
    }

    #[test]
    fn a_run_killed_at_the_deadline_is_named_deadline_exceeded_not_an_engine_failure() {
        let late = failure_message(
            Some(255),
            std::time::Duration::from_secs(DEADLINE_SECS) + std::time::Duration::from_millis(5),
            "",
        );
        assert!(late.starts_with("deadline_exceeded:"), "{late}");
        assert!(late.contains("600 s"), "{late}");
        let early = failure_message(Some(1), std::time::Duration::from_secs(3), "boom\n");
        assert_eq!(early, "engine_failed: audio-studio exited Some(1): boom");
    }

    #[test]
    fn the_descriptors_name_every_op_and_every_fault_kind() {
        let d = tool_descriptors();
        let t = d.iter().find(|t| t["name"] == "audio.transform").unwrap();
        let ops: Vec<&str> = OPS.iter().map(|(o, _)| *o).collect();
        assert_eq!(t["inputSchema"]["properties"]["op"]["enum"], json!(ops));
        let g = d
            .iter()
            .find(|t| t["name"] == "audio.detect_glitches")
            .unwrap();
        for k in KINDS {
            assert!(g["description"].as_str().unwrap().contains(k), "{k}");
        }
        // The registry names exactly these tools for the audio studio.
        let s = crate::studio::find("audio").unwrap();
        let names: Vec<&str> = d.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(s.tools, names);
    }
}
