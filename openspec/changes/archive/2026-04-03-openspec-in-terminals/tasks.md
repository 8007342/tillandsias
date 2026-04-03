## 1. Shared Install Function
- [x] 1.1 Add install_openspec() function to lib-common.sh with the npm install logic
- [x] 1.2 Remove inline OpenSpec install from entrypoint-forge-claude.sh, replace with install_openspec call
- [x] 1.3 Remove inline OpenSpec install from entrypoint-forge-opencode.sh, replace with install_openspec call

## 2. Terminal Integration
- [x] 2.1 Add install_openspec call to entrypoint-terminal.sh (after lib-common.sh source, before welcome)
- [x] 2.2 Add openspec init in terminal entrypoint (non-interactive, --tools terminal flag or no flag)
