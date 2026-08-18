## Cycle 2026-08-17T22:40Z (linux_mutable macuahuitl — day-3, forge-write blocker found)

**Result: the forge-write blocker is a DENIED mirror credential, measured out of
the volume rather than inferred from a symptom. It is p0 and it is the
operator's — filed 809-w2xy.**

Three cycles of directives have asked for a stack "publishing
refs/tillandsias/upstream-auth/authorized" to unblock 559, 741-3y48, 743-y5wh,
749-6uby, 749-8iw4, 749-y8xx and 722-uern. It publishes `denied`:

  refs/tillandsias/upstream-auth/denied/1787006049
  epoch 2026-08-17T22:34:09Z, age 523s, guard bound 900s, one ref in the volume

Fresh, and denied. The probe authenticated a `push --dry-run` advertisement
with the Vault credential and GitHub answered 403 — 756-2jnj's mechanism doing
exactly its job. The remedy is already written in the guard's own message and
nobody has run it: a credential with push rights at secret/github/token.

WHY IT SURVIVED THREE CYCLES AIMED AT IT: this host's push path is healthy.
check-credential-channel answers ok:gh-keyring and every push tonight worked.
The broken credential belongs to the MIRROR, lives in Vault, and is used only
by the enclave — a different principal, invisible from the host.

I did not route around it. The guard says "do NOT import host credentials" and
the enclave holding its own credential is the point, not an obstacle.

THIRD READING OF ONE FACT, two of them mine and wrong:
  1. "the mirror container does not exist"      — inferred from one podman ps
  2. "the verdict is stale while it is up"      — inferred from a failure string
  3. "fresh, 523s, DENIED"                      — READ OUT OF THE VOLUME
What settled it was reading the ref instead of reasoning from a symptom. Also
worth removing: the forge's failure label said `...-auth-stale` while the
guard's vocabulary distinguishes stale from denied, so the string sent me to a
probe loop that is healthy (ticks every 120s against a 900s bound).

Siblings merged (windows +6, osx +9). No forks delegated — the blocker is
operator-owned and the e2e stays parked behind it.
