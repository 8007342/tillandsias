//! @trace order:1956-26qh — the family contract v1 static checker behind
//! `studio.validate_family` (design D7 of studio-asset-pipeline).
//!
//! Pure: it reads the spec and the files the spec names under `project_root`,
//! touches no network, no GPU and no container. The schema it mirrors ships at
//! `openspec/changes/studio-asset-pipeline/contract/family-spec.v1.schema.json`;
//! the shape checks here are hand-written against that schema so the crate
//! takes on no JSON-Schema dependency.
//!
//! Verdict lines are the tool's wire format: `ok:family:<family>` or one
//! `refused:<check>:<detail>` per failure.

use serde_json::Value;
use std::collections::BTreeSet;
use std::fmt;
use std::path::Path;

/// The contract revision this checker rules on.
pub const CONTRACT: &str = "1935-k2ib/v1";

/// The kinds defined now. `kind` is an open enum: a sibling project adds a
/// kind by contributing its schema branch; until then it is refused by name.
pub const KNOWN_KINDS: &[&str] = &["character-frames", "layered-parts"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    Ok { family: String },
    Refused { check: String, detail: String },
}

impl Verdict {
    fn refused(check: &str, detail: impl Into<String>) -> Self {
        Verdict::Refused {
            check: check.to_string(),
            detail: detail.into(),
        }
    }
}

impl fmt::Display for Verdict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Verdict::Ok { family } => write!(f, "ok:family:{family}"),
            Verdict::Refused { check, detail } => write!(f, "refused:{check}:{detail}"),
        }
    }
}

/// Check the family spec at `spec_path`, resolving every project-relative
/// path it names under `project_root`. One `Ok` verdict, or one `Refused`
/// per failure, never both.
pub fn validate_family(spec_path: &Path, project_root: &Path) -> Vec<Verdict> {
    let text = match std::fs::read_to_string(spec_path) {
        Ok(t) => t,
        Err(e) => {
            return vec![Verdict::refused(
                "schema",
                format!("{} is unreadable: {e}", spec_path.display()),
            )];
        }
    };
    let spec: Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(e) => return vec![Verdict::refused("schema", format!("spec is not JSON: {e}"))],
    };
    let mut out = Vec::new();
    check_shape(&spec, &mut out);
    check_inputs_exist(&spec, project_root, &mut out);
    if spec.get("reservedRamps").is_some() {
        check_palette_fails_all_gates(&spec, project_root, &mut out);
    }
    if spec.get("regions").is_some() {
        check_region_mask_colours_declared(&spec, project_root, &mut out);
    }
    if out.is_empty() {
        let family = spec["family"].as_str().unwrap_or("").to_string();
        out.push(Verdict::Ok { family });
    }
    out
}

/// The project-relative paths a spec names as inputs, each with the JSON
/// path it came from. The tool copies exactly these out of the lane.
pub fn referenced_inputs(spec: &Value) -> Vec<(String, String)> {
    let mut v = Vec::new();
    let mut push = |at: String, val: &Value| {
        if let Some(p) = val.as_str() {
            v.push((p.to_string(), at));
        }
    };
    push("palette.locked".into(), &spec["palette"]["locked"]);
    for (i, r) in spec["references"]
        .as_array()
        .into_iter()
        .flatten()
        .enumerate()
    {
        push(format!("references[{i}].image"), &r["image"]);
    }
    for (i, p) in spec["poses"].as_array().into_iter().flatten().enumerate() {
        push(format!("poses[{i}].control.image"), &p["control"]["image"]);
        for (j, a) in p["control"]["aux"]
            .as_array()
            .into_iter()
            .flatten()
            .enumerate()
        {
            push(format!("poses[{i}].control.aux[{j}].image"), &a["image"]);
        }
        push(format!("poses[{i}].regionMask"), &p["regionMask"]);
    }
    v
}

/// Validate a tool argument as a project-relative path: forward slashes, not
/// absolute, no `..`, no hidden segment, nothing empty.
pub fn project_relative(path: &str) -> Result<String, String> {
    if path.is_empty() {
        return Err("invalid_arguments: spec path is empty".into());
    }
    if path.starts_with('/') || path.contains('\\') || path.contains(':') {
        return Err(format!(
            "invalid_arguments: {path:?} is absolute; give a path relative to the project"
        ));
    }
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    if segments.is_empty() {
        return Err("invalid_arguments: spec path is empty".into());
    }
    if segments.contains(&"..") {
        return Err(format!(
            "invalid_arguments: {path:?} leaves the project ('..' is not allowed)"
        ));
    }
    if segments.iter().any(|s| s.starts_with('.')) {
        return Err(format!(
            "invalid_arguments: {path:?} names a hidden or private segment"
        ));
    }
    Ok(segments.join("/"))
}

// ─── schema-level shape (hand-written mirror of family-spec.v1.schema.json) ───

