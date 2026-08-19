#!/usr/bin/env ruby
require 'fileutils'
require 'yaml'

index_path = 'plan/index.yaml'
archive_dir = 'plan/archive'
FileUtils.mkdir_p(archive_dir)

# ORDER 831-ezea / R2'. CLOSURE IS DECIDED BY THE FOLD, NOT BY GREPPING THE BASE.
#
# This script used to set `closed = true` on any line matching
# /^[ \t]*status: (completed|done|obsoleted)/ in plan/index.yaml. Two defects,
# both measured on 2026-08-19 by dry-running it against a copy:
#
#  1. IT NEVER READ plan/index.d AT ALL (`grep -cE 'index\.d|fragment'` -> 0),
#     but status is an LWW register over base PLUS fragments. A packet closed in
#     the base and later REOPENED by a fragment reads terminal here and ready to
#     everything else. The dry run archived 543 packets and SILENTLY REMOVED TWO
#     READY ROWS — 424 (git-mirror-credential-lifecycle) and 437
#     (forge-src-tmpfs-topology) — which answered `no packet matches` afterwards.
#  2. A line grep cannot tell a packet's OWN status from one nested inside an
#     event. That is the 752-pst5 class this project already fixed elsewhere by
#     parsing instead of grepping.
#
# `--check` did not catch either: it runs the archiver twice and diffs, which
# proves IDEMPOTENCY only. An archiver that deterministically archives the WRONG
# rows is perfectly idempotent, and the script's freshness header cited --check
# as evidence of soundness.
#
# The fold is not reimplemented here — it is ASKED. Reimplementing an invariant
# a sibling already owns is how four drifts landed in orchestrate-enclave.sh
# this week. `--index` is passed explicitly so --check's `plan/` -> `plan_tmp/`
# rewrite redirects the query at the copy along with everything else.
plan_bin = ENV['TILLANDSIAS_PLAN_BIN'] || 'target/release/tillandsias-plan'
TERMINAL_STATUSES = %w[completed done obsoleted].freeze
terminal_ids = {}
TERMINAL_STATUSES.each do |st|
  # `--limit 0` IS LOad-BEARING, not a default-restating flourish. `query`
  # defaults to a limit of TWENTY and says nothing when it truncates, so the
  # first version of this fix built a 48-row terminal set out of a 1127-packet
  # ledger and archived 48 packets while reporting success. `--limit 0` is
  # unlimited (564 completed alone). See the 831-ezea event filed with this
  # change: an enumerating caller that omits the flag gets a silently partial
  # answer, which is the 796-4ydb class in the reader the whole fold rests on.
  out = `#{plan_bin} --index #{index_path} query --status #{st} --limit 0 2>/dev/null`
  unless $?.success?
    abort "archive-plan-packets: could not read the fold via #{plan_bin} " \
          "(--index #{index_path}, status #{st}). REFUSING to fall back to a " \
          "base-index grep: that is the defect this replaced, and it silently " \
          "archives reopened rows."
  end
  # Column 1 is the order, column 2 the packet_id. Rows in the base index are
  # keyed by EITHER (`- packet_id:` or `- id:`), so accept both as lookup keys.
  out.each_line do |l|
    cols = l.split("\t")
    [cols[0], cols[1]].each do |k|
      k = k.to_s.strip
      terminal_ids[k] = true unless k.empty?
    end
  end
end
abort "archive-plan-packets: the fold reported ZERO terminal packets, which is " \
      "not a state this ledger reaches. Refusing rather than archiving nothing " \
      "and reporting success." if terminal_ids.empty?

# THE ROW HEADER. `order` is in this alternation because 19 of the 1031 base
# rows lead with `- order:` rather than `- packet_id:` — YAML mapping keys are
# unordered and nothing ever required a particular first key. A header regex
# that misses a row does not skip the row: the row has no header, so its lines
# are ABSORBED into the PRECEDING packet's block and share that packet's fate.
# That is how 424 (git-mirror-credential-lifecycle) and 437
# (forge-src-tmpfs-topology) — both `ready`, both `- order:`-led — were carried
# into the archive by their terminal predecessors (424's is
# macos-curl-installer-gatekeeper-overwarn at :20305).
#
# This, NOT the missing fragment read, is the actual cause of the two lost ready
# rows. The 2026-08-19 note on this packet asserted the fragment cause from a
# correct observation (`grep -cE 'index\.d|fragment'` -> 0) without testing that
# it produced the symptom; fixing the fold read alone left BOTH rows still
# vanishing. 797-5kqe, in the cycle that filed 797-5kqe's sibling.
ROW_HEADER = /^    - (packet_id|id|order): /.freeze

lines = File.readlines(index_path)
active_lines = []
current_packet_lines = []
in_packet = false
closed = false
packet_date = "2026-05" # Default
packet_id = nil
archived_count = 0

def flush_packet(lines, closed, date, id, active_lines, archive_dir)
  return 0 if lines.empty?
  if closed
    archive_file = File.join(archive_dir, "packets-#{date}.yaml")
    unless File.exist?(archive_file)
      File.write(archive_file, "plan_index:\n  steps:\n")
    end
    
    existing_content = File.read(archive_file)
    id_regex = /^    - (packet_id|id|order): #{Regexp.escape(id)}$/
    unless existing_content.match?(id_regex)
      File.open(archive_file, 'a') do |f|
        f.puts lines.join("")
      end
      return 1
    end
    return 0
  else
    active_lines.concat(lines)
    return 0
  end
end

lines.each do |line|
  if line.match?(ROW_HEADER)
    # Flush previous packet
    archived_count += flush_packet(current_packet_lines, closed, packet_date, packet_id, active_lines, archive_dir)
    
    # Start new packet
    in_packet = true
    current_packet_lines = [line]
    closed = false
    packet_date = "2026-05"
    packet_id = line.strip.split(': ')[1].strip.gsub('"', '')
    # THE DECISION, moved from a mid-packet line grep to a fold lookup at the
    # packet header. Whether this row is terminal is now answered by the same
    # LWW resolution every other reader uses, so a base-closed row REOPENED by
    # a fragment stays put instead of being archived out of `ready`.
    closed = terminal_ids.key?(packet_id)
  elsif in_packet
    if closed
      m = line.match(/^[ \t]*ts: "?(\d{4}-\d{2})/)
      if m
        packet_date = m[1]
      end
    end
    
    if line.match?(/^[a-zA-Z]/) && !line.start_with?(' ')
      archived_count += flush_packet(current_packet_lines, closed, packet_date, packet_id, active_lines, archive_dir)
      in_packet = false
      current_packet_lines = []
      active_lines << line
    else
      current_packet_lines << line
    end
  else
    active_lines << line
  end
end

archived_count += flush_packet(current_packet_lines, closed, packet_date, packet_id, active_lines, archive_dir)

File.write(index_path, active_lines.join(""))
puts "Archived #{archived_count} packets."
