-- @class observing
local r = proc.run {
    argv = {arg[1], arg[2], "child", arg[3]},
    timeout_ms = 4000,
    group = true,
}
out.line("proc-stdout:" .. r.stdout)
log.raw("proc-stderr:" .. r.stderr)
if not r.ok then return verdict.refused("producer", json.encode(r)) end
return verdict.ok("producer", r.status, r.code)
