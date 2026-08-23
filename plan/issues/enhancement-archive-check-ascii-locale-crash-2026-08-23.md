# enhancement: the 831-ezea archiver check crashes on unset-locale hosts — US-ASCII Ruby vs a UTF-8 ledger

- Filed: 2026-08-23 (UTC), by windows host **yolanda**. Class: enhancement/
  (fixed in the same commit; kept as the durable record).
- Related: scripts/archive-plan-packets.sh (`_ruby`), 831-ezea (the check),
  777-amku (toolbox-first ruby), c064ddc47 (check arrival).

Measured: `./build.sh --check` on yolanda died at "Checking the plan archiver
preserves the ready set (831-ezea)" with
`archive-plan-packets-check.rb:207:in 'String#match?': invalid byte sequence
in US-ASCII (ArgumentError)`. The gate on this host executes in WSL where
LANG/LC_ALL are empty, so Ruby's `Encoding.default_external` is US-ASCII and
`File.readlines(plan_tmp/index.yaml)` yields ASCII-tagged strings; the base
index carries 2,517 em-dashes, so the first `match?` raises. Any host whose
gate shell has no UTF-8 locale hits this on every run; UTF-8-locale hosts
(the Linux coordinator) never see it, which is why the check landed green.

Fix (this commit): `_ruby` passes `-E UTF-8:UTF-8` in both arms (host ruby
and toolbox ruby). The ledger is UTF-8 by construction; the encoding is now
stated instead of inherited from the environment.

Residual worth knowing: the finalization YAML-validation fallback
`ruby -ryaml -e "YAML.load_file(...)"` named in the meta-orchestration skill
inherits the same locale default and could fail the same way on these hosts;
not measured, not fixed here. Also a process note for the record: this red
was initially misread as green because the gate log was grepped for one
suite's verdict instead of reading the run's exit code — the exact
scrollback-diagnosis trap the skill already warns about (637-df4z shape).
