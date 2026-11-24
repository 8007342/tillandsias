-- @trace order:1248-j6vd
-- @env TILLANDSIAS_DEVINF_UNDER_TEST
--
-- test-dev-inference-start-refusal-names-cause.lua — criterion 2 of 1248-j6vd: a
-- GPU container start that fails names its CAUSE and the LOG PATH in the refusal.
-- Ported from the .sh. Measured on macuahuitl: dev-inference-ensure.sh printed a
-- bare `blocked:container-start-failed`, and the cause (a CDI spec mounting a
-- library the host no longer had) sat in serve.log.
--
--   1 CAUSE    podman run fails with an error line: the refusal keeps its prefix,
--              quotes that error, names the log path, exits 1, one stdout line
--   2 STALE    the log already holds an OLDER failure: THIS attempt's is quoted
--   3 FALLBACK a failure with no error-shaped line gets a named fallback
--   4 CONTROL  no image: blocked:image-missing:build-inference, unchanged
--
-- Hermetic: podman and curl are PATH stubs (curl fails, so the endpoint is
-- down), HOME and the state dir are scratch, and PATH carries no tillandsias, so
-- the tier is cpu. TILLANDSIAS_DEVINF_UNDER_TEST overrides the subject.
--
-- Verdict: ok:dev-inference-start-refusal-names-cause:<n> | violation:…

local fixture = require "common.fixture"
local T = fixture.new("dev-inference-start-refusal-names-cause")
local SH = fixture.posix_shell()
local SUBJECT = fs.read(env.get("TILLANDSIAS_DEVINF_UNDER_TEST") or "scripts/dev-inference-ensure.sh")
if not SUBJECT then T:refuse("no-subject") end

local function case(tag, image, err, old_log)
    local d = T:scratch(tag)
    for _, s in ipairs({ "bin", "home", "state", "scripts" }) do fs.mkdir(d.rel .. "/" .. s) end
    fs.write(d.rel .. "/scripts/dev-inference-ensure.sh", SUBJECT)
    fs.write(d.rel .. "/scripts/nvidia-cdi-ensure.sh", "#!/usr/bin/env bash\necho skip:nvidia-cdi:no-gpu\n")
    fs.write(d.rel .. "/bin/curl", "#!/usr/bin/env bash\nexit 7\n")
    -- The error text is a file, never generated code: pasted into a heredoc, its
    -- backticks ran as a command substitution.
    fs.write(d.rel .. "/run-err", err == "" and "" or err .. "\n")
    fs.write(d.rel .. "/bin/podman", '#!/usr/bin/env bash\nD="${0%/bin/*}"\ncase "$1" in\n    container) exit 1 ;;\n    images) ' ..
        (image and "echo localhost/tillandsias-inference:v56.9.23.1; " or "") ..
        'exit 0 ;;\n    run) cat "$D/run-err" >&2; exit 126 ;;\n    *) exit 0 ;;\nesac\n')
    if old_log then fs.write(d.rel .. "/state/serve.log", old_log) end
    -- PATH is set in the shell, from its own directory (msys; see 2272-cuxh).
    fs.write(d.rel .. "/go.sh", 'D="$(cd "$(dirname "$0")" && pwd)"\nPATH="$D/bin:/usr/bin:/bin" HOME="$D/home" ' ..
        'TILLANDSIAS_DEV_INFERENCE_HOME="$D/state" TILLANDSIAS_DEV_INFERENCE_READY_SECS=1 \\\n' ..
        '    bash "$D/scripts/dev-inference-ensure.sh" </dev/null\nrc=$?\necho "$D" > "$D/where"\nexit $rc\n')
    T:must{ "chmod", "+x", d.abs .. "/bin/curl", d.abs .. "/bin/podman", d.abs .. "/scripts/nvidia-cdi-ensure.sh" }
    local r = T:run{ SH, d.abs .. "/go.sh", timeout_ms = 30000 }
    local out = r.stdout or ""
    local _, nl = out:gsub("\n", "")
    return text.trim(out), r.code, nl, text.trim(fs.read(d.rel .. "/where") or "") .. "/state/serve.log"
end
local ERR = "Error: crun: open `/usr/lib64/libnvidia-egl-gbm.so.1.1.3`: $HOME No such file or directory: OCI runtime attempted to invoke a command that was not found"

local o, rc, nl, log = case("cause", true, ERR)
T:arm("1a CAUSE the refusal quotes podman's error and names the log path",
    o:sub(1, 32) == "blocked:container-start-failed:E" and o:find("libnvidia-egl-gbm.so.1.1.3", 1, true) ~= nil
        and o:sub(-(#log + 5)) == " log=" .. log, o)
T:arm("1b CAUSE exit 1, as blocked:* always was", rc == 1, rc)
T:arm("1c CAUSE exactly one stdout line (the grammar)", nl == 1, nl)
o = case("stale", true, "Error: this attempt's cause", "Error: an OLD failure from yesterday\n")
T:arm("2a STALE the refusal quotes THIS attempt's error, never the older one",
    o:find("this attempt's cause", 1, true) ~= nil and not o:find("OLD failure", 1, true), o)
o, rc, nl, log = case("stale-only", true, "", "Error: an OLD failure from yesterday\n")
T:arm("2b STALE an old failure is not quoted when this attempt wrote none (2a cannot see it: the newest line wins there)",
    o == "blocked:container-start-failed:no-error-line-in-log log=" .. log, o)
o, rc, nl, log = case("fallback", true, "")
T:arm("3 FALLBACK no error-shaped line gets a named fallback, still with the log path",
    o == "blocked:container-start-failed:no-error-line-in-log log=" .. log, o)
o = case("noimage", false, ERR)
T:arm("4 CONTROL no image still refuses as image-missing", o == "blocked:image-missing:build-inference", o)
T:finish()
