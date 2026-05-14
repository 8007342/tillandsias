# Proposal: Tray Minimal UX

## Summary
Implement a minimalistic tray UX flow that shows only essential elements at launch and dynamically updates as the environment is verified. The tray will show a simple 4-element menu initially, then expand to show project and cloud items only after all enclave images are built successfully.

## Problem
The current tray menu shows too many items at launch, including projects, settings, and other elements before the environment is ready. This creates visual clutter and confusion about what actions are available.

## Proposed Solution
Implement a 5-stage tray UX:

1. **Launch state**: Show only:
   - `<Checklist> Verifying environment ...`
   - Divider
   - `Version + Attribution`
   - `Quit Tillandsias`

2. **Building state**: Dynamically update first element as containers initialize:
   - `<Checklist> Verifying environment ...`
   - `<Checklist><Network> Building enclave ...`
   - `<Checklist><Network><Mirror> Building git mirror ...`

3. **Ready state** (all images built):
   - `<Checklist><Network><Mirror><Browser><DebugBrowser> ✓ Environment OK`
   - Or `<WhiteRose> Unhealthy environment` on failure

4. **Authenticated state**: After successful build + GitHub auth:
   - Show `<Home> ~/src >` (local projects)
   - Show `<Cloud> Cloud >` (remote projects)

5. **Click behavior**: When clicking a project:
   - Clone remote projects to local first if needed
   - Launch OpenCode Web container
   - Once container is healthy, launch safe browser window in `tillandsias-chromium-core` container

## Key Changes
- Simplify initial tray menu to 4 elements only
- Add dynamic status updates during environment verification
- Implement project click → OpenCode Web + chromium browser flow
- Add stale container cleanup on startup

## Success Criteria
- [ ] Tray shows only 4 elements at launch
- [ ] Status element updates dynamically during builds
- [ ] Projects/Cloud items appear only after successful initialization
- [ ] Clicking project launches OpenCode Web + chromium browser
- [ ] Stale containers are cleaned up on startup
