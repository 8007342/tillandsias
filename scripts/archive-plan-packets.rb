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
# `obsoleted` IS DELIBERATELY ABSENT (Tlatoāni ruling, 2026-08-19). It is a
# terminal status, so archiving it is defensible on its face — and it is exactly
# wrong under the convergence model.
#
# Retraction (`set-field <id> status obsoleted`) is the channel that drains the
# READY queue, and the whole argument for retracting aggressively is that
# NOTHING IS LOST: the row stays, its events stay, and the recorded reason for
# rejecting it is what stops a later agent re-proposing the same idea. Archiving
# makes a row answer `no packet matches`. So archiving retracted rows deletes
# precisely the memory that makes retraction safe, in precisely the population
# retraction produces.
#
# Today the exemption is nearly free: 8 obsoleted against 564 completed. It does
# NOT scale as written — once retraction is the primary drain (~182/week), these
# rows accumulate in the base index forever and re-create the growth problem
# they were meant to solve. The follow-on is a TOMBSTONE form: archive a
# retracted row's event history but keep a compact row carrying id, title, and
# the retraction reason, so it stays queryable at ~5 lines instead of ~80. That
# must land BEFORE the first large retraction wave, not after.
TERMINAL_STATUSES = %w[completed done].freeze
terminal_ids = {}
# order <-> packet_id, both directions. A row's HEADER may be keyed by either
# (19 of the base rows lead with `- order:`), so any set operation on ids has to
# act on BOTH names for one packet or it is silently half-applied. That
# asymmetry is the original 424/437 bug wearing a different hat, and it bit
# again on 2026-08-22: the addressed-fragment exclusion below rejected the
# packet_id and left the order key behind, so a row whose header is `- order:`
# was archived despite a live fragment addressing it, and the orphan invariant
# caught it one gate later.
id_aliases = Hash.new { |h, k| h[k] = [] }
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
    names = [cols[0], cols[1]].map { |k| k.to_s.strip }.reject(&:empty?)
    names.each do |k|
      terminal_ids[k] = true
      # Every name of a packet aliases every other name of it, so a later
      # rejection by ANY name removes ALL of them.
      id_aliases[k] = names
    end
  end
end
# REFUSE A BROKEN READ, NOT AN ALREADY-ARCHIVED LEDGER.
#
# The first version of this guard aborted whenever the terminal set was empty,
# on the premise that "zero terminal packets is not a state this ledger
# reaches". That premise is FALSE, and the check that exercises this script
# proves it: --check runs the archiver TWICE against one copy, and after the
# first run every terminal row has moved to plan_tmp/archive — so the second
# run legitimately sees zero. Measured 2026-08-21 on a copy: run 1 archived 661
# packets, after which the copy reported completed=0 done=0 with 510 packets
# still live, and run 2 aborted. A guard that fires on the correct steady state
# is not a guard, it is an outage.
#
# The condition actually worth refusing is a fold that returns NOTHING AT ALL —
# a wrong --index, an unreadable base, a binary that answers but cannot parse.
# Zero terminal against a non-empty ledger means the work is done.
all_ids = `#{plan_bin} --index #{index_path} query --limit 0 2>/dev/null`
abort "archive-plan-packets: the fold reports NO PACKETS AT ALL for " \
      "#{index_path}. That is an unreadable ledger, not an empty one — refusing " \
      "rather than archiving nothing and reporting success." unless $?.success? && all_ids.lines.any? { |l| !l.strip.empty? }

if terminal_ids.empty?
  puts "Archived 0 packets (no terminal rows remain — already archived)."
  exit 0
end

# A ROW STILL ADDRESSED BY A LIVE FRAGMENT IS NOT ARCHIVABLE.
#
# Found the hard way: the first real sweep archived 569 packets and immediately
# turned check-fragment-status-loss.sh red with 38 violations, each reading
# "an events block addresses it but NO SUCH PACKET is in the fold ... that event
# was discarded". Archiving a row does not just make the ROW unqueryable — it
# ORPHANS every plan/index.d event still aimed at it, and the fold then drops
# those events silently. The files stay in git and vanish from every answer.
#
# That is a worse loss than the row itself, and it cannot be fixed by relocating
# the events: fragments are append-only and immutable once written.
#
# So the archivable set is TERMINAL MINUS ADDRESSED. It costs a little of the
# sweep (38 rows of 569) and keeps the append-only substrate honest, which is
# the whole point of the CRDT.
fragments_dir = File.join(File.dirname(index_path), 'index.d')
addressed_ids = {}
Dir.glob(File.join(fragments_dir, '*.yaml')).sort.each do |frag|
  out = `#{plan_bin} fragment-event-packets #{frag} 2>/dev/null`
  # exit 3 is an unparseable fragment; 796-4ydb says name it and keep going
  # rather than refusing the fleet, but do NOT treat it as "addresses nothing".
  unless $?.success?
    warn "archive-plan-packets: could not read #{frag} — treating every terminal " \
         "packet as addressed by it is not possible, so REFUSING the sweep rather " \
         "than archiving rows whose events this fragment may still address."
    exit 1
  end
  out.each_line { |l| k = l.strip; addressed_ids[k] = true unless k.empty? }
end
# Reject by EVERY name of an addressed packet, not just the name the fragment
# happened to use. A fragment addresses packets by packet_id; a base row may be
# headed by `- order:`. Rejecting only the packet_id leaves the order key in the
# terminal set, the header lookup hits it, and the row is archived out from
# under the very fragment that addresses it.
addressed_ids.keys.each do |name|
  id_aliases[name].each { |alias_name| terminal_ids.delete(alias_name) }
  terminal_ids.delete(name)
end

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
