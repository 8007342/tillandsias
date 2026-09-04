# @trace order:901-jtvi
# Emit "file:line: <bad escapes>" for grep PATTERN arguments carrying an escape
# GNU grep does not define. Only the pattern argument is examined — never the
# rest of the command line, where a later awk or printf legitimately owns its
# own backslashes.
BEGIN { allowed = "sSwWbB<>123456789" }
{
  line = $0
  # $(printf ...) belongs to printf, not to grep: the shell substitutes a real
  # character before grep is invoked. Removing it is what keeps the CORRECT
  # idiom, "$(printf '\t')", from being refused as the defect it fixes.
  gsub(/\$\([^)]*printf[^)]*\)/, "", line)
  while ((i = index(line, "grep")) > 0) {
    rest = substr(line, i + 4)
    line = rest
    flags = ""
    while (match(rest, /^[ \t]+-[A-Za-z-]+/)) {
      tok = substr(rest, RSTART, RLENGTH); gsub(/^[ \t]+/, "", tok)
      flags = flags tok; rest = substr(rest, RSTART + RLENGTH)
    }
    # -F (fixed strings) interprets NO regex at all, and -P switches to PCRE,
    # where \\t \\d \\s \\w and \\xNN are all defined. Skipping both is correctness,
    # not leniency: the allowlist below describes GNU BRE/ERE only. Measured —
    # `grep -qP "a\\tb"` matches a real tab and emits no stray warning.
    if (flags ~ /[FP]/) continue
    pat = ""
    if (match(rest, /^[ \t]+'[^']*'/)) {
      pat = substr(rest, RSTART, RLENGTH); gsub(/^[ \t]+'/, "", pat); sub(/'$/, "", pat)
    } else if (match(rest, /^[ \t]+\\"[^\\]*\\"/)) {
      pat = substr(rest, RSTART, RLENGTH); gsub(/^[ \t]+\\"/, "", pat); sub(/\\"$/, "", pat)
    }
    if (pat == "") continue
    gsub(/\\\\/, "\\", pat)          # YAML spelling -> shell spelling
    bad = ""
    n = split(pat, ch, "")
    for (k = 1; k < n; k++) {
      if (ch[k] == "\\") {
        c = ch[k+1]
        if (c ~ /[A-Za-z0-9]/ && index(allowed, c) == 0) bad = bad "\\" c " "
        k++
      }
    }
    if (bad != "") print FILENAME ":" FNR ": " bad
  }
}