fn check_shape(spec: &Value, out: &mut Vec<Verdict>) {
    let mut s = Shape { out };
    let Some(obj) = spec.as_object() else {
        s.err("", "spec must be a JSON object");
        return;
    };
    for key in [
        "contract",
        "pipelineVersion",
        "family",
        "version",
        "project",
        "kind",
    ] {
        if !obj.contains_key(key) {
            s.err(key, "is required");
        }
    }
    if obj.contains_key("contract") && spec["contract"] != CONTRACT {
        s.err("contract", format!("must be {CONTRACT:?}"));
    }
    if obj.contains_key("pipelineVersion") && !spec["pipelineVersion"].is_null() {
        s.err(
            "pipelineVersion",
            "must be null in a spec; the tool stamps it into provenance",
        );
    }
    s.slug("family", &spec["family"]);
    s.slug("project", &spec["project"]);
    if obj.contains_key("version") && !spec["version"].as_u64().is_some_and(|n| n >= 1) {
        s.err("version", "must be an integer >= 1");
    }

    // kind: open enum, refused by name with the known list.
    match spec["kind"].as_str() {
        None => {
            if obj.contains_key("kind") {
                s.err("kind", "must be a string");
            }
        }
        Some(k) if !KNOWN_KINDS.contains(&k) => {
            s.out.push(Verdict::refused(
                "unknown_kind",
                format!(
                    "{k} is not a known kind; known kinds: {}",
                    KNOWN_KINDS.join(", ")
                ),
            ));
        }
        Some("character-frames") => s.character_frames(spec),
        Some("layered-parts") => s.layered_parts(spec),
        Some(_) => {}
    }

    if let Some(o) = spec.get("outline") {
        s.hex("outline", o);
    }
    if let Some(sym) = spec.get("symmetry") {
        s.one_of("symmetry", sym, &["none", "mirror-x"]);
    }
    if let Some(t) = spec.get("transparency") {
        s.transparency(t);
    }
    if let Some(a) = spec.get("adapters") {
        s.adapters(a);
    }
    for (i, r) in spec["references"]
        .as_array()
        .into_iter()
        .flatten()
        .enumerate()
    {
        let at = format!("references[{i}]");
        s.one_of(
            &format!("{at}.role"),
            &r["role"],
            &["identity", "style", "palette"],
        );
        s.path(&format!("{at}.image"), &r["image"]);
        if let Some(w) = r.get("weight")
            && !w.as_f64().is_some_and(|w| (0.0..=1.0).contains(&w))
        {
            s.err(&format!("{at}.weight"), "must be a number in 0..=1");
        }
    }
    if let Some(regions) = spec.get("regions") {
        match regions.as_object() {
            Some(m) if !m.is_empty() => {
                for (k, v) in m {
                    if parse_hex(k).is_none() {
                        s.err(&format!("regions[{k:?}]"), "key must be a #RRGGBB colour");
                    }
                    s.slug(&format!("regions[{k:?}]"), v);
                }
            }
            _ => s.err("regions", "must be a non-empty object of #RRGGBB -> region"),
        }
        if let Some(rr) = spec.get("regionsRender") {
            if rr["antialias"] != false {
                s.err("regionsRender.antialias", "must be false");
            }
            if rr["filtering"] != "none" {
                s.err("regionsRender.filtering", "must be \"none\"");
            }
        }
        s.require_static(spec, "regions", "region_mask_colours_declared");
    }
    if let Some(ramps) = spec.get("reservedRamps") {
        s.reserved_ramps(ramps);
        if spec.get("outline").is_none() {
            s.err("outline", "is required when reservedRamps is declared");
        }
        if spec["palette"]["locked"].is_null() {
            s.err(
                "palette.locked",
                "is required when reservedRamps is declared",
            );
        }
        s.require_static(spec, "reservedRamps", "palette_fails_all_gates");
    }
    if let Some(p) = spec.get("palette") {
        s.path("palette.locked", &p["locked"]);
    }
    if let Some(g) = spec.get("generation") {
        s.generation(g);
    }
    if let Some(q) = spec.get("qa") {
        s.qa(q);
    }
    if let Some(t) = spec.get("targets") {
        s.targets(spec, t);
    }
}

struct Shape<'a> {
    out: &'a mut Vec<Verdict>,
}

