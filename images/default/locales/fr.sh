#!/usr/bin/env bash
# @trace spec:shell-prompt-localization-fr
# Tillandsias Forge — paquet de localisation française
# Importé par entrypoint.sh et forge-welcome.sh après la détection de locale.
# Variables préfixées par L_ pour éviter les collisions.

# ── entrypoint.sh ────────────────────────────────────────────
L_INSTALLING_OPENCODE="Installation d'OpenCode..."
L_INSTALLED_OPENCODE="  OpenCode prêt: %s"
L_WARN_OPENCODE="  AVERTISSEMENT: Le binaire d'OpenCode existe mais --version n'a rien retourné."
L_INSTALLING_CLAUDE="Installation de Claude Code..."
L_INSTALLED_CLAUDE="  Claude Code prêt: %s"
L_WARN_CLAUDE="  AVERTISSEMENT: Le binaire de Claude Code existe mais --version n'a rien retourné."
L_CLAUDE_NOT_FOUND="  Binaire de Claude Code introuvable après l'installation."
L_INSTALL_FAILED_CLAUDE="  ERREUR: npm install a échoué. Consultez la sortie ci-dessus pour plus de détails."
L_INSTALLING_OPENSPEC="Installation d'OpenSpec..."
L_INSTALLED_OPENSPEC="  ✓ OpenSpec installé"
L_OPENSPEC_NOT_FOUND="  ✗ Binaire d'OpenSpec introuvable après l'installation"
L_OPENSPEC_FAILED="  [courant] AVERTISSEMENT: DÉGRADÉ — OpenSpec indisponible, les commandes /opsx ne fonctionneront pas"
L_RETRY_HINT="Pour réessayer: redémarrez le conteneur"
L_CLEAR_CACHE_CLAUDE="Pour vider le cache: rm -rf ~/.cache/tillandsias/claude/"
L_CLEAR_CACHE_OPENCODE="Pour vider le cache: rm -rf ~/.cache/tillandsias/opencode/"
L_OPENCODE_INSTALL_FAILED="ERREUR: OpenCode n'a pas pu être installé."
L_BANNER_FORGE="tillandsias forge"
L_BANNER_PROJECT="projet:"
L_BANNER_AGENT="agent:"
L_BANNER_MODE_MAINTENANCE="mode:    maintenance"
L_AGENT_NOT_AVAILABLE="Claude Code indisponible. Lancement de bash."
L_OPENCODE_NOT_AVAILABLE="OpenCode indisponible. Lancement de bash."
L_UNKNOWN_AGENT="Agent inconnu '%s'. Lancement de bash."

# ── Avertissements CA / proxy ──────────────────────────────────
L_WARN_CA_INSTALL="AVERTISSEMENT: Impossible d'installer le certificat CA — le cache HTTPS du proxy peut ne pas fonctionner"
L_WARN_CA_UPDATE="AVERTISSEMENT: Impossible de mettre à jour le magasin de confiance CA"

# ── Messages du miroir git ───────────────────────────────────────
L_WARN_PUSH_URL="AVERTISSEMENT: Impossible de définir l'URL push — git push peut ne pas fonctionner"
L_GIT_CLONE_FAILED="ERREUR: Impossible de cloner le projet depuis le service git."
L_GIT_CLONE_HINT="Le service git peut ne pas être en cours d'exécution. Ouverture du terminal."
L_GIT_EPHEMERAL="Tous les changements doivent être validés (commit) pour persister. Le travail non validé est perdu à l'arrêt."

# ── Avertissements d'authentification / initialisation ───────────
L_WARN_GH_AUTH="AVERTISSEMENT: gh auth setup-git a échoué — git push peut ne pas s'authentifier"
L_WARN_OPENSPEC_INIT="AVERTISSEMENT: L'initialisation d'OpenSpec a échoué — les commandes /opsx peuvent ne pas fonctionner"

# ── Avertissements de sortie du programme d'installation ────────
L_WARN_OPENCODE_EXIT="AVERTISSEMENT: Le programme d'installation d'OpenCode s'est fermé avec le code"
L_WARN_OPENCODE_UPDATE_EXIT="AVERTISSEMENT: La mise à jour d'OpenCode s'est fermée avec le code"

# ── Messages de mise à jour ────────────────────────────────────
L_UPDATING_CLAUDE="Mise à jour de Claude Code..."
L_UPDATING_OPENCODE="Mise à jour d'OpenCode..."

