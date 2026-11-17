# Observatorium blind design (2026-11-09)

A clean-room exercise. A designer saw only tillandsias.org's level-5 obligations
(docs/matrix/level-5-phd.md) and public sources, then designed the observatorium.
A sighted "membrane" answered its questions with facts only (answers.md). A judge
then scored the blind design against the existing one (rubric.md, comparison.md):
blind 65/86, existing 38/86, from one rater.

Operator rulings, 2026-11-09:
- Plain generated HTML replaces the Flutter app. It will also be used to test the
  GrapeJS local editor, so keep the markup clean, semantic and editable.
- Delete the old docs/convergence/centicolon-dashboard.* outright. Make the new one
  pretty.
- NO auto-deploy anywhere. Publishing is a manual wrangler deploy from the operator's
  machine after a release. No Workers Builds trigger is connected; never connect one.
  Remove the automatic deploy/observatorium move from promote-stable.sh, and fix
  methodology/versioning.yaml's "Workers Builds trigger" claim.

Start with comparison.md (the recommended target), then design.md (rev2), then
learnings.md.
