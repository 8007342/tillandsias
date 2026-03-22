#!/usr/bin/env bash
# Dev helper: run a container directly for testing
# Usage: ./run-tillandsia.sh [path] [--image forge|web] [--debug]
exec cargo run --manifest-path src-tauri/Cargo.toml -- "$@"
