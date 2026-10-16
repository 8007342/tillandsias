-- @trace order:1087-h2z9, order:865-q4wp, order:1632-y3ir
--
-- check-markdown-distillation.lua — PORTED from check-markdown-distillation.sh
-- (1632-y3ir). Every tracked *.md sits under an allowlisted root; anything
-- else is noncanonical markdown that must be distilled into a canonical root.
--
-- THE ALLOWLIST IS HERE, IN LUA. It is NOT read from
-- methodology/markdown-distillation.yaml — that file is an ARCHIVE RECORD of
-- what was distilled in 2026-06, and its `canonical_markdown_roots:` list has
-- already drifted from this one (it lacks .claude/commands, the SKILL.md
-- surfaces, and images/default/cheatsheets). Editing the YAML changes nothing
-- here. The refusal below used to send readers there anyway; see the note on it.
--
-- VERDICTS (stdout):
--   ok: markdown distillation paths                       exit 0
--   violation:markdown-distillation:<n> noncanonical      exit 1
--   refused:markdown-distillation:not-a-git-checkout      exit 1
-- The ok line keeps the .sh's exact text (space after the colon), which
-- gate step 145's STEP_SECOND_REGIME pin quotes. The .sh printed NOTHING on
-- stdout when it failed (the paths and the remedy went to stderr, exit 1);
-- the runner needs a verdict line, so the port adds the violation line. Both
-- callers (gate step 145, scripts/local-ci.sh) read only the exit code.
-- Outside a git checkout the .sh died in `git rev-parse` with exit 128; the
-- runner's codes stop at 3, so the port says refused with exit 1 (the same
-- class: the runner books any other non-zero exit as refused).
--
-- QUIRKS KEPT FROM THE .sh (1632-y3ir records them; none is fixed here):
--   * a bash case `*` matches '/', so every `<root>/*` entry admits any depth,
--     and scripts/*/README.md admits scripts/a/b/README.md although its comment
--     says "one level down";
--   * git's '*.md' pathspec is case-sensitive: README.MD is never checked;
--   * a path git quotes (non-ASCII under core.quotePath) is not a file under
--     its quoted name, so it is skipped silently, as `[[ -f ]]` skipped it;
--   * the .sh read `git ls-files` through process substitution, whose exit
--     status set -e never sees: a failing ls-files reads as an empty list and
--     the check says ok. The port ignores that status too.
-- WHAT THE PORT MAKES SLIGHTLY DIFFERENT: `[[ -f ]]` is "a regular file after
-- following symlinks". The port asks fs.exists (any existing path, symlinks
-- followed) and drops gitlinks (mode 160000, a submodule directory), so the
-- only case that differs is a tracked symlink to a DIRECTORY named *.md
-- (none exist). The noncanonical lines on stderr come in git's byte order,
-- not `sort`'s locale order.

local NAME = "markdown-distillation"

-- Each entry is a bash case glob, in the .sh's order: `*` matches anything,
-- '/' included, and every other character is literal.
local ALLOWED = {
    "README.md", "TRACES.md", "CLAUDE.md",
    -- ORDER 865-q4wp — AGENT-RUNTIME INSTRUCTION ENTRYPOINTS, the same class as
    -- CLAUDE.md directly above. AGENTS.md is the file; GEMINI.md and
    -- .github/copilot-instructions.md are SYMLINKS to it (verified: all three
    -- share sha 44d7c24f2ea6, and `ls -l` shows the links). One document, three
    -- names, because each agent runtime looks for its own. The policy's own
    -- validation_rule already permits these — "new Markdown outside canonical
    -- roots is allowed only for runtime command or skill surfaces" — but the
    -- allowlist never learned about them, so the gate failed on a file class it
    -- was written to allow.
    -- CODEX.md joined the same class on 2026-09-11 (440cde994): a fourth name
    -- for the one AGENTS.md document, a symlink like GEMINI.md, added so Codex
    -- discovers the forge-awareness block. It shipped through a green --check
    -- because this policy runs only in --ci-full (1087-h2z9); the release gate
    -- caught it the same day.
    "AGENTS.md", "GEMINI.md", "CODEX.md", ".github/copilot-instructions.md",
    -- PRIVACY.md — the Microsoft Store submission requires a public privacy
    -- policy URL (Partner Center rejects a listing without one), and that URL
    -- points at this file's GitHub blob at repo root. Moving it into docs/
    -- breaks the submitted URL, so it is a distribution surface pinned by
    -- location, same class as README.md above. Added when the 776-g6r3 Store
    -- lane landed it (windows-next 9699522c6) and the promotion gate flagged
    -- it as noncanonical.
    "PRIVACY.md",
    -- A RUNTIME SURFACE IN THE STRICTEST SENSE: inject_startup_context() appends
    -- this file VERBATIM into .forge-startup-context.md at every forge launch,
    -- read from the MOUNTED CHECKOUT (743-y5wh), and it carries its own litmus.
    -- It is executable context, not prose about the project.
    "images/default/startup-context-addendum.md",
    -- The same class (1724-kcj4): agent-profile.sh links this file at every
    -- forge launch as each harness's USER-level instructions (~/.claude/
    -- CLAUDE.md, ~/.codex/AGENTS.md, ...). It is what the agent is told, not
    -- prose about the project; its fixture is forge_agent_guidance.rs.
    "images/default/config-overlay/mcp/forge-agent-guidance.md",
    -- A README documenting the scripts it sits beside. Narrower than the
    -- `crates/*` entry below, which admits ALL markdown anywhere under crates/:
    -- this admits only a README (at any depth: `*` matches '/', see above).
    "scripts/*/README.md",
    "docs/*", "cheatsheets/*", "openspec/*", "plan/*", "skills/*", "crates/*",
    "methodology/specs/*",
    ".claude/commands/*", ".opencode/commands/*", ".opencode/command/*", ".github/prompts/*",
    -- 2026-08-28 repair: a runtime instruction surface the OpenCode agent loads at launch — same class as the AGENTS.md entry above.
    ".opencode/instructions/*",
    -- .agents/skills: openspec's vendor-neutral skill target (codex since 1.13.x; order 1441-myz3).
    ".agents/skills/*/SKILL.md", ".claude/skills/*/SKILL.md", ".opencode/skills/*/SKILL.md",
    ".codex/skills/*/SKILL.md", ".gemini/skills/*/SKILL.md", ".github/skills/*/SKILL.md",
    "images/default/cheatsheets/*", "images/default/config-overlay/opencode/*",
    "@methodology/.opencode/*",
}

