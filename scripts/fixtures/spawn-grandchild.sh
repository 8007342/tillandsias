#!/usr/bin/env bash
# @trace order:1384-aixy
# Fixture for proc.run's group-kill arm (design 4.1, row 1384-aixy arm 3).
# Starts a BACKGROUND grandchild that creates "$1" about two seconds later,
# then sleeps far past any test deadline. A deadline that kills only this
# script leaves the grandchild running, and the marker appears; a group kill
# (killpg on Unix, a job object on Windows) takes the grandchild too.
marker="$1"
( sleep 2; : >"$marker" ) &
sleep 30
