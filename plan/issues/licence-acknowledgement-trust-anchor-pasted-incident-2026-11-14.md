# INCIDENT 2026-11-14: a consent gate's trust anchor arrived by clipboard paste

Packet: 2083-nfne (p0). Linked: 2022-ygqj, 2022-89hm, 2022-hn2k.
Carried: .claude/skills/accept-licence/SKILL.md.

Operator: "THAT'S EXTREMELY FUCKED UP!!! ... this is the stupidest weakest most
terrible way in which Tillandsias has ever handled a credential."

## What happened (Demucs acknowledgement for demon_attack, signed on the Mac)

1. The tray never showed the licence clauses. The operator saw them only as a
   chat paraphrase, and the statement was typed into the Mac by a heredoc.
2. The accept-licence skill told forge agents `ssh-keygen -Y sign -f <key>`.
   The real path is `tillandsias-tray --approval-enrol/--approval-sign`, and
   nothing forge-side documents that.
3. The enrol line and the SSHSIG went to stdout only: no MCP result, no drop
   directory.
4. The approval key's PUBLIC key and the SSHSIG travelled through the macOS
   clipboard and a pasted chat message into a Claude transcript. No private
   key left the Secure Enclave, but the trust anchor of a consent gate arrived
   over an unauthenticated channel, and the forge verified the signature
   against a public key delivered by the same paste.
5. Touch ID was not the end of the flow; pasting came after it.
6. The coordinator sent "stop" after the operator had already signed, then
   "finish": mixed signals at the worst moment.

## Impact

No private key was exposed. The record's value (a signature verifiable against
a host-attested key) was not established: signature and key shared one
channel, so the verification proved nothing about who held the key.

## Root causes

- A gate that accepts allowed_signers lines from any writer (paste, agent).
- No MCP tool, so the only path was manual.
- Skill text that described a path that does not exist and invited a manual one.
- Tray never displayed the clauses it was supposedly gating.

## Remedy (packets)

- 2083-nfne: allowed_signers writable only by the host enrol path; skill can
  never instruct a manual flow; this post-mortem.
- 2022-ygqj, 2022-89hm, 2022-hn2k: the one-utterance, one-window, one-touch
  tool and cross-host propagation.

## Open questions

- Should the existing Mac-enrolled slug key in this host's allowed_signers be
  treated as unattested and re-enrolled through the new path? (2083-nfne
  decides; default yes for any line without host-enrol provenance.)
- Process: a stop/finish instruction after an irreversible operator action
  must be checked against status first, not issued blind.
