# `status-proxy` fails on a name collision with the container it just created, classified `retry Permanent`

- Class: research (one occurrence — mechanism not yet established)
- Filed: 2026-08-11, windows host, guest distro `tillandsias`, podman 5.8.4
- Found by: meta-orchestration cycle 2, probing whether a forge lane could be
  launched through the headless path

## Observation

First `tillandsias-headless --status-check` after a fresh reprovision (the same
run was also building the missing chromium-core / chromium-framework / web
images):

```
Error: stage 'status-proxy' failed for container tillandsias-proxy
cause: Container command failed (status Some(125), retry Permanent):
  podman run --detach --replace --name tillandsias-proxy ... localhost/tillandsias-proxy:v0.4.260810.1
stderr: Error: creating container storage: the container name "tillandsias-proxy"
  is already in use by 667f37b087ea...  You have to remove that container to be
  able to reuse that name: that name is already in use, or use --replace ...
container: tillandsias-proxy
state: running
```

Two things stand out:

1. The argv **already carries `--replace`**, and podman's advice is to use
   `--replace`.
2. The report's own `state: running` and the ID in the error are the same
   container — 667f37b087ea, which `podman ps -a` then showed as `Up 14
   seconds`. So the name was taken by a container created moments earlier, and
   the run that reported the collision is the one racing it.

An immediate second `--status-check` printed `status-check completed` with no
error, and the proxy was adopted normally.

## Why it is worth a record

The failure is classified `retry Permanent`, so the stage does not retry.
A transient name/storage collision that cannot self-recover turns a race into a
hard stack-up failure, and the surviving state (a healthy running proxy) looks
identical to the state the stage was trying to reach.

An intermittent failure is a defect with a schedule, not noise — but one
occurrence does not distinguish between:

- the stage sequence starting the proxy twice (provisioning start + status-proxy
  stage racing each other), and
- podman's `--replace` removal releasing the DB entry before storage releases
  the name, so a fast re-run lands inside that window.

Those want different fixes, and guessing between them is how a mis-diagnosis
gets filed (see 637-df4z, closed mis-diagnosed).

## Smallest next action

On the next occurrence, capture `podman ps -a --storage` and the stage ordering
from the same run before anything is retried — that separates the two
candidates. If the race is real and in the sequencing, the fix is to make the
`status-proxy` stage adopt an already-running, correctly-imaged proxy rather
than re-running `podman run`; if it is the replace/storage window, the fix is to
reclassify the "name already in use" stderr as retryable rather than Permanent.

Not promoted to a packet in the filing cycle: with one data point the exit
criterion could only be prose intent, and a packet with no verifiable closure is
worse than a dated finding waiting for its second observation.
