#!/usr/bin/env bash
# @trace order:1384-aixy
# Fixture for proc.run's two-fd arm (row 1384-aixy arm 2): writes exactly
# 1 MiB to stdout AND 1 MiB to stderr. A runner that drains one fd before the
# other deadlocks on the pipe buffer; proc.run must return both in full.
head -c 1048576 /dev/zero
head -c 1048576 /dev/zero >&2
