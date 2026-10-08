## ADDED Requirements

### Requirement: formal tools run on builders and never ship

Proof and model-checking toolchains (Lean, and Kani where adopted) SHALL run
only on builder infrastructure, inside a pinned OCI image started by podman
and reached through the toolbox-first pattern, so that a Linux host needs no
host package to use them. The image SHALL NOT be part of the builder
toolbox's initialization set. No shipped binary, runtime image or installer
SHALL reference, bundle or download either toolchain; adding one to the user
runtime SHALL require a recorded operator decision stating the
justification.

#### Scenario: a Linux host without a native toolchain checks the theorems

- **WHEN** the formal lane runs on a Linux builder that has podman and no native Lean
- **THEN** it checks the registered theorems inside the pinned image and installs nothing on the host

#### Scenario: a shipped artifact that references a formal tool is refused

- **WHEN** a runtime image definition, an installer, or the manifest of a shipped crate gains a reference to Lean, elan, lake or Kani
- **THEN** the runtime-boundary check fails and names the path

### Requirement: the verdict is decided by axioms, not by the build

The formal lane SHALL report a theorem as proved only when that theorem
exists and every axiom it depends on is in an allowlist consisting of
`propext`, `Classical.choice` and `Quot.sound`. A proof that uses `sorry`,
a user-declared axiom, or `native_decide` SHALL be refused, and the refusal
SHALL name the theorem and the offending axiom. A successful build alone
SHALL NOT produce an ok verdict.

#### Scenario: a theorem proved with sorry is refused although it compiles

- **WHEN** a registered theorem's proof contains `sorry` and the project builds without error
- **THEN** the lane refuses, naming the theorem and `sorryAx`

#### Scenario: a user-declared axiom is refused

- **WHEN** a registered theorem depends on an axiom declared in the project
- **THEN** the lane refuses, naming the theorem and that axiom

### Requirement: an absent toolchain is a named skip

The formal lane SHALL have exactly three outcomes, each with its own exit
status and one verdict line: ok, naming the count of registered theorems
checked; refused, naming the theorem and the reason; and skipped, naming
what is missing. A host that cannot run the lane SHALL report skipped and
SHALL NOT report ok.

#### Scenario: a host without the image does not report success

- **WHEN** the lane runs on a host where the pinned image is unavailable
- **THEN** the verdict line begins with `skip:`, names the image, and the exit status differs from both the ok and the refused status

### Requirement: the lane is outside the build gate

The formal lane SHALL be its own entry point and SHALL NOT run as part of
`./build.sh --check`. It SHALL NOT run concurrently with a gate on the same
host.

#### Scenario: the build gate does not need the formal image

- **WHEN** `./build.sh --check` runs on a host without the formal image
- **THEN** its verdict is unaffected by the absence

### Requirement: a registry binds each theorem to the claim it supports

A registry SHALL list every theorem the methodology relies on, each with its
name, the methodology check or claim it discharges, and the layer it speaks
about. The lane SHALL check exactly the registered theorems and SHALL refuse
when a registered name does not resolve to a theorem.

#### Scenario: a registered theorem that does not exist is refused

- **WHEN** the registry names a theorem absent from the project
- **THEN** the lane refuses and names it

### Requirement: statements are reviewed before proofs are written

The statement of a registered theorem SHALL be reviewed by the operator
before its proof is accepted, and a change to a registered statement SHALL
require the same review, recorded as an event on the packet that owns the
theorem.

#### Scenario: a changed statement without a recorded review is not registered

- **WHEN** a registered theorem's statement changes and no review event names the new statement
- **THEN** the theorem is not cited by the methodology at the machine-checked strength

### Requirement: the model mirrors the implementation it speaks for

The Lean model SHALL use the same seven evidence states in the same order
as the implementation, a refinement step in which every rule reads the
state before the step and raises its obligation to the greater of its
current state and the rule's target, and a score in which a tombstoned
obligation leaves both the numerator and the denominator and marks the
result as outside the monotone regime. The deliberately wrong rule set
committed as a negative control for the implementation's property tests
SHALL also be the model's negative control.

#### Scenario: the committed wrong model is shown non-monotone in the model too

- **WHEN** the rule set that raises one obligation only while another is exactly at `declared` is checked in the model
- **THEN** a registered theorem exhibits a pair of ordered states whose refinements are not ordered

### Requirement: expected-value vectors link the model to the implementations

The proved model SHALL emit a vector file of expected scores over an
enumerated domain that the file itself states. The Rust scorer and a pure
Lua scoring predicate running under the cacheable predicate class SHALL
each be tested against every vector. Agreement with the vectors SHALL be
described as tested, never as proved.

#### Scenario: a wrong expected value turns both implementations red

- **WHEN** one expected residual in the vector file is changed by one
- **THEN** the Rust test and the Lua test both fail and each names the vector

#### Scenario: the Lua scoring predicate cannot observe the world

- **WHEN** the Lua scoring predicate is given a shell or clock verb
- **THEN** it fails, because it runs under the cacheable class

### Requirement: committed vectors cannot go stale silently

Where the formal image is available, a check SHALL regenerate the vectors
from the model and refuse when they differ from the committed file. Where
it is not, hosts SHALL run the conformance tests from the committed file
and the regeneration check SHALL report skipped.

#### Scenario: a model change without regenerated vectors is refused

- **WHEN** the model's scoring definition changes and the committed vectors are not regenerated
- **THEN** the regeneration check refuses on a host with the image

### Requirement: a bounded check states its bound

Where a bounded model checker is used on implementation code, every result
SHALL state the bound it holds for, in the harness and wherever the result
is cited, and the harnesses SHALL be absent from every normal build.

#### Scenario: a bounded result is cited with its bound

- **WHEN** the methodology or the website cites a model-checked property of the scorer
- **THEN** the citation names the obligation-count bound of the harness
