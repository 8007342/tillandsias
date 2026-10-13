# 1652-p8xv: an unnamed modifier extra makes a resolver match approximated

- red.txt: the new test `a_match_that_needs_an_unnamed_modifier_is_approximated`
  on the 1644-u8b8 tree (40ec8e9a7). "galaxy s23" resolved exactly to the S23 FE.
- Cause: "fe" was not in MODIFIERS, so the FE's extra token scored as a plain
  extra (0,1) and beat the S23+ and S23 Ultra (1,0). Exact, because the token
  rule only flagged ties.
- Fix: "fe" is a modifier (and not a base model), and a token-rule winner that
  carries any modifier the query did not name is approximated.
- green.txt: all 11 devices tests pass; "galaxy s23" now gives the S23+ with
  approximated true and the Ultra and FE as alternatives; "galaxy s23 fe"
  stays exact (alias rule).
