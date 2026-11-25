-- @trace order:1903-djsq, order:1265-8qr6, order:2378-hcxg
--
-- common/privatebus.lua — a keyring fixture never reaches the operator's session bus. The Lua
-- counterpart of scripts/test-support/private-session-bus.sh.
--
--   local bus = require "common.privatebus"
--   bus.env{ HOME = d.abs }   -- a child environment: PATH, HOME and a bus address that cannot exist
--
-- WHY. gnome-keyring-daemon 50.0 aborts in its own property handler (1265-8qr6) and D-Bus
-- re-activates it LOCKED; gh then blocks and every push fails until the operator unlocks. The door
-- passes DBUS_SESSION_BUS_ADDRESS on to a child, so a stub's fall-through to the real busctl, gh or
-- secret-tool would open the real bus. A dead address, not a private daemon: nothing to reap, and
-- sd-bus, libdbus, gio and godbus all honour the variable first.
--
-- Guarded by scripts/lua/test-keyring-fixtures-use-a-private-bus.lua.

local M = {}
M.ADDRESS = "unix:path=/nonexistent/tillandsias-private-bus/no-bus"
function M.env(more)
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME") }
    for k, v in pairs(more or {}) do e[k] = v end
    e.DBUS_SESSION_BUS_ADDRESS = M.ADDRESS
    return e
end
return M
