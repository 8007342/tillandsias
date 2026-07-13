# Git mirror pre-receive hook rejects `.openspec.yaml` files (Ruby Psych Date class)

**Filed**: 2026-07-12T22:34Z
**Host**: git mirror (tillandsias-git)
**Classification**: blocker/regression

## Summary

The git mirror's pre-receive hook runs a Ruby YAML validator
(`ruby -ryaml -e "YAML.load_file('<file>')"` with `safe_load` semantics) that
rejects any `.openspec.yaml` file containing a bare `Date` scalar (e.g.
`date: 2026-05-04`). Ruby's `Psych::DisallowedClass` exception is thrown
because `safe_load` does not allow `Date` deserialization.

This affects 15+ archived OpenSpec change files under
`openspec/changes/archive/`. Every push that touches the full history of any
branch triggers these rejections.

## Impact

- Pushes through the mirror succeed (the rejects are advisory, not blocking
  for the pushed ref), but the pre-receive output is noisy and confusing.
- If the hook is ever tightened to reject on any file failure, ALL pushes
  will be blocked.

## Smallest Next Action

Fix the mirror's pre-receive YAML validator to use `YAML.safe_load` with
`permitted_classes: [Date]`, or switch to `tillandsias-policy validate-yaml`
which handles Date scalars correctly. Owner: operator.

## Verifiable Closure

```bash
# After fix, push output should contain no "REJECT" lines:
git push git://tillandsias-git/tillandsias osx-next 2>&1 | grep -c "REJECT" | grep -q "^0$"
```
