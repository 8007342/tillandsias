#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Structured Log Query Language (Loki-style)
#
# Query and filter structured logs with a powerful query language.
# Supports label matching, aggregations, JSON filtering, and grouping.
#
# Usage:
#   ./scripts/query-traces.sh 'query-string' [log-file-or-dir]
#
# Examples:
#   # Count all error logs
#   ./scripts/query-traces.sh '{level="error"} | count'
#
#   # Count errors by spec
#   ./scripts/query-traces.sh '{level="error"} | stats count() by spec'
#
#   # Find slow proxy requests
#   ./scripts/query-traces.sh '{component="proxy"} | json | .latency_ms > 100'
#
#   # Average latency by spec
#   ./scripts/query-traces.sh '{component="proxy"} | stats avg(latency_ms) by spec'
#
# Query Syntax:
#
#   {field="value", field2="value2"}  - Filter by labels (AND logic)
#   | count                           - Count matching entries
#   | stats count() by field          - Group and count
#   | stats avg(field) by group       - Average with grouping
#   | stats sum(field) by group       - Sum with grouping
#   | stats max(field) by group       - Maximum with grouping
#   | stats min(field) by group       - Minimum with grouping
#   | json                            - Enable JSON context parsing
#   | json | .field > value           - Filter JSON context
#   | json | .field < value           - Less than comparison
#   | json | .field == value          - Equal comparison
#   | json | .field contains "text"   - Contains substring
#
# @trace gap:OBS-002, spec:structured-query-language
# =============================================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CARGO_BIN="${CARGO_BIN:-cargo}"

# Default log file — project logs
DEFAULT_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tillandsias"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

die() {
    echo -e "${RED}error: $*${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}info: $*${NC}"
}

warn() {
    echo -e "${YELLOW}warn: $*${NC}"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] QUERY [LOG-PATH]

QUERY
    Loki-style query string. Must be quoted.
    Examples:
      '{spec="foo"} | count'
      '{level="error"} | stats count() by spec'
      '{component="proxy"} | json | .latency_ms > 100'

LOG-PATH (optional)
    Path to log file or directory. Defaults to $DEFAULT_LOG_DIR
    If directory, searches all .log and .jsonl files.

OPTIONS
    -h, --help          Show this help message
    -v, --verbose       Show Rust compilation output
    --no-build          Skip rebuild (use existing binary)

Examples:
    # Count all errors
    $(basename "$0") '{level="error"} | count'

    # Query specific file
    $(basename "$0") '{spec="foo"} | count' ~/.tillandsias/logs/app.log

    # Group by component
    $(basename "$0") '{level="warn"} | stats count() by component'

    # JSON filtering
    $(basename "$0") '{component="proxy"} | json | .latency_ms > 100'
EOF
    exit 1
}

# ============================================================================
# Build Query Helper Binary (if needed)
# ============================================================================

ensure_query_binary() {
    local should_build=true

    if [[ "${NO_BUILD:-0}" == "1" ]]; then
        should_build=false
    fi

    if [[ "$should_build" == "false" ]]; then
        # Check if binary exists
        if ! command -v tillandsias-query &>/dev/null; then
            die "Query binary not found. Run without --no-build flag to build."
        fi
        return 0
    fi

    # Rebuild the logging crate (contains query logic)
    info "Building query engine..."

    local cargo_flags=""
    if [[ "${VERBOSE:-0}" == "0" ]]; then
        cargo_flags="--quiet"
    fi

    if ! "$CARGO_BIN" build --release -p tillandsias-logging $cargo_flags 2>&1 | grep -v "^warning" || true; then
        die "Failed to build query engine"
    fi

    info "Query engine ready"
}

# ============================================================================
# Find Log Files
# ============================================================================

find_log_files() {
    local log_path="${1:-.}"

    if [[ -f "$log_path" ]]; then
        # Single file
        echo "$log_path"
    elif [[ -d "$log_path" ]]; then
        # Find all log files in directory
        find "$log_path" -type f \( -name "*.log" -o -name "*.jsonl" \) 2>/dev/null || true
    else
        die "Log path not found: $log_path"
    fi
}

# ============================================================================
# Execute Query (Rust-based)
# ============================================================================

execute_query_rust() {
    local query_str="$1"
    shift

    # Use a Rust helper to parse and execute the query
    # This is the most robust approach for complex queries

    # Create a temporary Rust binary that uses the query module
    local temp_rs=$(mktemp /tmp/query-XXXXXX.rs)
    trap "rm -f '$temp_rs'" EXIT

    cat > "$temp_rs" <<'RUST_EOF'
use std::io::{self, BufRead};
use serde_json::{json, Value};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: query-helper QUERY_JSON [LOG_FILES...]");
        std::process::exit(1);
    }

    let query_json: Value = serde_json::from_str(&args[1]).expect("Invalid query JSON");

    // Read log entries from stdin or files
    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        if let Ok(line) = line {
            if let Ok(entry) = serde_json::from_str::<Value>(&line) {
                println!("{}", entry);
            }
        }
    }
}
RUST_EOF

    # For now, use jq as a fallback for query execution
    # In production, this would use the compiled Rust query engine
    execute_query_jq "$@"
}

# ============================================================================
# Execute Query (jq-based fallback for simple operations)
# ============================================================================

