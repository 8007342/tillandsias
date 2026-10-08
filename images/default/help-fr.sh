#!/usr/bin/env bash
# @trace spec:help-system-localization
# help-fr.sh — Système d'aide de Tillandsias Forge
# Version française

cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                   Aide de Tillandsias Forge                    ║
╚════════════════════════════════════════════════════════════════╝

CONSEILS RAPIDES
────────────────
• Tapez `help` pour voir ce message de nouveau
• Utilisez les raccourcis Fish: Tab pour autocomplétion, Ctrl+R pour recherche
• Aperçu des fichiers avec: bat <fichier>
• Explorez les répertoires avec: eza --tree
• Recherche floue avec: fzf

AGENTS ET DÉVELOPPEMENT
───────────────────────
Claude Code:
  • Démarrez avec: /claude (ou simplement 'claude')
  • Exécutez: /opsx (commandes OpenSpec)
  • Chat: Demandez révision, générez boilerplate, déboguez

OpenCode:
  • Démarrez avec: /opencode (ou 'opencode')
  • Modifiez le code efficacement avec des suggestions intelligentes
  • Exécutez: opencode <commande> (ex: opencode run)

Opérations Git
  • Cloner: git clone <repo>
  • Commit: git add . && git commit -m "message"
  • Push: git push origin <branche>
  • Statut: git status
  • GitHub CLI: gh repo view, gh pr list, gh issue create

CONTENEUR ET ENVIRONNEMENT
──────────────────────────
Projet Actuel: ${TILLANDSIAS_PROJECT:-inconnu}
Répertoire du Projet: /home/forge/src/<projet>
Réseau: Enclave uniquement (pas d'internet)
Identifiants: Aucun dans le conteneur (auth git via service miroir)

Modifications de Code:
  ✓ Tout travail non confirmé est ÉPHÉMÈRE (perdu à l'arrêt)
  ✓ Confirmez les modifications pour les conserver: git commit
  ✓ Push pour mettre à jour le distant: git push

DÉPANNAGE
─────────
Problème: Commande introuvable
  → Vérifiez l'installation: which <commande>
  → Listez les commandes: ls -la /usr/local/bin/

Problème: Git push échoue
  → Vérifiez config: git config -l
  → Redémarrez service git: reconnectez-vous
  → Vérifiez identifiants: gh auth status

Problème: npm/cargo/pip install échoue
  → Paquets via proxy: vérifiez env var HTTPS_PROXY
  → Videz cache: rm -rf ~/.cache/tillandsias/<outil>/
  → Réessayez: npm install

Problème: Permission refusée
  → Vérifiez votre utilisateur: whoami
  → Propriété du fichier: ls -l <fichier>
  → Rendez exécutable: chmod +x <fichier>

COMMANDES UTILES
────────────────
Navigation de Fichiers:
  eza <dir>          Liste les fichiers (élégant)
  eza --tree         Vue en arborescence
  tree               Arborescence des répertoires
  cd /home/forge/src Aller à la racine du projet

Traitement de Texte:
  bat <fichier>      Aperçu avec syntaxe
  rg <motif>         Ripgrep (recherche rapide)
  fd <motif>         Trouve les fichiers par motif
  fzf                Rechercheur flou

Infos Système:
  df -h              Utilisation du disque
  du -sh <dir>       Taille du répertoire
  ps aux             Processus en cours
  htop               Visionneuse interactive
  top                Moniteur CPU/mémoire

DOCUMENTATION
──────────────
Livres de Consulta:
  ls /opt/cheatsheets/        Explorez les livres disponibles
  cat /opt/cheatsheets/INDEX.md

Apprenez le Shell:
  man <commande>     Pages manuelles
  help <builtin>     Aide bash intégrée
  type <commande>    Affiche le type de commande

Besoin d'aide?
  • Tapez: /claude (demandez à Claude Code)
  • Explorez: /opt/cheatsheets/
  • Vérifiez: git log --oneline (commits récents)

═══════════════════════════════════════════════════════════════════
Tapez q pour quitter ou une commande pour continuer.
EOF
