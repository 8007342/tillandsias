# The Windows→WSL hop mangles `$` expansions, and the compliant recipe is written down nowhere

Passing a script to a WSL guest as part of the `wsl.exe` argument string
silently corrupts `$` expansions. The obvious workaround — base64-encoding the
script — reads as forbidden by `base64_script_injection_ban`. **A compliant
recipe exists, is one line, and is recorded in no cheatsheet or methodology
file**, so each host rediscovers the problem and then stalls on the apparent
ban.

This belongs beside 1155-jurn's finding that exit status through this same hop
is decoration: same transport, same class of silent corruption, and 1155-jurn
already established that a measurement taken across it cannot be trusted
without a control.

trace: order 1155-jurn (adjacent), methodology.runtime_language_policy.base64_script_injection_ban
host: yolanda-windows (Windows 11, Git Bash / PowerShell → `wsl.exe`)

---

## 1. The measurement

Reading a 28-byte token file inside the guest, through the argument string:

```
wsl.exe -d tillandsias -- bash -lc '... echo "token_len=${#TOK}" ...'
    ->  token_len=0            # the file is really 28 bytes
```

Two further shapes, same session, same cause:

- A `<<"EOF"` heredoc written *inside* the command string: `$ADDR` and
  `${#TOK}` both arrived **empty**, so a loop ran against a blank `VAULT_ADDR`
  and produced three misleading `permission denied` results before the empty
  variable was noticed.
- `/mnt/c/...` is **not mounted** in the `tillandsias` distro, so the usual
  escape — write the script on the Windows side, point `bash` at the path —
  fails with "No such file or directory".

Quoting does not help. The corruption happens in transit, before any shell sees
the text. This is broader than 1155-jurn's `$?` finding: **any** `$` expansion
written in the argument string is at risk, not only `?`.

## 2. Why the empty value is the dangerous part

`${#TOK}` arriving as `0` does not look like a transport fault. It looks like an
empty file, which is a plausible finding about the system under test. In this
session it produced a confident wrong reading — "the Vault root token is empty"
— that survived until a second probe contradicted it. A mangled expansion is
indistinguishable from a real measurement of an absent value, which is exactly
the property that makes 1155-jurn's control necessary.

## 2b. It caught the author again, one hour after this row was filed

Gathering provenance for an unrelated finding, through the same hop:

```
wsl.exe -d tillandsias -- bash -c 'for b in git gh; do printf "%s: %s\n" "$b" "$(command -v $b || echo ABSENT)"; done'
    ->  : 
        :
```

`$b` arrived empty in both iterations. The loop ran, printed two well-formed
lines, and said nothing. Written by the author of this row, about an hour after
filing it, while deliberately working on the Windows lane.

**That is the thesis, and it is a stronger instance than section 1.** The
failure mode is not that the technique is hard to remember — it is that the
corrupted output is a well-formed-looking RESULT rather than an error. Two lines
reading `: ` are what an empty PATH lookup would also print. Nothing in the
output announces that the loop variable never arrived.

The measurement was rescued only because the same probe also ran `rpm -q git`,
which needs no variable and answered plainly (`package git is not installed`).
A discipline reminder would not have helped here; a form that carries no `$`
through the argument string did.

This is the argument for recording the recipe somewhere a person lands on by
symptom rather than by cause — see section 5.

## 3. The compliant recipe, verified

```bash
cat p.sh | wsl.exe -d <distro> -- bash -c 'cat > /tmp/p.sh; bash /tmp/p.sh'
```

Verified on this host: `${#TOK}` survives intact (`len=8` on an 8-character
value). The script never enters the argument string, so there is nothing for the
transport to rewrite, and it can be authored normally with a quoted heredoc.

## 4. The ban is scoped correctly and READS as broader than it is

Reaching for base64 first is the natural move, and then the rule stops you:

> `methodology.yaml:186-191` — Embedding scripts of ANY language inside
> base64-encoded string literals — whether in Rust source, YAML, shell, or any
> other file — is unconditionally forbidden.

"unconditionally" and "any other file" map straight onto an interactive
transport shim for a reader in a hurry — and a prior base64 podman shim really
was removed for this rule on 2026-07-02 (noted in a `pty/mod.rs` comment), which
makes the mapping look confirmed.

**It does not actually cover this case.** The rule's corollary scopes the harm
to presence *in source code* as a mechanism to generate and execute a script at
runtime, and its incident was smuggling Python past `tlatoani_hard_no_python`.
An interactive command line is not a file; bash is an approved language; no
policy is circumvented.

This was raised by the author rather than self-acquitted, and **ruled outside
the ban's scope by macuahuitl-fedora after reading the rule text — not
forgiven**. Recording the ruling here so the next person does not spend the same
time, and so the distinction is available to whoever decides whether the rule's
wording should be narrowed.

The shape is worth naming because it recurs: a correctly-scoped rule that reads
as broader than it is, encountered at the moment someone is blocked. That is the
same failure mode as the inert remedy in 1211-34v6, one layer up.

## 5. Suggested disposition

Put the recipe in a cheatsheet on the Windows lane beside the 1155-jurn control,
so it is found by someone searching for the symptom (`${#VAR}` empty, heredoc
variables blank, `/mnt/c` absent) rather than only by someone who already knows
the cause. Optionally add a one-line scope note to
`base64_script_injection_ban` distinguishing a committed literal from an
interactive transport, since the current wording invites the broader reading.