# ── forge-welcome.sh ──────────────────────────────────────────
L_WELCOME_TITLE="🌱 Tillandsias Forge"
L_WELCOME_PROJECT="Projet"
L_WELCOME_FORGE="Forge"
L_WELCOME_MOUNTS="Montages"
L_WELCOME_PROJECT_AT="→ Projet à /home/forge/src/%s"
L_WELCOME_SECURITY="Sécurité"
L_WELCOME_NETWORK="Réseau"
L_WELCOME_NETWORK_DESC="enclave uniquement (pas d'internet, paquets via proxy)"
L_WELCOME_CREDENTIALS="Identifiants"
L_WELCOME_CREDENTIALS_DESC="aucun (authentification git via service miroir)"
L_WELCOME_CODE="Code"
L_WELCOME_CODE_DESC="cloné du miroir git (le travail non validé est éphémère)"
L_WELCOME_SERVICES="Services"
L_WELCOME_PROXY_DESC="proxy HTTP/S en cache (domaines autorisés)"
L_WELCOME_GIT_DESC="miroir git + push automatique vers le distant"
L_WELCOME_INFERENCE_DESC="ollama (LLM local)"

# ── Conseils (rotatifs, affichés à la connexion) ──────────────
L_TIP_1="Tapez help pour en savoir plus sur le shell Fish"
L_TIP_2="Essayez Midnight Commander avec mc"
L_TIP_3="Parcourez les fichiers avec eza --tree"
L_TIP_4="Utilisez Tab pour les suggestions d'autocomplétion"
L_TIP_5="Recherchez dans l'historique avec Ctrl+R"
L_TIP_6="Saut de répertoire intelligent avec z <nom-partiel>"
L_TIP_7="Aperçu des fichiers avec bat <fichier>"
L_TIP_8="Trouvez des fichiers rapidement avec fd <motif>"
L_TIP_9="Recherche floue de n'importe quoi avec fzf"
L_TIP_10="Affichage des processus avec htop"
L_TIP_11="Affichage de l'arborescence des répertoires avec tree"
L_TIP_12="Modifiez les fichiers avec vim ou nano"
L_TIP_13="Fish met en évidence les commandes valides en vert au fur et à mesure de la saisie"
L_TIP_14="Fish suggère à partir de l'historique — appuyez sur → pour accepter"
L_TIP_15="Utilisez .. pour remonter d'un répertoire"
L_TIP_16="Listez les fichiers en détail avec ll"
L_TIP_17="Basculez vers bash n'importe quand: tapez bash"
L_TIP_18="Basculez vers zsh n'importe quand: tapez zsh"
L_TIP_19="Vérifiez l'état de git avec git status"
L_TIP_20="GitHub CLI: gh repo view, gh pr list"

# ── Livres de consulta ──────────────────────────────────────
# Remarque: Le pointeur de livre de consulta est actuellement codé en dur dans forge-welcome.sh
# et n'utilise pas les variables locale. Ceci est conservé pour une future localisation
# si nous rendons la bannière entièrement sensible aux paramètres régionaux.
L_WELCOME_CHEATSHEETS="📚 Livres de consulta"

# ── Messages d'erreur (lib-localized-errors.sh) ──────────────
L_ERROR_CONTAINER_FAILED="ERREUR: Impossible de démarrer le conteneur"
L_ERROR_CONTAINER_HINT="Essayez de redémarrer le conteneur ou consultez les journaux pour plus de détails."

L_ERROR_IMAGE_MISSING="ERREUR: Image de conteneur introuvable"
L_ERROR_IMAGE_HINT="Reconstruisez l'image ou vérifiez qu'elle existe. Vérifiez l'espace disque disponible."

L_ERROR_NETWORK="ERREUR: Erreur réseau"
L_ERROR_NETWORK_HINT="Vérifiez la configuration du proxy (env HTTPS_PROXY) et que les services réseau fonctionnent."

L_ERROR_GIT_CLONE="ERREUR: Échec du clonage git"
L_ERROR_GIT_HINT="Vérifiez les identifiants, les clés SSH, ou redémarrez le service git. Vérifiez la configuration git."

L_ERROR_AUTH="ERREUR: Échec d'authentification"
L_ERROR_AUTH_HINT="Reconfigurer les identifiants avec 'gh auth login' ou vérifier la configuration git."
