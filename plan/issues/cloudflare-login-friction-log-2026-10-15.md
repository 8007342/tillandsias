# Cloudflare login: friction log

Orders 1718-adra (login inputs), 1719-83po (tray item), 1719-7wd9 (device
grant). The operator, 2026-10-14: "let's do the awkward one time flow in the
mac, and see if we can simplify it later for our end users. We don't want n00b
users awkwradly copying and pasteing random weird bytes. We want to make it
frictionless for them."

Purpose: each awkward step the operator hits, in their words where possible,
with what Tillandsias should do so an end user never meets it. Append-only:
one dated entry per step, then a "for users" line.

## 2026-10-14: registering the Tillandsias OAuth client (operator only)

Context: a read-only PKCE probe (1707-g633 U1), not the Tillandsias login
itself. End users will never register a client; Tillandsias ships one.

1. **Finding where to register.** Manage Account → OAuth clients → Create
   client. The operator saw no Visibility setting and assumed Private is the
   default. *For users:* never shown. Tillandsias ships the client, which must
   go Public (logo, client URL, DNS TXT verification, irreversible) before
   anyone outside the operator's account can sign in.
2. **Permission names vs scope ids.** The dashboard lists friendly names
   ("Workers CI Write", "Workers Metadata Read-Only"), and the authorize URL
   needs ids (`workers-ci.write`, `workers-scripts.metadata_read`). Several
   names the operator looked for didn't exist as such ("Workers Scripts" read
   wasn't offered under that tab). Six probe runs were spent guessing ids
   (`workers_builds:write`, `account:read`, `workers.read` were all refused by
   name) until `GET /client/v4/oauth/scopes` listed the 397 ids. *For users:*
   never shown. The ids are compiled in (1718).
3. **"0 total permissions", Authorize disabled.** With no scope requested,
   the consent screen has nothing to approve. Tillandsias shipped exactly that
   until 1718. *For users:* a fixture now forbids an empty scope list.
4. **A consent click per attempt.** Every probe run opened a new consent tab.
   Stale tabs piled up, and the operator clicked Authorize in an older tab,
   which made one run look like it completed without a click. *For users:* one
   consent at login, then silent refresh. Never open more than one tab per
   attempt, and say "you can close this tab" (done in the probe).
5. **"What's with the callbacks in 127.0.0.1? ... That looks fishy."** The
   loopback redirect (RFC 8252 §7.3) is standard and safe, but to a user it
   looks like an attack, and on a Mac it lands on a "can't connect" page
   because the listener is inside the VM. *For users:* the device-code grant
   (1719-7wd9) has no redirect at all. Until then, the terminal must say
   beforehand that the browser will show "can't connect" and that this is
   expected.
6. **SSO first.** Each consent began with the operator's SSO sign-in to
   Cloudflare. Fine for the operator; for users it's one more screen before
   the one that matters.

## To fill in: the operator's first real `--cloudflare-login` (paste mode, macOS)

When 1718 and 1719-83po are released: click **Cloudflare Login** in the tray,
then record each step here. Was the printed link findable? Did the "can't
connect" page confuse? Was copying the address bar obvious? How long did it
take? Then note the first silent token rotation (about an hour later): did it
happen, and what did the tray say?