impl Shape<'_> {
    fn err(&mut self, at: &str, what: impl fmt::Display) {
        let at = if at.is_empty() { "spec" } else { at };
        self.out
            .push(Verdict::refused("schema", format!("{at} {what}")));
    }

    fn slug(&mut self, at: &str, v: &Value) {
        if v.is_null() {
            return;
        }
        let ok = v.as_str().is_some_and(|s| {
            let mut c = s.chars();
            c.next()
                .is_some_and(|f| f.is_ascii_lowercase() || f.is_ascii_digit())
                && c.all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || "._-".contains(ch))
        });
        if !ok {
            self.err(at, "must be a slug [a-z0-9][a-z0-9._-]*");
        }
    }

    fn hex(&mut self, at: &str, v: &Value) {
        if !v.as_str().is_some_and(|s| parse_hex(s).is_some()) {
            self.err(at, "must be a #RRGGBB colour");
        }
    }

    fn path(&mut self, at: &str, v: &Value) {
        match v.as_str() {
            Some(p) => {
                if let Err(e) = project_relative(p) {
                    self.err(at, e.trim_start_matches("invalid_arguments: "));
                }
            }
            None => self.err(at, "must be a project-relative path"),
        }
    }

    fn one_of(&mut self, at: &str, v: &Value, allowed: &[&str]) {
        if !v.as_str().is_some_and(|s| allowed.contains(&s)) {
            self.err(at, format!("must be one of {}", allowed.join(" | ")));
        }
    }

    fn require_static(&mut self, spec: &Value, because: &str, id: &str) {
        let listed = spec["qa"]["static"]
            .as_array()
            .is_some_and(|a| a.iter().any(|c| c["id"] == id));
        if !listed {
            self.err(
                "qa.static",
                format!("must list {id} when {because} is declared (D7(a))"),
            );
        }
    }

    fn character_frames(&mut self, spec: &Value) {
        for key in ["frame", "clips", "poses", "targets"] {
            if spec.get(key).is_none() {
                self.err(key, "is required for kind character-frames");
            }
        }
        if let Some(f) = spec.get("frame") {
            self.frame(f);
        }
        let clips: BTreeSet<&str> = spec["clips"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|c| c["id"].as_str())
            .collect();
        for (i, c) in spec["clips"].as_array().into_iter().flatten().enumerate() {
            let at = format!("clips[{i}]");
            self.slug(&format!("{at}.id"), &c["id"]);
            if c["id"].is_null() {
                self.err(&format!("{at}.id"), "is required");
            }
            if !c["drawings"].as_u64().is_some_and(|n| n >= 1) {
                self.err(&format!("{at}.drawings"), "must be an integer >= 1");
            }
            if !c["durationBeats"].as_f64().is_some_and(|b| b > 0.0) {
                self.err(&format!("{at}.durationBeats"), "must be a number > 0");
            }
            for (j, e) in c["events"].as_array().into_iter().flatten().enumerate() {
                if !e["beat"].as_f64().is_some_and(|b| b >= 0.0) {
                    self.err(&format!("{at}.events[{j}].beat"), "must be a number >= 0");
                }
                self.one_of(&format!("{at}.events[{j}].type"), &e["type"], &["accent"]);
            }
        }
        for (i, p) in spec["poses"].as_array().into_iter().flatten().enumerate() {
            let at = format!("poses[{i}]");
            if p.get("camera").is_some() {
                self.err(
                    &format!("{at}.camera"),
                    "poses carry no camera; camera lives on frame and targets (D7(b))",
                );
            }
            if !p["id"].is_string() {
                self.err(&format!("{at}.id"), "is required");
            }
            match p["clip"].as_str() {
                Some(c) if !clips.is_empty() && !clips.contains(c) => {
                    self.err(&format!("{at}.clip"), format!("{c:?} is not a clip id"));
                }
                None => self.err(&format!("{at}.clip"), "is required"),
                _ => {}
            }
            if p.get("control").is_none() {
                self.err(
                    &format!("{at}.control"),
                    "is required: the caller supplies the control image",
                );
            } else {
                self.control(&format!("{at}.control"), &p["control"]);
                for (j, a) in p["control"]["aux"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .enumerate()
                {
                    self.control(&format!("{at}.control.aux[{j}]"), a);
                }
            }
            if let Some(m) = p.get("regionMask") {
                self.path(&format!("{at}.regionMask"), m);
            }
            if let Some(sf) = p.get("supportFoot") {
                self.one_of(
                    &format!("{at}.supportFoot"),
                    sf,
                    &["left", "right", "both", "none"],
                );
            }
        }
    }

    fn control(&mut self, at: &str, c: &Value) {
        self.one_of(
            &format!("{at}.type"),
            &c["type"],
            &["openpose", "depth", "lineart", "canny", "normal"],
        );
        self.path(&format!("{at}.image"), &c["image"]);
        if let Some(s) = c.get("strength")
            && !s.as_f64().is_some_and(|s| (0.0..=2.0).contains(&s))
        {
            self.err(&format!("{at}.strength"), "must be a number in 0..=2");
        }
    }

    fn frame(&mut self, f: &Value) {
        for key in ["units", "scale", "native", "margin", "generationCanvas"] {
            if f.get(key).is_none() {
                self.err(&format!("frame.{key}"), "is required");
            }
        }
        if f.get("units").is_some() && f["units"] != "native-px" {
            self.err("frame.units", "must be \"native-px\"");
        }
        if f.get("scale").is_some() {
            self.one_of(
                "frame.scale.mode",
                &f["scale"]["mode"],
                &["fixed-per-family"],
            );
        }
        if let Some(c) = f.get("camera") {
            self.camera("frame.camera", c);
        }
        if let Some(n) = f.get("native") {
            self.native(n);
        }
        if let Some(m) = f.get("margin") {
            if !m["minClear"]
                .as_f64()
                .is_some_and(|x| (0.0..=0.5).contains(&x))
            {
                self.err(
                    "frame.margin.minClear",
                    "must be a fraction of the canvas in 0..=0.5",
                );
            }
            if m["units"] != "fraction-of-generation-canvas" {
                self.err(
                    "frame.margin.units",
                    "must be \"fraction-of-generation-canvas\"",
                );
            }
        }
        if let Some(c) = f.get("generationCanvas") {
            for k in ["width", "height"] {
                if !c[k].as_u64().is_some_and(|n| n >= 64) {
                    self.err(
                        &format!("frame.generationCanvas.{k}"),
                        "must be an integer >= 64",
                    );
                }
            }
        }
    }

    fn native(&mut self, n: &Value) {
        if n.is_null() {
            return; // a decision the owner has not made yet
        }
        let Some(m) = n.as_object() else {
            self.err(
                "frame.native",
                "must be null, a size, or {perRoom: true, <room>: size}",
            );
            return;
        };
        if m.get("perRoom").is_some() {
            if m["perRoom"] != true {
                self.err("frame.native.perRoom", "must be true when present");
            }
            let rooms: Vec<_> = m.keys().filter(|k| *k != "perRoom").collect();
            if rooms.is_empty() {
                self.err(
                    "frame.native",
                    "perRoom needs at least one <room>: {width, height, pixelScale}",
                );
            }
            for r in rooms {
                self.slug(&format!("frame.native[{r:?}]"), &Value::from(r.as_str()));
                self.native_size(&format!("frame.native.{r}"), &m[r]);
            }
        } else {
            self.native_size("frame.native", n);
        }
    }

    fn native_size(&mut self, at: &str, s: &Value) {
        for k in ["width", "height", "pixelScale"] {
            match s.get(k) {
                None => self.err(&format!("{at}.{k}"), "is required"),
                Some(v) if v.is_null() => {}
                Some(v) if !v.as_f64().is_some_and(|x| x > 0.0) => {
                    self.err(&format!("{at}.{k}"), "must be a positive number or null");
                }
                _ => {}
            }
        }
    }

    fn camera(&mut self, at: &str, c: &Value) {
        self.one_of(at, c, &["floor-perspective", "side-on"]);
    }

    fn layered_parts(&mut self, spec: &Value) {
        // Minimal and permissive: demon_attack's details are not in this repo.
        match spec["slots"].as_array() {
            None => self.err("slots", "is required for kind layered-parts"),
            Some(a) if a.is_empty() => self.err("slots", "must name at least one slot"),
            Some(a) => {
                for (i, s) in a.iter().enumerate() {
                    if s["id"].is_null() {
                        self.err(&format!("slots[{i}].id"), "is required");
                    } else {
                        self.slug(&format!("slots[{i}].id"), &s["id"]);
                    }
                }
            }
        }
        for k in ["dock", "wear"] {
            if let Some(v) = spec.get(k)
                && !(v.is_object() || v.is_array())
            {
                self.err(k, "must be an object or an array");
            }
        }
    }

    fn transparency(&mut self, t: &Value) {
        for (k, v) in t["byBackend"].as_object().into_iter().flatten() {
            self.one_of(
                &format!("transparency.byBackend.{k}"),
                v,
                &["layerdiffuse", "matte"],
            );
        }
        if let Some(m) = t.get("matte") {
            self.one_of("transparency.matte", m, &["birefnet"]);
        }
        if let Some(a) = t.get("alpha") {
            self.one_of("transparency.alpha", a, &["binary"]);
        }
    }

    fn adapters(&mut self, a: &Value) {
        match a["enum"].as_array() {
            None => self.err("adapters.enum", "is required"),
            Some(list) => {
                for (i, v) in list.iter().enumerate() {
                    self.one_of(
                        &format!("adapters.enum[{i}]"),
                        v,
                        &["ip-adapter-sdxl", "qwen-image-edit", "img2img"],
                    );
                }
            }
        }
    }

    fn reserved_ramps(&mut self, ramps: &Value) {
        let Some(list) = ramps.as_array() else {
            self.err("reservedRamps", "must be an array");
            return;
        };
        for (i, ramp) in list.iter().enumerate() {
            let at = format!("reservedRamps[{i}]");
            if ramp["id"].is_null() {
                self.err(&format!("{at}.id"), "is required");
            }
            self.slug(&format!("{at}.id"), &ramp["id"]);
            match ramp["appliesToRegions"].as_array() {
                Some(a) if !a.is_empty() => {
                    for (j, r) in a.iter().enumerate() {
                        self.slug(&format!("{at}.appliesToRegions[{j}]"), r);
                    }
                }
                _ => self.err(
                    &format!("{at}.appliesToRegions"),
                    "must name at least one region",
                ),
            }
            match ramp["gates"].as_array() {
                Some(g) if !g.is_empty() => {
                    for (j, gate) in g.iter().enumerate() {
                        self.gate(&format!("{at}.gates[{j}]"), gate);
                    }
                }
                _ => self.err(&format!("{at}.gates"), "must hold at least one gate"),
            }
        }
    }

    fn gate(&mut self, at: &str, gate: &Value) {
        if gate["id"].is_null() {
            self.err(&format!("{at}.id"), "is required");
        }
        self.slug(&format!("{at}.id"), &gate["id"]);
        match gate["all"].as_array() {
            Some(c) if !c.is_empty() => {
                for (k, cond) in c.iter().enumerate() {
                    let at = format!("{at}.all[{k}]");
                    if let Err(e) = Condition::parse(cond) {
                        self.err(&format!("{at}.{}", e.0), e.1);
                    }
                }
            }
            _ => self.err(&format!("{at}.all"), "must hold at least one condition"),
        }
    }

    fn generation(&mut self, g: &Value) {
        if let Some(c) = g.get("count_per_pose")
            && !c.as_u64().is_some_and(|n| (1..=16).contains(&n))
        {
            self.err("generation.count_per_pose", "must be an integer in 1..=16");
        }
        if let Some(b) = g.get("backend") {
            self.one_of("generation.backend", b, &["comfyui-api", "sdcpp"]);
        }
        if let Some(w) = g.get("workflow") {
            self.path("generation.workflow", w);
        }
    }

    fn qa(&mut self, q: &Value) {
        for (i, c) in q["add"].as_array().into_iter().flatten().enumerate() {
            self.one_of(
                &format!("qa.add[{i}].id"),
                &c["id"],
                &[
                    "baseline_drift",
                    "head_size_variance",
                    "region_gate_agreement",
                    "identity_similarity",
                ],
            );
        }
        for (i, c) in q["static"].as_array().into_iter().flatten().enumerate() {
            self.one_of(
                &format!("qa.static[{i}].id"),
                &c["id"],
                &["palette_fails_all_gates", "region_mask_colours_declared"],
            );
        }
    }

    fn targets(&mut self, spec: &Value, t: &Value) {
        let Some(list) = t.as_array() else {
            self.err("targets", "must be an array");
            return;
        };
        if list.is_empty() {
            self.err("targets", "must name at least one target");
        }
        let per_room: Option<BTreeSet<&str>> = spec["frame"]["native"]
            .as_object()
            .filter(|m| m.get("perRoom").is_some())
            .map(|m| {
                m.keys()
                    .map(String::as_str)
                    .filter(|k| *k != "perRoom")
                    .collect()
            });
        for (i, target) in list.iter().enumerate() {
            let at = format!("targets[{i}]");
            self.one_of(
                &format!("{at}.type"),
                &target["type"],
                &["kumbiaManifest", "layeredAtlas"],
            );
            match target["room"].as_str() {
                None => self.err(
                    &format!("{at}.room"),
                    "is required: every target names its room",
                ),
                Some(r) => {
                    self.slug(&format!("{at}.room"), &target["room"]);
                    if let Some(rooms) = &per_room
                        && !rooms.contains(r)
                    {
                        self.err(
                            &format!("{at}.room"),
                            format!("{r:?} has no frame.native entry"),
                        );
                    }
                }
            }
            if let Some(c) = target.get("camera") {
                self.camera(&format!("{at}.camera"), c);
            }
            self.path(&format!("{at}.out"), &target["out"]);
            if let Some(m) = target.get("manifest") {
                self.path(&format!("{at}.manifest"), m);
            }
            if !target["requireHumanAcceptance"].is_boolean() {
                self.err(&format!("{at}.requireHumanAcceptance"), "must be a boolean");
            }
            if let Some(a) = target["packing"].get("anchorRelativeTo") {
                self.one_of(
                    &format!("{at}.packing.anchorRelativeTo"),
                    a,
                    &["trimmed-rect"],
                );
            }
        }
    }
}

