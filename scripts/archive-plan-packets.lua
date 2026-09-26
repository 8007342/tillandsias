#!/usr/bin/env tillandsias-plan lua
-- archive-plan-packets.lua — archive terminal plan packets into plan/archive/
-- Replacement for scripts/archive-plan-packets.rb using the tillandsias-managed Lua runtime.
-- @trace order:398, order:1132-r4mt, order:1380-u7sq, spec:ci-release
--
-- ORDER 1380-u7sq: this script runs in the DEFAULT sandboxed `tillandsias-plan
-- lua` environment. It no longer needs `--unsandboxed`:
--   * processes go through proc.run{argv=...} (1384-aixy): no shell string,
--     no quoting, no `2>/dev/null` hiding a failed query, and it runs the same
--     on native Windows, where io.popen/os.execute went through cmd.exe and
--     failed (measured by yolanda 2026-09-26: `mkdir -p` made a directory
--     named "-p", and the fold query never ran);
--   * files go through fs.read / fs.write / fs.mkdir / fs.list, rooted at the
--     repository root. The --check path points TILLANDSIAS_REPO_ROOT at its
--     per-run scratch copy, so the whole script is confined to that copy;
--   * the plan binary comes ONLY from --plan-bin. The old hardcoded
--     target/release/tillandsias-plan fallback was the 721-nyev shape (wrong
--     under a redirected CARGO_TARGET_DIR, a stale ELF beside a live .exe),
--     so a missing --plan-bin is a refusal, not a guess.

local index_path = "plan/index.yaml"
local archive_dir = "plan/archive"
local plan_bin = nil

local i = 1
while i <= #arg do
  if arg[i] == "--index" and arg[i + 1] then
    index_path = arg[i + 1]
    i = i + 2
  elseif arg[i] == "--archive" and arg[i + 1] then
    archive_dir = arg[i + 1]
    i = i + 2
  elseif arg[i] == "--plan-bin" and arg[i + 1] then
    plan_bin = arg[i + 1]
    i = i + 2
  else
    i = i + 1
  end
end

-- A refusal: the reason on stderr, then a non-zero exit through error().
local function refuse(msg)
  io.stderr:write("archive-plan-packets: " .. msg .. "\n")
  error("archive-plan-packets: refused", 0)
end

if not plan_bin or plan_bin == "" then
  refuse("no --plan-bin given. The archiver decides closure from the FOLD, so it needs the resolved plan binary (scripts/plan-binary-probe.sh); it will not guess a target/ path.")
end

