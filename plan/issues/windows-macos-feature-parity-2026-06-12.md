# Windows and macOS Feature Parity Restoration

**Context:**
The Windows and macOS implementations claim to be "completed" regarding creating and launching the forge boxes, but they are far behind the Linux headless and tray implementations and suffer from significant glitches. 

**Requirements:**
1. Establish true feature parity with the Linux headless and tray binaries.
2. Fix the specific startup glitches:
   - The binaries currently launch with broken menus showing extremely stale spec elements.
   - They falsely claim to have created the containers, but nothing is actually able to launch.
3. Implement necessary methodology and plan updates to ensure Windows/macOS branches (`windows-next`, `osx-next`) stay in lockstep with `linux-next`.
4. **End-to-End Testing**: With Claude's recent fixes to the `github-login` Vault flow, verify the entire end-to-end behavior on Windows and macOS. Prove things actually work, rather than just claiming they work.
5. Track progress using waves of agents tailored to the task (e.g., specialized macOS or Windows troubleshooting subagents).
