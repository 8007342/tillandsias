-- @trace spec:cli-mode, order:1847-5xv3, order:2168-dqph
-- @env PATH HOME CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN CARGO_TARGET_DIR
--
-- test-headless-cloud-one-shot.lua — `tillandsias --cloud <o/r> --opencode`
-- (or --codex) with no terminal on stdin is a one-shot. Ported from the .sh of
-- the same name (order 2168-dqph); same five checks, same verdict.
--
--   1 PROMPT    no --prompt runs the queue default; a given prompt wins; an
--               interactive start is unchanged
--   2 BACKSTOP  past TILLANDSIAS_ONE_SHOT_MAX_MINUTES the forge is removed,
--               failed:timeout is printed and reported, and the launcher exits
--               124 through its own return path (Vault cleanup still runs)
--   3 QUEUE     the report goes through the QueueClient seam (NoQueue for now)
--   4 WIRING    both agent dispatch sites check timed_out() after the cleanup
--               wrapper returns, and the prompt is resolved before either
--
-- 1-3 are the unit tests in crates/tillandsias-headless/src/one_shot.rs; 4 reads
-- main.rs.
--
-- Usage: tillandsias-plan script run scripts/lua/test-headless-cloud-one-shot.lua
-- Verdict: ok:headless-cloud-one-shot:5

local MAIN = "crates/tillandsias-headless/src/main.rs"
local pass, fail = 0, 0
local function check(name, cond, why)
    if cond then pass = pass + 1; out.line("ok:   " .. name)
    else fail = fail + 1; out.line("FAIL: " .. name .. (why and (" — " .. why) or "")) end
end

local e = {}
for _, k in ipairs({ "PATH", "HOME", "CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN", "CARGO_TARGET_DIR" }) do e[k] = env.get(k) end
local r = proc.run({ argv = { "cargo", "test", "-q", "-p", "tillandsias-headless", "--bin", "tillandsias",
    "--features", "tray,listen-vsock", "one_shot::" }, env = e, timeout_ms = 1800000 })
local all = (r.stdout or "") .. "\n" .. (r.stderr or "")
local passed = nil
for _, l in ipairs(text.lines(all)) do
    local n = l:match("^test result: ok%. ([1-9]%d*) passed")
    if n then passed = n end
end
if passed then
    check("1-3 one_shot unit tests pass (" .. passed .. " passed)", true)
else
    local ls = text.lines(all)
    for i = math.max(1, #ls - 19), #ls do if ls[i] then log.raw(ls[i]) end end
    check("1-3 one_shot unit tests", false, "rc=" .. tostring(r.code))
end

local src = fs.read(MAIN) or ""
local n = 0
for _ in src:gmatch("if one_shot::timed_out%(%) {") do n = n + 1 end
check("4 both agent dispatch sites honour the timeout", n == 2, "timed_out() checks: " .. n .. ", want 2")
check("4 the prompt is resolved before dispatch",
    text.contains(src, "let prompt = one_shot::effective_prompt(prompt, one_shot);"), "effective_prompt not wired")
check("4 only --opencode/--codex on --cloud without a tty",
    text.contains(src, "one_shot::is_one_shot(is_cloud, opencode || codex, io::stdin().is_terminal())"), "is_one_shot call changed")
check("4 the queue post is the no-op client", text.contains(src, "Box::new(one_shot::NoQueue)"), "NoQueue not wired")

if fail > 0 then verdict.emit("violation:headless-cloud-one-shot:" .. fail, 1) end
verdict.ok("headless-cloud-one-shot", tostring(pass))
