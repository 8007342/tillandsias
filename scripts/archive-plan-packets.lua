#!/usr/bin/env tillandsias-plan lua
-- archive-plan-packets.lua — archive terminal plan packets into plan/archive/
-- Replacement for scripts/archive-plan-packets.rb using the tillandsias-managed Lua runtime.
-- @trace order:398, order:1132-r4mt, spec:ci-release

local index_path = "plan/index.yaml"
local archive_dir = "plan/archive"

-- Parse CLI arguments
local i = 1
while i <= #arg do
  if arg[i] == "--index" and arg[i + 1] then
    index_path = arg[i + 1]
    i = i + 2
  elseif arg[i] == "--archive" and arg[i + 1] then
    archive_dir = arg[i + 1]
    i = i + 2
  else
    i = i + 1
  end
end

-- Ensure archive directory exists
os.execute(string.format("mkdir -p %q", archive_dir))

-- Resolve plan binary
local plan_bin = os.getenv("TILLANDSIAS_PLAN_BIN")
if not plan_bin or plan_bin == "" then
  plan_bin = "target/release/tillandsias-plan"
end

local function run_cmd(cmd)
  local handle = io.popen(cmd)
  if not handle then return nil, -1 end
  local output = handle:read("*a")
  local success, exit_type, code = handle:close()
  local rc = 0
  if not success then
    rc = (exit_type == "exit" and code) or 1
  end
  return output, rc
end

local TERMINAL_STATUSES = {"completed", "done"}
local terminal_ids = {}
local id_aliases = {}

for _, st in ipairs(TERMINAL_STATUSES) do
  local cmd = string.format("%s --index %q query --status %s --limit 0 2>/dev/null", plan_bin, index_path, st)
  local out, rc = run_cmd(cmd)
  if rc ~= 0 then
    io.stderr:write(string.format("archive-plan-packets: could not read the fold via %s (--index %s, status %s). REFUSING to fall back to a base-index grep: that is the defect this replaced, and it silently archives reopened rows.\n", plan_bin, index_path, st))
    os.exit(1)
  end

  for line in out:gmatch("[^\r\n]+") do
    local cols = {}
    for col in line:gmatch("[^\t]+") do
      table.insert(cols, col:match("^%s*(.-)%s*$"))
    end
    local names = {}
    if cols[1] and cols[1] ~= "" then table.insert(names, cols[1]) end
    if cols[2] and cols[2] ~= "" then table.insert(names, cols[2]) end

    for _, k in ipairs(names) do
      terminal_ids[k] = true
      id_aliases[k] = names
    end
  end
end

-- Verify fold reports packets
local all_cmd = string.format("%s --index %q query --limit 0 2>/dev/null", plan_bin, index_path)
local all_ids, all_rc = run_cmd(all_cmd)
if all_rc ~= 0 or not all_ids or all_ids:match("%S") == nil then
  io.stderr:write(string.format("archive-plan-packets: the fold reports NO PACKETS AT ALL for %s. That is an unreadable ledger, not an empty one — refusing rather than archiving nothing and reporting success.\n", index_path))
  os.exit(1)
end

if next(terminal_ids) == nil then
  print("Archived 0 packets (no terminal rows remain — already archived).")
  os.exit(0)
end

-- A row still addressed by a live fragment is not archivable.
local fragments_dir
local idx_dir = index_path:match("^(.*)/[^/]+$")
if idx_dir then
  fragments_dir = idx_dir .. "/index.d"
else
  fragments_dir = "plan/index.d"
end

local frag_list_cmd = string.format("ls -1 %q/*.yaml 2>/dev/null", fragments_dir)
local frag_files_out, _ = run_cmd(frag_list_cmd)
local addressed_ids = {}

if frag_files_out then
  local frag_paths = {}
  for f in frag_files_out:gmatch("[^\r\n]+") do
    table.insert(frag_paths, f)
  end
  table.sort(frag_paths)

  for _, frag in ipairs(frag_paths) do
    local frag_cmd = string.format("%s fragment-event-packets %q 2>/dev/null", plan_bin, frag)
    local out, rc = run_cmd(frag_cmd)
    if rc ~= 0 then
      io.stderr:write(string.format("archive-plan-packets: could not read %s — treating every terminal packet as addressed by it is not possible, so REFUSING the sweep rather than archiving rows whose events this fragment may still address.\n", frag))
      os.exit(1)
    end
    for line in out:gmatch("[^\r\n]+") do
      local k = line:match("^%s*(.-)%s*$")
      if k and k ~= "" then
        addressed_ids[k] = true
      end
    end
  end