// ─── gate grammar: data, never eval ──────────────────────────────────────────

#[derive(Clone, Copy)]
enum Channel {
    R,
    G,
    B,
}

impl Channel {
    fn parse(v: &Value) -> Option<Self> {
        match v.as_str()? {
            "r" => Some(Channel::R),
            "g" => Some(Channel::G),
            "b" => Some(Channel::B),
            _ => None,
        }
    }
    fn of(self, rgb: [f64; 3]) -> f64 {
        match self {
            Channel::R => rgb[0],
            Channel::G => rgb[1],
            Channel::B => rgb[2],
        }
    }
}

enum Lhs {
    Channel(Channel),
    Sub(Channel, Channel),
}

enum Rhs {
    Literal(f64),
    Mul(f64, Channel),
}

#[derive(Clone, Copy)]
enum Op {
    Ge,
    Le,
    Gt,
    Lt,
    Eq,
}

struct Condition {
    lhs: Lhs,
    op: Op,
    rhs: Rhs,
}

impl Condition {
    /// Parse one condition; an error names the sub-field and why.
    fn parse(v: &Value) -> Result<Self, (&'static str, String)> {
        let lhs = match &v["lhs"] {
            s @ Value::String(_) => Channel::parse(s)
                .map(Lhs::Channel)
                .ok_or(("lhs", "must be r, g or b, or {sub:[a,b]}".to_string()))?,
            o @ Value::Object(_) => {
                let sub = o["sub"].as_array().filter(|a| a.len() == 2);
                match sub.and_then(|a| Some((Channel::parse(&a[0])?, Channel::parse(&a[1])?))) {
                    Some((a, b)) => Lhs::Sub(a, b),
                    None => return Err(("lhs", "must be r, g or b, or {sub:[a,b]}".into())),
                }
            }
            _ => return Err(("lhs", "must be r, g or b, or {sub:[a,b]}".into())),
        };
        let op = match v["op"].as_str() {
            Some(">=") => Op::Ge,
            Some("<=") => Op::Le,
            Some(">") => Op::Gt,
            Some("<") => Op::Lt,
            Some("==") => Op::Eq,
            _ => return Err(("op", "must be one of >= | <= | > | < | ==".into())),
        };
        let rhs = match &v["rhs"] {
            Value::Number(n) => Rhs::Literal(n.as_f64().unwrap_or(f64::NAN)),
            o @ Value::Object(_) => {
                let mul = o["mul"].as_array().filter(|a| a.len() == 2);
                match mul.and_then(|a| Some((a[0].as_f64()?, Channel::parse(&a[1])?))) {
                    Some((k, c)) => Rhs::Mul(k, c),
                    None => return Err(("rhs", "must be a number or {mul:[k,channel]}".into())),
                }
            }
            _ => return Err(("rhs", "must be a number or {mul:[k,channel]}".into())),
        };
        Ok(Condition { lhs, op, rhs })
    }

