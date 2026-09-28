#!/bin/sh
# Fixture for lua_predicate_classes.rs (a_timed_out_shell_call_is_distinguishable_in_lua):
# a child that ignores SIGTERM, so a timeout has to escalate. Passed to `sh` as a
# FILE, which is argv; `sh -c <string>` is refused by the command policy (1443-isrk).
trap '' TERM
sleep 60