end

-- Reject by EVERY name of an addressed packet
for name, _ in pairs(addressed_ids) do
  if id_aliases[name] then
    for _, alias_name in ipairs(id_aliases[name]) do
      terminal_ids[alias_name] = nil
    end
  end
  terminal_ids[name] = nil
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function packet_in_archive(content, id)
  if not id then return false end
  for l in content:gmatch("[^\r\n]+") do
    local k, v = l:match("^    %- ([%w_]+):%s*(.-)%s*$")
    if (k == "packet_id" or k == "id" or k == "order") and v then
      local clean_v = v:gsub('^"(.-)"$', '%1'):gsub("^'(.-)'$", "%1"):match("^%s*(.-)%s*$")
      if clean_v == id then
        return true
      end
    end
  end
  return false
end

local function flush_packet(lines, closed, date, id, active_lines, archive_directory)
  if #lines == 0 then return 0 end
  if closed then
    local archive_file = string.format("%s/packets-%s.yaml", archive_directory, date)
    if not file_exists(archive_file) then
      local af = io.open(archive_file, "w")
      if af then
        af:write("plan_index:\n  steps:\n")
        af:close()
      end
    end

    local existing_content = ""
    local rf = io.open(archive_file, "r")
    if rf then
      existing_content = rf:read("*a")
      rf:close()
    end

    if not packet_in_archive(existing_content, id) then
      local af = io.open(archive_file, "a")
      if af then
        for _, l in ipairs(lines) do
          af:write(l)
        end
        af:close()
        return 1
      end
    end
    return 0
  else
    for _, l in ipairs(lines) do
      table.insert(active_lines, l)
    end
    return 0
  end
end

local f_idx = io.open(index_path, "r")
if not f_idx then
  io.stderr:write("archive-plan-packets: cannot open " .. index_path .. "\n")
  os.exit(1)
end

local active_lines = {}
local current_packet_lines = {}
local in_packet = false
local closed = false
local packet_date = "2026-05"
local packet_id = nil
local archived_count = 0

for line in f_idx:lines("L") do
  local key, raw_id = line:match("^    %- ([%w_]+):%s*(.-)%s*[\r\n]*$")
  if (key == "packet_id" or key == "id" or key == "order") and raw_id then
    archived_count = archived_count + flush_packet(current_packet_lines, closed, packet_date, packet_id, active_lines, archive_dir)

    in_packet = true
    current_packet_lines = {line}
    closed = false
    packet_date = "2026-05"
    packet_id = raw_id:gsub('^"(.-)"$', '%1'):gsub("^'(.-)'$", "%1"):match("^%s*(.-)%s*$")
    closed = (terminal_ids[packet_id] == true)
  elseif in_packet then
    if closed then
      local ts_m = line:match("^[ \t]*ts:%s*\"?(%d%d%d%d%-%d%d)")
      if ts_m then
        packet_date = ts_m
      end
    end

    if line:match("^[a-zA-Z]") and not line:match("^ ") then
      archived_count = archived_count + flush_packet(current_packet_lines, closed, packet_date, packet_id, active_lines, archive_dir)
      in_packet = false
      current_packet_lines = {}
      table.insert(active_lines, line)
    else
      table.insert(current_packet_lines, line)
    end
  else
    table.insert(active_lines, line)
  end
end
f_idx:close()

archived_count = archived_count + flush_packet(current_packet_lines, closed, packet_date, packet_id, active_lines, archive_dir)

local out_idx = io.open(index_path, "w")
if not out_idx then
  io.stderr:write("archive-plan-packets: cannot write to " .. index_path .. "\n")
  os.exit(1)
end
for _, l in ipairs(active_lines) do
  out_idx:write(l)
end
out_idx:close()

print(string.format("Archived %d packets.", archived_count))
