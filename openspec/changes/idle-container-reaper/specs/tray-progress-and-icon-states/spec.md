## ADDED Requirements

### Requirement: A reap never blushes

Reaping an idle container MUST NOT change the tray icon phase: blushing is
reserved for container creation and pups for finished work. The single
non-interactive status line MAY show the latest reap verdict (for example
"reaped 1 idle preview (3 h)") until the next status event replaces it. A
relaunch caused by `publish_local` blushes like any creation.

#### Scenario: Reap while plain
- **WHEN** the sweep stops an idle preview and the icon is plain
- **THEN** the icon stays plain and the status line reads the reap verdict

#### Scenario: Relaunch after a reap
- **WHEN** an agent's `publish_local` relaunches the reaped preview
- **THEN** the icon blushes during creation and shows pups when the route is ready