-- bash case glob -> anchored Lua pattern: `*` is `.*`, the rest literal.
local PATTERNS = {}
for i, g in ipairs(ALLOWED) do
    local p = g:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*")
    PATTERNS[i] = "^" .. p .. "$"
end

local function allowed_path(path)
    for _, p in ipairs(PATTERNS) do
        if path:match(p) then return true end
    end
    return false
end

local function git(args)
    local argv = { "git" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 60000 })
    return r.status == "exited" and r.code == 0, r.stdout or ""
end

local in_repo, top = git({ "rev-parse", "--show-toplevel" })
top = top:gsub("[\r\n]+$", "")
if not in_repo or top == "" then
    verdict.emit("refused:" .. NAME .. ":not-a-git-checkout", 1,
        "git rev-parse --show-toplevel failed: run from inside the repository")
end

-- `-s` adds the mode, so a gitlink (a submodule directory) is told apart.
local _, listing = git({ "-C", top, "ls-files", "-s", "*.md" })
local bad = 0
for line in listing:gmatch("[^\n]+") do
    local mode, path = line:match("^(%d+) %x+ %d+\t(.*)$")
    if mode and mode ~= "160000" and fs.exists(path) and not allowed_path(path) then
        log.raw("noncanonical markdown: " .. path)
        bad = bad + 1
    end
end

if bad > 0 then
    -- THE REMEDY THIS LINE USED TO GIVE DOES NOT WORK, and that is worth more
    -- than the paths it blocked. It said "Add an inventory row to
    -- methodology/markdown-distillation.yaml" — but this script never reads that
    -- file. A reader following the instruction edits a YAML, re-runs, and is
    -- refused identically, with no clue why. An error that names a remedy it
    -- cannot honour costs more than one that names none, because it spends the
    -- reader's trust as well as their time (865-q4wp; same shape as
    -- promote-stable.sh's demotion comment, 864-mk2p).
    verdict.emit("violation:" .. NAME .. ":" .. bad .. " noncanonical", 1, table.concat({
        "Fix ONE of these — the allowlist is in THIS script, not in any YAML:",
        "  (a) if it is a runtime/skill surface, add its path to ALLOWED above;",
        "  (b) otherwise distill it into a canonical root (docs/, cheatsheets/,",
        "      openspec/, plan/, methodology/specs/) and archive the original under",
        "      plan/archive/, recording it in methodology/markdown-distillation.yaml.",
        "  The YAML is an archive RECORD of past distillations; editing it alone",
        "  changes nothing this check sees.",
    }, "\n"))
end

verdict.emit("ok: markdown distillation paths", 0)