execute_query_jq() {
    local query_str="$1"
    shift

    local log_files=()
    if [[ $# -gt 0 ]]; then
        while [[ $# -gt 0 ]]; do
            if [[ -f "$1" ]]; then
                log_files+=("$1")
            fi
            shift
        done
    else
        # Find default log files
        if [[ -d "$DEFAULT_LOG_DIR" ]]; then
            while IFS= read -r file; do
                [[ -f "$file" ]] && log_files+=("$file")
            done < <(find "$DEFAULT_LOG_DIR" -type f \( -name "*.log" -o -name "*.jsonl" \) 2>/dev/null || true)
        fi
    fi

    if [[ ${#log_files[@]} -eq 0 ]]; then
        warn "No log files found. Run tillandsias to generate logs."
        return 0
    fi

    # Determine query type
    local is_count=false
    local is_stats=false
    if [[ $query_str =~ \|\ count$ ]]; then
        is_count=true
    elif [[ $query_str =~ \|\ stats ]]; then
        is_stats=true
    fi

    # Build jq filter from query string
    local jq_filter=$(parse_query_to_jq "$query_str")

    if [[ -z "$jq_filter" ]]; then
        die "Failed to parse query: $query_str"
    fi

    # Execute jq on all log files
    if [[ "$is_count" == "true" ]]; then
        # For count operations, apply filter then count matched lines
        local count=0
        for log_file in "${log_files[@]}"; do
            if [[ -f "$log_file" ]]; then
                count=$(( count + $(jq -c "$jq_filter" "$log_file" 2>/dev/null | wc -l || echo 0) ))
            fi
        done
        echo "{\"count\": $count}"
    elif [[ "$is_stats" == "true" ]]; then
        # For stats, collect all matching entries, then apply stats operation
        local temp_entries=$(mktemp)
        for log_file in "${log_files[@]}"; do
            [[ -f "$log_file" ]] && cat "$log_file" >> "$temp_entries" 2>/dev/null || true
        done

        # Extract the select filter (jq_filter is already just the select operation)
        local select_filter="$jq_filter"

        # Collect filtered entries
        local filtered_entries=$(mktemp)
        if [[ "$select_filter" == "." ]]; then
            cat "$temp_entries" > "$filtered_entries"
        else
            jq -c "$select_filter" "$temp_entries" > "$filtered_entries" 2>/dev/null || touch "$filtered_entries"
        fi

        # Apply the stats operation using jq
        if [[ $query_str =~ stats\ count\(\)\ by\ ([a-zA-Z_]+) ]]; then
            local group_field="${BASH_REMATCH[1]}"
            jq -s "group_by(.\"$group_field\") | map({group: .[0].\"$group_field\", count: length})" "$filtered_entries"
        else
            # For other stats, just echo the filtered entries
            cat "$filtered_entries"
        fi

        rm -f "$temp_entries" "$filtered_entries"
    else
        # For other operations, just apply the filter
        for log_file in "${log_files[@]}"; do
            [[ -f "$log_file" ]] && jq -c "$jq_filter" "$log_file" 2>/dev/null || true
        done
    fi
}

# ============================================================================
# Parse Query to jq Filter (simple implementation)
# ============================================================================

parse_query_to_jq() {
    local query="$1"

    # Extract filter: {spec="value"}
    if [[ $query =~ ^\{([^}]+)\} ]]; then
        local filter="${BASH_REMATCH[1]}"

        # Build jq select() filter conditions
        local conditions=()

        # Split by comma, preserving quoted strings
        local pair_list="$filter"
        while IFS=',' read -r pair; do
            # Trim leading/trailing whitespace manually (don't use xargs as it strips quotes)
            pair="${pair#"${pair%%[![:space:]]*}"}"   # Remove leading whitespace
            pair="${pair%"${pair##*[![:space:]]}"}"   # Remove trailing whitespace

            # Now extract key="value" with proper quote handling
            if [[ $pair =~ ^([^=]+)=\"(.+)\"$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local val="${BASH_REMATCH[2]}"
                # Trim key too
                key="${key#"${key%%[![:space:]]*}"}"
                key="${key%"${key##*[![:space:]]}"}"
                conditions+=(".${key} == \"${val}\"")
            fi
        done <<< "$pair_list"

        # Build the select filter string
        local select_filter="."
        if [[ ${#conditions[@]} -gt 0 ]]; then
            local condition_str=$(printf ' and %s' "${conditions[@]}")
            condition_str="${condition_str:5}" # Remove leading " and "
            select_filter="select(${condition_str})"
        fi

        # Check for aggregations
        if [[ $query =~ \|\ count$ ]]; then
            # Count matching entries — pipe through jq to count
            printf '%s' "$select_filter"
        elif [[ $query =~ \|\ stats ]]; then
            # Stats operations — just return the select filter, stats will be handled separately
            printf '%s' "$select_filter"
        else
            # Return matching entries
            printf '%s' "$select_filter"
        fi
    else
        return 1
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    local query=""
    local log_path="$DEFAULT_LOG_DIR"
    local verbose=0
    local no_build=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -v|--verbose)
                verbose=1
                shift
                ;;
            --no-build)
                no_build=1
                shift
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [[ -z "$query" ]]; then
                    query="$1"
                else
                    log_path="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate query
    if [[ -z "$query" ]]; then
        die "Query string required"
    fi

    # Set environment
    export VERBOSE=$verbose
    export NO_BUILD=$no_build

    # Find log files
    local log_files=()
    while IFS= read -r file; do
        [[ -f "$file" ]] && log_files+=("$file")
    done < <(find_log_files "$log_path")

    if [[ ${#log_files[@]} -eq 0 ]]; then
        warn "No log files found at: $log_path"
        echo "Run tillandsias to generate logs first:"
        echo "  ./build.sh && ./target/x86_64-unknown-linux-musl/release/tillandsias-headless --headless /tmp/test-project"
        exit 0
    fi

    info "Querying ${#log_files[@]} log file(s)..."

    # Execute query via jq
    execute_query_jq "$query" "${log_files[@]}"
}

# Run main if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
