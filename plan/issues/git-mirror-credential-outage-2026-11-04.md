# Git mirror credential outage, macuahuitl, 2026-11-04/05

Reported by the kumbia-kombat forge. Times are UTC.

## What happened

- ~23:40 last good push from the forge.
- 23:55:56 first `upstream-auth:denied` in the mirror log, repeating every two minutes. GitHub refused the mirror's token (`reason=unauthenticated`). Nothing surfaced it: the operator and the forge learned about it only when a push failed at 04:58, five hours later.
- The host's own `gh` login could still read the repository, so the account was fine.
- ~04:59 the operator ran `tillandsias --github-login`. tillandsias-vault restarted at 04:59:39.
- 05:0x the mirror's verdict changed to `upstream-auth:agent-unauthenticated`: "the mirror's Vault client token is expired or rejected (lookup-self failed); the Agent cannot re-authenticate". Pushes stayed refused after the login. The mirror's Vault Agent had started at 18:40, before the Vault restart. Vault logged repeated `tls: bad record MAC` from the mirror's address.
- 05:03:56 the coordinator ran `podman restart tillandsias-git-kumbia-kombat`, on the operator's instruction to reload it. The Agent re-authenticated at once and the verdict became `upstream-auth:authorized`. The forge's next push landed 8b0fcc6.

The forge saw this as clearing by itself after about three minutes. It did not: the restart cleared it.

## What is established and what is not

- Established: the mirror did not recover from the Vault restart until it was restarted, and restarting it was enough.
- Inferred from timing only: that `--github-login` caused the Vault restart.
- Unknown: why GitHub began refusing the token at 23:55:56. A token lifetime is one lead, unchecked.
- Unknown: the cause of `tls: bad record MAC`. One such line appears around the restart too, so it may not be the fault.
- Not checked: whether a plain restart is enough on every host, or whether other mirrors were affected. Only this mirror was running here.

## Manual recovery

`podman restart tillandsias-git-<project>`, then look for `upstream-auth:authorized` in its log. Run `tillandsias --github-login` only for a `denied` or `no-credential` verdict, not for `agent-unauthenticated`.

## Durable fixes

Rows 1998-mvrs, 1998-gtkx and 1998-mcsd.
