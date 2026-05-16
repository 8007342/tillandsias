#!/usr/bin/env bash
# @trace spec:help-system-localization
# help.sh — Tillandsias Forge help system
# English version with common commands, tips, and troubleshooting

# Detect locale if available
if [ -z "${L_WELCOME_TITLE:-}" ]; then
    _LOCALE_RAW="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
    _LOCALE="${_LOCALE_RAW%%_*}"
    _LOCALE="${_LOCALE%%.*}"
    _HELP_FILE="/usr/local/share/tillandsias/help-${_LOCALE}.sh"
    [ -f "$_HELP_FILE" ] || _HELP_FILE="/usr/local/share/tillandsias/help.sh"
    if [ "$_HELP_FILE" != "$0" ] && [ -f "$_HELP_FILE" ]; then
        source "$_HELP_FILE"
        exit 0
    fi
fi

cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                   Tillandsias Forge Help                       ║
╚════════════════════════════════════════════════════════════════╝

QUICK TIPS
──────────
• Type `help` to see this message again
• Use `fish` key bindings: Tab for autocomplete, Ctrl+R for history search
• Preview files with: bat <filename>
• Browse directories with: eza --tree
• Fuzzy find anything with: fzf

AGENTS & DEVELOPMENT
────────────────────
Claude Code:
  • Start with: /claude (or just 'claude' if available)
  • Run: /opsx (OpenSpec commands)
  • Chat: Ask for code review, generate boilerplate, debug

OpenCode:
  • Start with: /opencode (or 'opencode' if available)
  • Edit code efficiently with intelligent suggestions
  • Run: opencode <command> (e.g., opencode run)

Git Operations
  • Clone: git clone <repo>
  • Commit: git add . && git commit -m "message"
  • Push: git push origin <branch>
  • Status: git status
  • GitHub CLI: gh repo view, gh pr list, gh issue create

CONTAINER & ENVIRONMENT
───────────────────────
Current Project: ${TILLANDSIAS_PROJECT:-unknown}
Project Directory: /home/forge/src/<project>
Network: Enclave only (no internet)
Credentials: None in container (git auth via mirror service)

Code Changes:
  ✓ All uncommitted work is EPHEMERAL (lost on container stop)
  ✓ Commit changes to persist them: git commit
  ✓ Push to update remote: git push

TROUBLESHOOTING
───────────────
Problem: Command not found
  → Check if tool is installed: which <tool>
  → List available commands: ls -la /usr/local/bin/

Problem: Git push fails
  → Check git config: git config -l
  → Restart git service: reconnect to container
  → Verify credentials with: gh auth status

Problem: npm/cargo/pip install fails
  → Packages use proxy: check HTTPS_PROXY env var
  → Clear cache: rm -rf ~/.cache/tillandsias/<tool>/
  → Try again: npm install

Problem: File permissions denied
  → Check your user: whoami
  → File ownership: ls -l <file>
  → Make executable: chmod +x <file>

USEFUL COMMANDS
───────────────
File Navigation:
  eza <dir>          List files (fancy)
  eza --tree         Tree view
  tree               Directory tree
  cd /home/forge/src Go to project root

Text Processing:
  bat <file>         Syntax-highlighted preview
  rg <pattern>       Ripgrep (fast search)
  fd <pattern>       Find files by pattern
  fzf                Fuzzy finder

System Info:
  df -h              Disk usage
  du -sh <dir>       Directory size
  ps aux             Running processes
  htop               Interactive process viewer
  top                CPU/memory monitor

DOCUMENTATION
──────────────
Cheatsheets:
  ls /opt/cheatsheets/        Browse available cheatsheets
  cat /opt/cheatsheets/INDEX.md

Learn the Shell:
  man <command>      Manual pages
  help <builtin>     Bash builtin help
  type <command>     Show command type

Need More Help?
  • Type: /claude (ask Claude Code)
  • Browse: /opt/cheatsheets/
  • Check: git log --oneline (recent commits)

═══════════════════════════════════════════════════════════════════
Press q to exit this help, or type a command to continue.
EOF
