# Proposal — a forge with nothing to do pushes, exits, and is woken later

@trace order:2014-slpw

## Why

Operator, 2026-11-06: a forge facing a long wait should commit and push, exit
gracefully and shut down, and the tray should wake it later, idempotently, in
a resumed or a fresh session. Holding a long call wastes a running container
and breaks on harness call limits.

## What changes

Design only, for operator review (`design.md`): session names and the
command lines per harness, the boundary between blocking in 2011-amqd's
`what_next` and exiting, the shutdown-and-wake sequence, routing a message
when several forges share a project, and the tests. Nothing is built.
