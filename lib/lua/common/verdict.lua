-- @trace order:2080-zcur
-- common.verdict — the house verdict lines a test prints, in the format the
-- existing scripts/lua/test-*.lua already emit (a verdict string is an
-- interface; do not respell these):
--   ok:<name>:<n> arms            exit 0
--   violation:<name>:<n>-failed   exit 1
--   skip:<name>:<reason>          exit 0
--   refused:<name>:<reason>       exit 1   (the fixture could not set up)
-- A port of a shell test whose callers grep a different line passes that
-- line explicitly to emit().
local M = {}

function M.ok(name, passed) verdict.emit("ok:" .. name .. ":" .. passed .. " arms", 0) end
function M.violation(name, nfailed) verdict.emit("violation:" .. name .. ":" .. nfailed .. "-failed", 1) end
function M.skip(name, reason) verdict.emit("skip:" .. name .. ":" .. reason, 0) end
function M.refused(name, reason) verdict.emit("refused:" .. name .. ":" .. reason, 1) end
function M.emit(line, code) verdict.emit(line, code) end

return M