    fn holds(&self, rgb: [f64; 3]) -> bool {
        let l = match self.lhs {
            Lhs::Channel(c) => c.of(rgb),
            Lhs::Sub(a, b) => a.of(rgb) - b.of(rgb),
        };
        let r = match self.rhs {
            Rhs::Literal(x) => x,
            Rhs::Mul(k, c) => k * c.of(rgb),
        };
        match self.op {
            Op::Ge => l >= r,
            Op::Le => l <= r,
            Op::Gt => l > r,
            Op::Lt => l < r,
            Op::Eq => (l - r).abs() < 1e-9,
        }
    }
}

/// A gate matches when ALL its parseable conditions hold. Unparseable
/// conditions were already refused by the shape check.
fn gate_matches(gate: &Value, rgb: [f64; 3]) -> bool {
    gate["all"].as_array().is_some_and(|all| {
        !all.is_empty()
            && all
                .iter()
                .filter_map(|c| Condition::parse(c).ok())
                .all(|c| c.holds(rgb))
    })
}

fn unit_rgb(hex: &str) -> Option<[f64; 3]> {
    let (r, g, b) = parse_hex(hex)?;
    Some([r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0])
}

// ─── palette_fails_all_gates (mandatory with reservedRamps) ──────────────────

fn check_palette_fails_all_gates(spec: &Value, root: &Path, out: &mut Vec<Verdict>) {
    const CHECK: &str = "palette_fails_all_gates";
    let Some(ramps) = spec["reservedRamps"].as_array() else {
        return;
    };
    let ramp_regions: BTreeSet<&str> = ramps
        .iter()
        .flat_map(|r| r["appliesToRegions"].as_array().into_iter().flatten())
        .filter_map(Value::as_str)
        .collect();

    // Entries to test: the outline, then every palette colour not under a
    // ramp-applied region key.
    let mut entries: Vec<(String, String)> = Vec::new();
    if let Some(o) = spec["outline"].as_str() {
        entries.push(("outline".into(), o.to_string()));
    }
    let Some(rel) = spec["palette"]["locked"].as_str() else {
        out.push(Verdict::refused(CHECK, "palette.locked names no file"));
        return;
    };
    let path = root.join(rel);
    let palette: Value = match std::fs::read_to_string(&path) {
        Ok(t) => match serde_json::from_str(&t) {
            Ok(v) => v,
            Err(e) => {
                out.push(Verdict::refused(
                    CHECK,
                    format!("palette {rel} is not JSON: {e}"),
                ));
                return;
            }
        },
        Err(_) => return, // reported by missing_input
    };
    let mut found = Vec::new();
    collect_palette(&palette, "", &ramp_regions, false, &mut found);
    if found.is_empty() {
        out.push(Verdict::refused(
            CHECK,
            format!("palette {rel} holds no #RRGGBB colours in any recognised shape"),
        ));
        return;
    }
    entries.extend(found.into_iter().map(|(label, hex)| {
        let label = if label.is_empty() {
            "palette entry".to_string()
        } else {
            format!("palette entry {label}")
        };
        (label, hex)
    }));

    for (label, hex) in entries {
        let Some(rgb) = unit_rgb(&hex) else {
            out.push(Verdict::refused(
                CHECK,
                format!("{label} {hex} is not a #RRGGBB colour"),
            ));
            continue;
        };
        for ramp in ramps {
            let ramp_id = ramp["id"].as_str().unwrap_or("?");
            for gate in ramp["gates"].as_array().into_iter().flatten() {
                if gate_matches(gate, rgb) {
                    out.push(Verdict::refused(
                        CHECK,
                        format!(
                            "{label} {} passes gate {} of ramp {ramp_id}",
                            hex.to_ascii_uppercase(),
                            gate["id"].as_str().unwrap_or("?")
                        ),
                    ));
                }
            }
        }
    }
}

