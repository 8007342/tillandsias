# ci-node24-audit-and-fix

Audit GitHub Actions workflow run logs for remaining Node.js deprecation warnings. Both workflows have FORCE_JAVASCRIPT_ACTIONS_TO_NODE24 at workflow level but warnings may persist from action internals. Document the flag properly and fix all remaining warning sources.