-- Every line WITH its terminator, the same shape io.lines("L") gave.
local function lines_keep(content)
  local out = {}
  for line in content:gmatch("[^\n]*\n") do
    out[#out + 1] = line
  end
  local tail = content:match("[^\n]*$")
  if tail and tail ~= "" then
    out[#out + 1] = tail
  end
  return out
end

local function plan(args)
  local argv = {plan_bin}
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  return proc.run{argv = argv, timeout_ms = 300000}
end

local function main()
  fs.mkdir(archive_dir)

  local TERMINAL_STATUSES = {"completed", "done"}
  local terminal_ids = {}
  local id_aliases = {}

  for _, st in ipairs(TERMINAL_STATUSES) do
    local r = plan{"--index", index_path, "query", "--status", st, "--limit", "0"}
    if not r.ok then
      refuse(string.format("could not read the fold via %s (--index %s, status %s; %s). REFUSING to fall back to a base-index grep: that is the defect this replaced, and it silently archives reopened rows.", plan_bin, index_path, st, r.status))
    end
    for line in r.stdout:gmatch("[^\r\n]+") do
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

  local all = plan{"--index", index_path, "query", "--limit", "0"}
  if not all.ok or all.stdout:match("%S") == nil then
    refuse(string.format("the fold reports NO PACKETS AT ALL for %s. That is an unreadable ledger, not an empty one — refusing rather than archiving nothing and reporting success.", index_path))
  end

  if next(terminal_ids) == nil then
    print("Archived 0 packets (no terminal rows remain — already archived).")
    return
  end

  -- A row still addressed by a live fragment is not archivable. An ABSENT
  -- fragments directory means no fragments; an unreadable one raises in
  -- fs.list rather than reading as empty (the old `ls ... 2>/dev/null` could
  -- not tell those apart).
  local idx_dir = index_path:match("^(.*)/[^/]+$")
  local fragments_dir = idx_dir and (idx_dir .. "/index.d") or "plan/index.d"
  local names = fs.list(fragments_dir)
  local addressed_ids = {}
  for _, name in ipairs(names) do
    if name:match("%.yaml$") then
      local frag = fragments_dir .. "/" .. name
      local r = plan{"fragment-event-packets", frag}
      if not r.ok then
        refuse(string.format("could not read %s — treating every terminal packet as addressed by it is not possible, so REFUSING the sweep rather than archiving rows whose events this fragment may still address.", frag))
      end
      for line in r.stdout:gmatch("[^\r\n]+") do
        local k = line:match("^%s*(.-)%s*$")
        if k and k ~= "" then addressed_ids[k] = true end
      end
    end
  end

  -- Reject by EVERY name of an addressed packet.
  for name, _ in pairs(addressed_ids) do
    if id_aliases[name] then
      for _, alias_name in ipairs(id_aliases[name]) do
        terminal_ids[alias_name] = nil
      end
    end
    terminal_ids[name] = nil
  end

  local function packet_in_archive(content, id)
    if not id then return false end
    for l in content:gmatch("[^\r\n]+") do
      local k, v = l:match("^    %- ([%w_]+):%s*(.-)%s*$")
      if (k == "packet_id" or k == "id" or k == "order") and v then
        local clean_v = v:gsub('^"(.-)"$', '%1'):gsub("^'(.-)'$", "%1"):match("^%s*(.-)%s*$")
        if clean_v == id then return true end
      end
    end
    return false
  end

  -- Archive files are built in memory, one read each, and written once at the
  -- end. The duplicate check sees packets appended earlier in THIS run, as
  -- the old re-read of the file did.
  local archives = {}
  local archive_order = {}
  local function archive_content(path)
    if archives[path] == nil then
      if fs.exists(path) then
        archives[path] = fs.read(path)
      else
        archives[path] = "plan_index:\n  steps:\n"
      end
      archive_order[#archive_order + 1] = path
    end
    return archives[path]
  end

  local function flush_packet(lines, closed, date, id, active_lines)
    if #lines == 0 then return 0 end
    if closed then
      local path = string.format("%s/packets-%s.yaml", archive_dir, date)
      local content = archive_content(path)
      if not packet_in_archive(content, id) then
        archives[path] = content .. table.concat(lines)
        return 1
      end
      return 0
    end
    for _, l in ipairs(lines) do
      table.insert(active_lines, l)
    end
    return 0
  end

  if not fs.exists(index_path) then
    refuse("cannot open " .. index_path)
  end
  local index_lines = lines_keep(fs.read(index_path))

  local active_lines = {}
  local current_packet_lines = {}
  local in_packet = false
  local closed = false
  local packet_date = "2026-05"
  local packet_id = nil
  local archived_count = 0

  for _, line in ipairs(index_lines) do
    local key, raw_id = line:match("^    %- ([%w_]+):%s*(.-)%s*[\r\n]*$")
    if (key == "packet_id" or key == "id" or key == "order") and raw_id then
      archived_count = archived_count + flush_packet(current_packet_lines, closed, packet_date, packet_id, active_lines)
      in_packet = true
      current_packet_lines = {line}
      packet_date = "2026-05"
      packet_id = raw_id:gsub('^"(.-)"$', '%1'):gsub("^'(.-)'$", "%1"):match("^%s*(.-)%s*$")
      closed = (terminal_ids[packet_id] == true)
    elseif in_packet then
      if closed then
        local ts_m = line:match("^[ \t]*ts:%s*\"?(%d%d%d%d%-%d%d)")
        if ts_m then packet_date = ts_m end
      end
      if line:match("^[a-zA-Z]") and not line:match("^ ") then
        archived_count = archived_count + flush_packet(current_packet_lines, closed, packet_date, packet_id, active_lines)
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
  archived_count = archived_count + flush_packet(current_packet_lines, closed, packet_date, packet_id, active_lines)

  -- Archives FIRST, then the index: a failure between the two can duplicate
  -- a packet into the archive but never loses one (fs.write is atomic per file).
  for _, path in ipairs(archive_order) do
    fs.write(path, archives[path])
  end
  fs.write(index_path, table.concat(active_lines))

  print(string.format("Archived %d packets.", archived_count))
end

main()
