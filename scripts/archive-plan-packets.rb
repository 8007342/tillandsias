#!/usr/bin/env ruby
require 'fileutils'
require 'yaml'

index_path = 'plan/index.yaml'
archive_dir = 'plan/archive'
FileUtils.mkdir_p(archive_dir)

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
    id_regex = /^    - (packet_id|id): #{Regexp.escape(id)}$/
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
  if line.match?(/^    - (packet_id|id): /)
    # Flush previous packet
    archived_count += flush_packet(current_packet_lines, closed, packet_date, packet_id, active_lines, archive_dir)
    
    # Start new packet
    in_packet = true
    current_packet_lines = [line]
    closed = false
    packet_date = "2026-05"
    packet_id = line.strip.split(': ')[1].strip.gsub('"', '')
  elsif in_packet
    if line.match?(/^[ \t]*status: (completed|done|obsoleted)/)
      closed = true
    end
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
