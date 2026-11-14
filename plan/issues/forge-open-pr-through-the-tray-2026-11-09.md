# A forge-side "open PR" path through the tray (order 2065-ccx9)

Filed 2026-11-09 from the demon_attack forge session (demon-attack-3e),
relayed by macuahuitl-fedora.

## Context

The session had no `gh` auth. That is by design: forges are credential-free,
and this packet does NOT ask for a GitHub token in the forge.

## Ask

Give the forge a way to ask the tray to open a pull request for a branch the
forge has pushed through the git mirror: head ref, base, title and body.
The tray uses the operator's credential host-side, and the forge gets back
the PR URL or a refusal. The operator should see what is being opened,
through the tray's approval surface, before it is created.

## Closure

From a forge, an agent opens a draft PR for a pushed work ref without any
credential in the forge, and the request appears in the tray first.
