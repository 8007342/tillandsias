# GitHub login prompts for a token, then completes via device flow anyway (648-e5pf)

- Date: 2026-08-10
- Reporter: operator, at the terminal, on the Windows host
- Class: `enhancement/` — wasted operator effort + a credential collected without need
- Status: filed; root mechanism NOT fully determined (see "What is not established")

## Operator report

> "I was able to run the login flow, but it was a lil' weird, I pasted the token,
> then it showed me a code and a github.com/login/device url, the device login
> worked fine but then the token would not be needed."

## What the evidence shows

Guest-side log, `/root/.cache/tillandsias/github-login-last.log`, one continuous run:

```
[tillandsias] ready

Paste your GitHub authentication token (input hidden), then press Enter:

! First copy your one-time code: 94D8-AE05
Open this URL to continue in your web browser: https://github.com/login/device

✓ Authentication complete.
✓ Configured git protocol
! Authentication credentials saved in plain text
✓ Logged in as 8007342
```

Host-side tray log, same window:

```
04:58:26  tray menu click menu_id=github-login
04:58:59  github sign-in state resolved from="signing-in" to="signed-out"
05:00:34  github sign-in state resolved from="signed-out" to="signed-in"
```

That intermediate `signed-out` at 04:58:59 is the tell: the token the operator
pasted **did not authenticate**. The device flow that followed did, 95 seconds
later. So the operator's read is exactly right — the token was collected and
then turned out to be unnecessary.

The end state is correct: signed in as `8007342`, git protocol configured, and
the git identity stored correctly (verified: `name = Tlatoani`,
`email = bulloncito@gmail.com` in the guest gitconfig — the log renders those
two prompts on one line without values, which looks alarming but is only
formatting; the values landed).

## Why this is worth fixing beyond the annoyance

1. **A credential was collected that the system did not need.** The token is
   read into a shell variable in the login container and piped to
   `gh auth login --with-token`. That is a reasonable design when the token is
   the auth path. It is not reasonable when the flow then authenticates by a
   different route — the operator has now pasted a live GitHub token into a
   prompt for no benefit, and the least-surprise expectation after "please paste
   your token" is that the token is what authenticated them.
2. **The prompt makes a promise the flow does not keep.** An operator who does
   not have a token to hand has no way to know, at the prompt, that pressing on
   to the device flow would have worked. `GH_LOGIN_TOKEN_SCRIPT` aborts on an
   empty token (`No token entered; aborting GitHub login.`, exit 1) — so the
   documented escape from the prompt is failure, not the device flow that
   actually works.

## What IS established

- `GH_LOGIN_TOKEN_SCRIPT` (`crates/tillandsias-headless/src/main.rs:7100`) reads
  the token and pipes it to `gh auth login --hostname github.com
  --git-protocol https --with-token`. That script contains no device flow.
- `gh auth login --with-token` never emits a device code, so the
  `github.com/login/device` prompt came from somewhere else in the sequence.
- GitHub is registered as `AuthModel::OAuthDevice`
  (`main.rs:523`) while being handed the **token-entry** script — a declared
  auth model and an actual input method that do not agree. All four providers
  use `AuthModel::OAuthDevice`, so the label may carry no branching, but the
  inconsistency is real and is the obvious place to start.

## What is NOT established

Which component launched the device flow after the token attempt failed — a
deliberate fallback, `gh`'s own behaviour, or a second invocation. This was not
traced to a specific call site, and the report deliberately stops short of
guessing at it.

## Suggested resolution

Decide which is the primary path and make the UI say so:

- If device flow is primary, **stop prompting for a token** and go straight to
  the code + URL. The token prompt is then dead weight that costs an operator a
  paste and a live credential.
- If the token is primary, the fallback must be announced — the prompt should
  say a token is optional and that pressing Enter continues with browser sign-in,
  and an empty token must NOT abort with an error.

Either way, a failed token attempt should say so out loud rather than sliding
silently into a different flow. The operator saw a device code with no
indication that their paste had been rejected.
