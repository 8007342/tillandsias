## ADDED Requirements

### Requirement: a startup and shutdown splash follows lifecycle events

The tray SHALL show a splash during startup and shutdown, at normal window
level (never always-on-top), closable without affecting the tray. Its Mācron
animation SHALL advance only when the tray emits a lifecycle stage event
(`TrayStatusStage` on Linux and the matching stages on macOS and Windows), one
scene step per stage, and SHALL close itself when all services are ready or
shutdown completes.

#### Scenario: progress comes from events, not a timer

- **WHEN** a fixture emits stages in order with arbitrary gaps
- **THEN** the splash step equals the last stage received, regardless of time

#### Scenario: a stuck step stalls visibly

- **WHEN** no stage event arrives for longer than the stage's expected duration
- **THEN** the animation stops and a calm line says the step is taking longer
  than usual, naming the step

#### Scenario: it does not float

- **WHEN** the splash is open and the operator focuses another window
- **THEN** the other window is above the splash

#### Scenario: a failure is shown, not hidden

- **WHEN** a `Failed` stage arrives
- **THEN** the splash shows the failed step in plain words and stays until
  closed
