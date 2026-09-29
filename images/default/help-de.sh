#!/usr/bin/env bash
# @trace spec:help-system-localization
# help-de.sh — Hilfe für Tillandsias Forge
# Deutsche Version

cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                   Tillandsias Forge Hilfe                      ║
╚════════════════════════════════════════════════════════════════╝

SCHNELLTIPPS
────────────
• Geben Sie `help` ein, um diese Nachricht erneut anzuzeigen
• Verwenden Sie Fish-Tastenkombinationen: Tab zur Autovervollständigung, Strg+R für Verlauf
• Vorschau von Dateien mit: bat <datei>
• Verzeichnisse erkunden mit: eza --tree
• Unscharfe Suche mit: fzf

AGENTEN UND ENTWICKLUNG
───────────────────────
Claude Code:
  • Start mit: /claude (oder einfach 'claude')
  • Ausführen: /opsx (OpenSpec-Befehle)
  • Chat: Code-Review, generieren Sie Boilerplate, debuggen Sie

OpenCode:
  • Start mit: /opencode (oder 'opencode')
  • Code effizient mit intelligenten Vorschlägen bearbeiten
  • Ausführen: opencode <befehl> (z.B. opencode run)

Git-Operationen
  • Klonen: git clone <repo>
  • Commit: git add . && git commit -m "nachricht"
  • Push: git push origin <branch>
  • Status: git status
  • GitHub CLI: gh repo view, gh pr list, gh issue create

CONTAINER UND UMGEBUNG
──────────────────────
Aktuelles Projekt: ${TILLANDSIAS_PROJECT:-unbekannt}
Projektverzeichnis: /home/forge/src/<projekt>
Netzwerk: Nur Enklave (kein Internet)
Anmeldedaten: Keine im Container (git auth über Spiegeldienst)

Code-Änderungen:
  ✓ Alle nicht committeten Arbeiten sind FLÜCHTIG (gehen beim Stoppen verloren)
  ✓ Committe Änderungen um sie zu behalten: git commit
  ✓ Push um Remote zu aktualisieren: git push

FEHLERBEHEBUNG
───────────────
Problem: Befehl nicht gefunden
  → Prüfen Sie Installation: which <befehl>
  → Befehle auflisten: ls -la /usr/local/bin/

Problem: Git push schlägt fehl
  → Prüfen Sie config: git config -l
  → Starten Sie git-Dienst neu: reconnectieren Sie
  → Prüfen Sie Anmeldedaten: gh auth status

Problem: npm/cargo/pip install schlägt fehl
  → Pakete über Proxy: prüfen Sie HTTPS_PROXY env var
  → Cache leeren: rm -rf ~/.cache/tillandsias/<tool>/
  → Wiederholen: npm install

Problem: Berechtigung verweigert
  → Prüfen Sie Benutzer: whoami
  → Dateieigentümer: ls -l <datei>
  → Ausführbar machen: chmod +x <datei>

NÜTZLICHE BEFEHLE
──────────────────
Dateinavigation:
  eza <dir>          Dateien auflisten (elegant)
  eza --tree         Baumansicht
  tree               Verzeichnisbaum
  cd /home/forge/src Zur Projektwurzel gehen

Textverarbeitung:
  bat <datei>        Vorschau mit Syntax
  rg <muster>        Ripgrep (schnelle Suche)
  fd <muster>        Dateien nach Muster finden
  fzf                Unscharfer Sucher

Systeminformationen:
  df -h              Speichernutzung
  du -sh <dir>       Verzeichnisgröße
  ps aux             Laufende Prozesse
  htop               Interaktiver Betrachter
  top                CPU/Speicher-Monitor

DOKUMENTATION
──────────────
Spickzettel:
  ls /opt/cheatsheets/        Verfügbare Spickzettel durchsuchen
  cat /opt/cheatsheets/INDEX.md

Shell erlernen:
  man <befehl>       Handbuchseiten
  help <builtin>     Bash-integrierte Hilfe
  type <befehl>      Befehlstyp anzeigen

Weitere Hilfe?
  • Geben Sie ein: /claude (fragen Sie Claude Code)
  • Durchsuchen Sie: /opt/cheatsheets/
  • Prüfen Sie: git log --oneline (aktuelle Commits)

═══════════════════════════════════════════════════════════════════
Geben Sie q ein zum Beenden oder einen Befehl zum Fortfahren.
EOF
