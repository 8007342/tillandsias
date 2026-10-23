# Pushing a change in acme-widgets

**Use when**: you finished a change in the acme-widgets project and want to publish it.

## How to push your change

acme-widgets runs branch discipline level 0, declared in `AGENTS.md`. Commit on `main`,
run `npm test`, then `git push origin main`. There is no integration branch, no pull
request step and no ledger to update.

## Running the tests

`npm test` runs the whole suite; it takes about ten seconds.
