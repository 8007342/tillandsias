#!/usr/bin/env bash
# @trace spec:shell-prompt-localization-fr, spec:shell-prompt-localization-ja
# Tillandsias Forge — Deutsches Sprachpaket
# Wird von entrypoint.sh und forge-welcome.sh nach der Spracherkennung eingebunden.
# Variablen mit L_ als Präfix zur Vermeidung von Kollisionen.

# ── entrypoint.sh ────────────────────────────────────────────
L_BANNER_FORGE="tillandsias forge"
L_BANNER_PROJECT="Projekt:"
L_BANNER_AGENT="Agent:"

# ── forge-welcome.sh ──────────────────────────────────────────
L_WELCOME_TITLE="🌱 Tillandsias Forge"
L_WELCOME_PROJECT="Projekt"
L_WELCOME_FORGE="Forge"
L_WELCOME_MOUNTS="Einbindungen"
L_WELCOME_SECURITY="Sicherheit"
L_WELCOME_NETWORK="Netzwerk"
L_WELCOME_NETWORK_DESC="nur Enklave (kein Internet, Pakete über Proxy)"
L_WELCOME_CREDENTIALS="Anmeldedaten"
L_WELCOME_CREDENTIALS_DESC="keine (Git-Authentifizierung über Spiegeldienst)"
L_WELCOME_CODE="Code"
L_WELCOME_CODE_DESC="vom Git-Spiegel geklont (nicht committete Arbeit ist flüchtig)"
L_WELCOME_SERVICES="Dienste"
L_WELCOME_PROXY_DESC="cachender HTTP/S-Proxy (erlaubte Domains)"
L_WELCOME_GIT_DESC="Git-Spiegel + automatischer Push zum Remote"
L_WELCOME_INFERENCE_DESC="Ollama (lokales LLM)"

# ── Tipps (wechselnd, beim Anmelden angezeigt) ──────────────
L_TIP_1="Tippe help, um mehr über die Fish-Shell zu erfahren"
L_TIP_2="Probiere Midnight Commander mit mc"
L_TIP_3="Durchsuche Dateien mit eza --tree"
L_TIP_4="Verwende Tab für Autovervollständigung"
L_TIP_5="Durchsuche den Verlauf mit Strg+R"
L_TIP_6="Intelligenter Verzeichnissprung mit z <Teilname>"
L_TIP_7="Dateivorschau mit bat <Dateiname>"
L_TIP_8="Dateien schnell finden mit fd <Muster>"
L_TIP_9="Unscharfe Suche mit fzf"
L_TIP_10="Prozesse anzeigen mit htop"
L_TIP_11="Verzeichnisbaum anzeigen mit tree"
L_TIP_12="Dateien bearbeiten mit vim oder nano"
L_TIP_13="Fish hebt gültige Befehle beim Tippen grün hervor"
L_TIP_14="Fish schlägt aus dem Verlauf vor — drücke → zum Übernehmen"
L_TIP_15="Verwende .. um ein Verzeichnis nach oben zu gehen"
L_TIP_16="Dateien detailliert auflisten mit ll"
L_TIP_17="Jederzeit zu bash wechseln: tippe bash"
L_TIP_18="Jederzeit zu zsh wechseln: tippe zsh"
L_TIP_19="Git-Status prüfen mit git status"
L_TIP_20="GitHub CLI: gh repo view, gh pr list"

# ── Spickzettel ────────────────────────────────────────────────
# Hinweis: Der Spickzettel-Zeiger ist derzeit in forge-welcome.sh codiert
# und verwendet keine Locale-Variablen. Dies wird für zukünftige Lokalisierung
# beibehalten, wenn wir das Banner vollständig Locale-fähig machen.

# ── Fehlermeldungen (lib-localized-errors.sh) ──────────────────
L_ERROR_CONTAINER_FAILED="FEHLER: Container konnte nicht gestartet werden"
L_ERROR_CONTAINER_HINT="Versuchen Sie, den Container neu zu starten oder überprüfen Sie die Protokolle."

L_ERROR_IMAGE_MISSING="FEHLER: Container-Image nicht gefunden"
L_ERROR_IMAGE_HINT="Erstellen Sie das Image neu oder vergewissern Sie sich, dass es existiert. Prüfen Sie den verfügbaren Speicherplatz."

L_ERROR_NETWORK="FEHLER: Netzwerkfehler"
L_ERROR_NETWORK_HINT="Überprüfen Sie die Proxy-Einstellungen (HTTPS_PROXY env) und dass Netzwerkdienste laufen."

L_ERROR_GIT_CLONE="FEHLER: Git-Klon fehlgeschlagen"
L_ERROR_GIT_HINT="Überprüfen Sie Anmeldedaten, SSH-Schlüssel oder starten Sie den git-Dienst neu. Prüfen Sie git config."

L_ERROR_AUTH="FEHLER: Authentifizierung fehlgeschlagen"
L_ERROR_AUTH_HINT="Richten Sie Anmeldedaten neu ein mit 'gh auth login' oder prüfen Sie git config."

# ── Agent onboarding ──────────────────────────
L_AGENT_ONBOARDING="🤖 Agent-Onboarding"
L_AGENT_ONBOARDING_HINT="cat $TILLANDSIAS_CHEATSHEETS/welcome/readme-discipline.md für First-Turn-Anleitung"
