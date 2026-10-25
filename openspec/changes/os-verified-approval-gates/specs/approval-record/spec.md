## ADDED Requirements

### Requirement: the approval statement binds the exact action

An approval SHALL be a signature over a canonical statement naming the action
kind, project, target, old and new revision (for git actions), a curated
detail sentence, host, strength, a broker-issued nonce, issue time and an
expiry ten minutes later.

#### Scenario: an approval for one action does not cover another

- **WHEN** an approval for merging into `linux-next` at one revision is
  presented for a different revision or branch
- **THEN** it is refused

### Requirement: git approvals are notes pushed atomically with the ref

An approval for a git action SHALL be a git note on the approved commit under
`refs/notes/tillandsias/approvals`: a plain first-line sentence with no hash,
then the statement and the armored signature, pushed in the same atomic push as
the branch. Merge commits made by host tools SHALL also carry an `Approved-by:`
trailer naming who approved and how, without a hash.

#### Scenario: the record reads plainly

- **WHEN** `git log --notes=tillandsias/approvals` shows an approved merge
- **THEN** the first note line is a sentence with no hexadecimal hash

### Requirement: the mirror verifies grants for gated promotions

For each ref update that matches a promotion marked approval-required in the
branch-discipline seed, the git-mirror `pre-receive` hook SHALL find a grant
covering it and check that grant's signature with `ssh-keygen -Y verify` and
its expiry. In `enforced` mode it SHALL refuse before relaying. In `present`
and `allow` modes it SHALL accept and journal the result.

#### Scenario: an unapproved gated promotion is refused when enforced

- **WHEN** a push matches a required promotion with no valid grant on an
  `enforced` host
- **THEN** the push is refused, nothing is relayed upstream, and the message
  says in one sentence how to ask for approval

#### Scenario: a standing grant is honoured

- **WHEN** a push matches a required promotion and a valid signed standing
  grant covers it
- **THEN** the hook relays and accepts it

#### Scenario: work refs are not gated

- **WHEN** a push updates `work/1879-5jkt`
- **THEN** no approval is required

### Requirement: non-git approvals are journaled

Approvals for non-git actions SHALL be appended to a host approval journal and,
when the action names a commit, also written as a note on that commit.

#### Scenario: a workflow dispatch leaves a record

- **WHEN** a workflow dispatch is approved
- **THEN** the journal gains one entry whose signature verifies
