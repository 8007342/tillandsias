## ADDED Requirements

### Requirement: local is an implementer tier below haiku

The packet field `implementer_tier` SHALL accept `local` in addition to `haiku`, `sonnet` and `opus`. The batch selector SHALL offer a `local` row to the local delegate only when `TILLANDSIAS_INFERENCE_ENDPOINT` answers. Otherwise, and whenever the delegate's result is rejected, the row SHALL be worked at the haiku tier.

#### Scenario: endpoint available

- **WHEN** the selector picks a `local` row and the inference endpoint answers
- **THEN** the batch line names tier `local`

#### Scenario: endpoint down

- **WHEN** the endpoint does not answer
- **THEN** the same row is offered at tier `haiku`

### Requirement: the local delegate is bounded to owned files and never commits

`scripts/local-delegate.sh implement <order>` SHALL:

- build its prompt from the context pack, the row's goal, its exit criteria, its owned files and retrieved idioms;
- run a bounded tool loop against the local endpoint;
- revert every edit to a file not in the row's `owned_files`, and report `out-of-scope`;
- run the row's closure command once at the end;
- print exactly one verdict line.

It SHALL NOT create a commit, and SHALL use no jq or python.

#### Scenario: a stray edit

- **WHEN** the model edits a file outside `owned_files`
- **THEN** that edit is reverted, the verdict is `out-of-scope`, and `git log -1` is unchanged

#### Scenario: a passing closure

- **WHEN** the model's edits make the closure pass
- **THEN** the verdict is `ok`, the changes are left uncommitted for the frontier session to verify and commit, and `git log -1` is unchanged

### Requirement: outcomes are ledger tokens and promotion is computed

The frontier session SHALL record each delegated result as an event token:

```
local-delegate:<model>:<quant>:<order>:<accepted|rejected|reverted>:<frontier_tokens_avoided>:<retries>
```

The aggregator SHALL compute the highest rung reached for each (model, quant):

- **R1:** acceptance at least 70% and revert at most 5%;
- **R2:** acceptance at least 80% and revert at most 3%;
- **R3:** acceptance at least 80% and positive total frontier tokens saved;
- **R4:** revert at most 2% over at least 100 outcomes.

R1–R3 SHALL require at least 20 outcomes.

#### Scenario: a first rung

- **WHEN** a model has 20 outcomes, 15 accepted and 1 reverted
- **THEN** the aggregator prints `rung=R1` for that model and quant

#### Scenario: too few outcomes

- **WHEN** a model has 19 outcomes
- **THEN** the aggregator prints `rung=none:sample`

### Requirement: candidate models are benchmarked on tool calls and a replay set

The inference bench SHALL have an arm that reports whether a model completes an OpenAI tool-call round trip. A replay set of 20 landed size:S packets SHALL record each packet's pre-fix commit, owned files and closure command. Every closure in the set SHALL fail on its pre-fix commit and pass on its landed commit.

#### Scenario: replay set integrity

- **WHEN** `verify-set.sh` runs
- **THEN** every listed closure fails on its pre-fix commit and passes on its landed commit
