## ADDED Requirements

### Requirement: machine-checked model claims carry their own strength and limit

The methodology SHALL record a claim whose support is a machine-checked
theorem at a claim strength of its own, distinct from the strengths for
project practice, external analogy, adopted standard and project invariant.
Every such claim SHALL name the registered theorem and SHALL state the
limit: the theorem is proved of the model and establishes nothing about
whether the implementation matches the model or about the world the model
abstracts. A claim SHALL carry this strength only while its theorem is
registered and the formal lane reports it proved.

Documentation SHALL keep four words apart: proved, for a theorem about the
model; model-checked, for a property of implementation code up to a stated
bound; tested; and empirical. A machine-checked theorem SHALL NOT be cited
as evidence for a conditional premise, such as the progress premise that a
residual reaches zero, nor to restore a claim the methodology has withdrawn.

#### Scenario: a claim cites a theorem that is not registered

- **WHEN** a methodology claim carries the machine-checked strength and its theorem is absent from the registry or not reported proved
- **THEN** the claim check fails and names the claim

#### Scenario: a conditional bound is cited with its condition

- **WHEN** documentation cites the theorem bounding the cycles to a zero residual
- **THEN** it states the progress premise as an unproved hypothesis in the same sentence or the next

#### Scenario: a validation check names its theorem or says why none exists

- **WHEN** a reader looks up a phase 1 or phase 2 check of the validation program
- **THEN** the entry names the registered theorem that proves it, or says it is not a theorem and why