/// Tolerant palette reader: any `#RRGGBB` string anywhere in the JSON is a
/// palette entry, labelled by the key path it sits under. Entries under a key
/// that names a ramp-applied region are skipped (they are meant to pass).
/// Objects with `hex` / `color` / `colour` leaves are read the same way.
fn collect_palette(
    v: &Value,
    label: &str,
    ramp_regions: &BTreeSet<&str>,
    in_ramp_region: bool,
    out: &mut Vec<(String, String)>,
) {
    match v {
        Value::String(s) => {
            if parse_hex(s).is_some() && !in_ramp_region {
                out.push((label.to_string(), s.clone()));
            }
        }
        Value::Array(a) => {
            for item in a {
                collect_palette(item, label, ramp_regions, in_ramp_region, out);
            }
        }
        Value::Object(m) => {
            for (k, item) in m {
                let in_region = in_ramp_region || ramp_regions.contains(k.as_str());
                let next = match k.as_str() {
                    "hex" | "color" | "colour" | "value" | "colors" | "colours" | "palette"
                    | "entries" => label.to_string(),
                    _ if label.is_empty() => k.clone(),
                    _ => format!("{label}.{k}"),
                };
                collect_palette(item, &next, ramp_regions, in_region, out);
            }
        }
        _ => {}
    }
}

// ─── region_mask_colours_declared (mandatory with regions) ───────────────────

fn check_region_mask_colours_declared(spec: &Value, root: &Path, out: &mut Vec<Verdict>) {
    const CHECK: &str = "region_mask_colours_declared";
    let declared: BTreeSet<String> = spec["regions"]
        .as_object()
        .into_iter()
        .flatten()
        .map(|(k, _)| k.to_ascii_uppercase())
        .collect();
    for pose in spec["poses"].as_array().into_iter().flatten() {
        let Some(rel) = pose["regionMask"].as_str() else {
            continue;
        };
        let path = root.join(rel);
        if !path.is_file() {
            continue; // reported by missing_input
        }
        let img = match image::open(&path) {
            Ok(i) => i.to_rgba8(),
            Err(e) => {
                out.push(Verdict::refused(
                    CHECK,
                    format!("{rel} is not a readable PNG: {e}"),
                ));
                continue;
            }
        };
        let mut seen = BTreeSet::new();
        for px in img.pixels() {
            let [r, g, b, a] = px.0;
            if a == 0 {
                continue; // fully transparent: not an ID colour
            }
            let hex = format!("#{r:02X}{g:02X}{b:02X}");
            if !declared.contains(&hex) && seen.insert(hex.clone()) {
                out.push(Verdict::refused(
                    CHECK,
                    format!("{hex} in {rel} is not a key of regions"),
                ));
            }
        }
    }
}

