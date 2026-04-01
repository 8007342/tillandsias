## 1. Lifecycle line cleanup
- [x] 1.1 In entrypoint-forge-claude.sh, redirect all [lifecycle] echo lines to stderr
- [x] 1.2 In entrypoint-forge-opencode.sh, redirect all [lifecycle] echo lines to stderr
- [x] 1.3 In entrypoint-terminal.sh, redirect all [lifecycle] echo lines to stderr

## 2. Color improvements
- [x] 2.1 In forge-welcome.sh, replace D_BLUE with B_BLUE (bright blue, \033[1;94m) for mount source paths
- [x] 2.2 Add ramdisk color (B_MAGENTA, \033[1;95m) and use it for token/secret mount display
- [x] 2.3 Add "* ramdisk" legend line after mounts section, aligned with mount paths, using B_MAGENTA

## 3. Verify
- [x] 3.1 Ensure embedded.rs still compiles (include_str picks up changes automatically)