// ─── inputs exist ────────────────────────────────────────────────────────────

fn check_inputs_exist(spec: &Value, root: &Path, out: &mut Vec<Verdict>) {
    for (rel, at) in referenced_inputs(spec) {
        if project_relative(&rel).is_err() {
            continue; // the shape check already refused this path
        }
        if !root.join(&rel).is_file() {
            out.push(Verdict::refused("missing_input", format!("{rel} ({at})")));
        }
    }
}

/// `#RRGGBB` to channels.
pub fn parse_hex(hex: &str) -> Option<(u8, u8, u8)> {
    let h = hex.strip_prefix('#')?;
    if h.len() != 6 || !h.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let n = u32::from_str_radix(h, 16).ok()?;
    Some(((n >> 16) as u8, (n >> 8) as u8, n as u8))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    const EXAMPLE: &str = include_str!(
        "../../../openspec/changes/studio-asset-pipeline/contract/examples/gatekeeper-v3.character-frames.json"
    );

    /// A project tree in a tempdir beside the test binary (never bare mktemp,
    /// never /tmp), with every file the spec names present.
    fn project_with(spec: &Value) -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        let root = dir.path().to_path_buf();
        let spec_path = root.join("art/families/family.json");
        fs::create_dir_all(spec_path.parent().unwrap()).unwrap();
        fs::write(&spec_path, serde_json::to_vec_pretty(spec).unwrap()).unwrap();
        // The locked palette: outline, skin, hair, hat, shoes, cream trousers,
        // teal. None is plum (r >= 0.39 with b >= 0.32 r and a blue-green gap).
        write_json(
            &root,
            spec["palette"]["locked"].as_str().unwrap_or("palette.json"),
            &serde_json::json!({
                "outline": "#1A1018",
                "skin": ["#F2C9A0", "#C98A5E"],
                "hair": ["#2B1B12"],
                "hat": ["#F5EBD0"],
                "shoes": ["#1F8A8A"]
            }),
        );
        for pose in spec["poses"].as_array().into_iter().flatten() {
            if let Some(p) = pose["control"]["image"].as_str() {
                write_png(&root, p, &["#000000"]);
            }
            for aux in pose["control"]["aux"].as_array().into_iter().flatten() {
                if let Some(p) = aux["image"].as_str() {
                    write_png(&root, p, &["#000000"]);
                }
            }
            if let Some(p) = pose["regionMask"].as_str() {
                // Declared region colours only.
                write_png(&root, p, &["#FF0000", "#00FF00", "#0000FF", "#FFFF00"]);
            }
        }
        for r in spec["references"].as_array().into_iter().flatten() {
            if let Some(p) = r["image"].as_str() {
                write_png(&root, p, &["#000000"]);
            }
        }
        (dir, spec_path)
    }

    fn write_json(root: &Path, rel: &str, v: &Value) {
        let p = root.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, serde_json::to_vec(v).unwrap()).unwrap();
    }

    /// A 4x1 RGBA PNG whose pixels are `colours` (padded with the last one).
    fn write_png(root: &Path, rel: &str, colours: &[&str]) {
        let p = root.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        let mut img = image::RgbaImage::new(4, 1);
        for (x, px) in img.enumerate_pixels_mut().map(|(x, _, p)| (x, p)) {
            let hex = colours[(x as usize).min(colours.len() - 1)];
            let (r, g, b) = parse_hex(hex).unwrap();
            *px = image::Rgba([r, g, b, 255]);
        }
        img.save_with_format(p, image::ImageFormat::Png).unwrap();
    }

    fn example() -> Value {
        serde_json::from_str(EXAMPLE).unwrap()
    }

    fn lines(v: &[Verdict]) -> Vec<String> {
        v.iter().map(ToString::to_string).collect()
    }

    /// The example in the contract directory validates ok against a project
    /// tree that holds every file it names.
    #[test]
    fn studio_contract_example_validates_ok() {
        let spec = example();
        let (dir, spec_path) = project_with(&spec);
        let verdicts = validate_family(&spec_path, dir.path());
        assert_eq!(lines(&verdicts), vec!["ok:family:gatekeeper-v3"]);
    }

    /// The real v0 case: kumbia-kombat's old outline #1A1020 passed the cool
    /// gate, which is how palette_fails_all_gates was found; the review moved
    /// the outline to #1A1018. The v0 record elides the cool gate ("…cool,
    /// pink"), so this is a plausible reconstruction: a cool colour has at
    /// least as much blue as red, and blue clearly above green. #1A1020
    /// (r .102, g .063, b .125) passes it; #1A1018 (b .094) fails it.
    #[test]
    fn studio_contract_refuses_outline_inside_a_gate() {
        let cool = serde_json::json!({
            "id": "cool",
            "all": [
                { "lhs": "b", "op": ">=", "rhs": { "mul": [1.0, "r"] } },
                { "lhs": { "sub": ["b", "g"] }, "op": ">=", "rhs": 0.047059 }
            ]
        });
        let mut spec = example();
        spec["reservedRamps"][0]["gates"]
            .as_array_mut()
            .unwrap()
            .push(cool);

        // The accepted outline fails every gate, so the family is ok.
        let (dir, spec_path) = project_with(&spec);
        assert_eq!(
            lines(&validate_family(&spec_path, dir.path())),
            vec!["ok:family:gatekeeper-v3"]
        );

        // The old outline passes the cool gate: refused, naming colour and gate.
        spec["outline"] = Value::from("#1A1020");
        let (dir, spec_path) = project_with(&spec);
        let got = lines(&validate_family(&spec_path, dir.path()));
        assert_eq!(
            got,
            vec![
                "refused:palette_fails_all_gates:outline #1A1020 passes gate cool of ramp kumbia-outfit"
            ]
        );
    }

    /// A palette entry outside the ramp-applied region that passes a gate is
    /// refused too; an entry inside that region (cloth) may pass.
    #[test]
    fn studio_contract_refuses_a_non_cloth_palette_entry_inside_a_gate() {
        let spec = example();
        let (dir, spec_path) = project_with(&spec);
        // Plum #7A3B8C: r .478, g .231, b .549 -> passes the plum gate.
        write_json(
            dir.path(),
            "tool/art/palettes/gatekeeper.json",
            &serde_json::json!({
                "outline": "#1A1018",
                "cloth": ["#7A3B8C"],
                "hat": ["#7A3B8C", "#F5EBD0"]
            }),
        );
        let got = lines(&validate_family(&spec_path, dir.path()));
        assert_eq!(
            got,
            vec![
                "refused:palette_fails_all_gates:palette entry hat #7A3B8C passes gate plum of ramp kumbia-outfit"
            ]
        );
    }

    /// Every pixel colour of a regionMask PNG must be a key of regions. The
    /// refusal names the undeclared colour and the file.
    #[test]
    fn studio_contract_refuses_an_undeclared_region_mask_colour() {
        let spec = example();
        let (dir, spec_path) = project_with(&spec);
        write_png(
            dir.path(),
            "art_runs/inputs/gatekeeper-v3/left_hand.peak.regions.png",
            &["#FF0000", "#123456"],
        );
        let got = lines(&validate_family(&spec_path, dir.path()));
        assert_eq!(
            got,
            vec![
                "refused:region_mask_colours_declared:#123456 in art_runs/inputs/gatekeeper-v3/left_hand.peak.regions.png is not a key of regions"
            ]
        );
    }

    /// `kind` is an open enum: an unknown kind is refused with the known list.
    #[test]
    fn studio_contract_refuses_an_unknown_kind_listing_the_known_ones() {
        let mut spec = example();
        spec["kind"] = Value::from("ship-hulls");
        let (dir, spec_path) = project_with(&spec);
        let got = lines(&validate_family(&spec_path, dir.path()));
        assert_eq!(
            got,
            vec![
                "refused:unknown_kind:ship-hulls is not a known kind; known kinds: character-frames, layered-parts"
            ]
        );
    }

    /// Missing inputs are named relative to the project root.
    #[test]
    fn studio_contract_refuses_missing_input_files() {
        let spec = example();
        let (dir, spec_path) = project_with(&spec);
        fs::remove_file(
            dir.path()
                .join("art_runs/inputs/gatekeeper-v3/left_hand.peak.depth.png"),
        )
        .unwrap();
        fs::remove_file(dir.path().join("assets/art/ensemble/gatekeeper-v2.png")).unwrap();
        let got = lines(&validate_family(&spec_path, dir.path()));
        assert_eq!(
            got,
            vec![
                "refused:missing_input:assets/art/ensemble/gatekeeper-v2.png (references[0].image)",
                "refused:missing_input:art_runs/inputs/gatekeeper-v3/left_hand.peak.depth.png (poses[0].control.aux[0].image)",
            ]
        );
    }

    /// A pose carrying a camera, a target without a room, and a bad gate
    /// operand are schema refusals, each naming its path.
    #[test]
    fn studio_contract_refuses_schema_shape_errors_by_path() {
        let mut spec = example();
        spec["poses"][0]["camera"] = Value::from("side-on");
        spec["targets"][1].as_object_mut().unwrap().remove("room");
        spec["reservedRamps"][0]["gates"][0]["all"][0]["lhs"] = Value::from("alpha");
        let (dir, spec_path) = project_with(&spec);
        let got = lines(&validate_family(&spec_path, dir.path()));
        assert!(
            got.iter()
                .any(|l| l.starts_with("refused:schema:poses[0].camera")),
            "{got:?}"
        );
        assert!(
            got.iter()
                .any(|l| l.starts_with("refused:schema:targets[1].room")),
            "{got:?}"
        );
        assert!(
            got.iter()
                .any(|l| l.starts_with("refused:schema:reservedRamps[0].gates[0].all[0].lhs")),
            "{got:?}"
        );
        assert!(!got.iter().any(|l| l.starts_with("ok:")), "{got:?}");
    }

    /// The tool argument is a project-relative path: absolute paths, `..` and
    /// hidden segments are refused before anything is read.
    #[test]
    fn studio_contract_project_relative_refuses_escapes() {
        assert_eq!(
            project_relative("art/families/g.json"),
            Ok("art/families/g.json".to_string())
        );
        assert!(project_relative("/etc/passwd").is_err());
        assert!(project_relative("../x.json").is_err());
        assert!(project_relative("a/../x.json").is_err());
        assert!(project_relative(".git/config").is_err());
        assert!(project_relative("").is_err());
    }
}
