#!/usr/bin/env bash
# Tillandsias Forge — paquete de localización en español
# Se importa con source en entrypoint.sh y forge-welcome.sh.
# Traducción por: Tlatoāni (hablante nativo)

# ── entrypoint.sh ────────────────────────────────────────────
L_INSTALLING_OPENCODE="Instalando OpenCode..."
L_INSTALLED_OPENCODE="  OpenCode listo: %s"
L_WARN_OPENCODE="  ADVERTENCIA: El binario de OpenCode existe pero --version no devolvió nada."
L_INSTALLING_CLAUDE="Instalando Claude Code..."
L_INSTALLED_CLAUDE="  Claude Code listo: %s"
L_WARN_CLAUDE="  ADVERTENCIA: El binario de Claude Code existe pero --version no devolvió nada."
L_CLAUDE_NOT_FOUND="  No se encontró el binario de Claude Code después de la instalación."
L_INSTALL_FAILED_CLAUDE="  ERROR: npm install falló. Revisa la salida de arriba para más detalles."
L_INSTALLING_OPENSPEC="Instalando OpenSpec..."
L_INSTALLED_OPENSPEC="  ✓ OpenSpec instalado"
L_OPENSPEC_NOT_FOUND="  ✗ No se encontró el binario de OpenSpec después de la instalación"
L_OPENSPEC_FAILED="  Instalación de OpenSpec fallida (no es crítico, continuando)"
L_RETRY_HINT="Para reintentar: reinicia el contenedor"
L_CLEAR_CACHE_CLAUDE="Para limpiar la caché: rm -rf ~/.cache/tillandsias/claude/"
L_CLEAR_CACHE_OPENCODE="Para limpiar la caché: rm -rf ~/.cache/tillandsias/opencode/"
L_OPENCODE_INSTALL_FAILED="ERROR: No se pudo instalar OpenCode."
L_BANNER_FORGE="tillandsias forge"
L_BANNER_PROJECT="proyecto:"
L_BANNER_AGENT="agente:"
L_BANNER_MODE_MAINTENANCE="modo:    mantenimiento"
L_AGENT_NOT_AVAILABLE="Claude Code no está disponible. Iniciando bash."
L_OPENCODE_NOT_AVAILABLE="OpenCode no está disponible. Iniciando bash."
L_UNKNOWN_AGENT="Agente desconocido '%s'. Iniciando bash."

# ── CA / advertencias de proxy ───────────────────────────────────
L_WARN_CA_INSTALL="ADVERTENCIA: No se pudo instalar el certificado CA — el caché HTTPS del proxy podría no funcionar"
L_WARN_CA_UPDATE="ADVERTENCIA: No se pudo actualizar el almacén de confianza CA"

# ── Mensajes del espejo git ──────────────────────────────────────
L_WARN_PUSH_URL="ADVERTENCIA: No se pudo configurar la URL de push — git push podría no funcionar"
L_GIT_CLONE_FAILED="ERROR: No se pudo clonar el proyecto desde el servicio git."
L_GIT_CLONE_HINT="El servicio git podría no estar ejecutándose. Abriendo terminal."
L_GIT_EPHEMERAL="Todos los cambios deben ser confirmados (commit) para persistir. El trabajo no confirmado se pierde al detener."

# ── Advertencias de autenticación / inicialización ───────────────
L_WARN_GH_AUTH="ADVERTENCIA: gh auth setup-git falló — git push podría no autenticarse"
L_WARN_OPENSPEC_INIT="ADVERTENCIA: La inicialización de OpenSpec falló — los comandos /opsx podrían no funcionar"

# ── Advertencias de salida del instalador ────────────────────────
L_WARN_OPENCODE_EXIT="ADVERTENCIA: El instalador de OpenCode terminó con código"
L_WARN_OPENCODE_UPDATE_EXIT="ADVERTENCIA: La actualización de OpenCode terminó con código"

# ── Mensajes de actualización ────────────────────────────────────
L_UPDATING_CLAUDE="Actualizando Claude Code..."
L_UPDATING_OPENCODE="Actualizando OpenCode..."

# ── forge-welcome.sh ──────────────────────────────────────────
L_WELCOME_TITLE="🌱 Tillandsias Forge"
L_WELCOME_PROJECT="Proyecto"
L_WELCOME_FORGE="Forge"
L_WELCOME_MOUNTS="Montajes"
L_WELCOME_PROJECT_AT="→ Proyecto en /home/forge/src/%s"
L_WELCOME_SECURITY="Seguridad"
L_WELCOME_NETWORK="Red"
L_WELCOME_NETWORK_DESC="solo enclave (sin internet, paquetes vía proxy)"
L_WELCOME_CREDENTIALS="Credenciales"
L_WELCOME_CREDENTIALS_DESC="ninguna (autenticación git vía servicio espejo)"
L_WELCOME_CODE="Código"
L_WELCOME_CODE_DESC="clonado del espejo git (el trabajo no confirmado es efímero)"
L_WELCOME_SERVICES="Servicios"
L_WELCOME_PROXY_DESC="proxy HTTP/S con caché (dominios permitidos)"
L_WELCOME_GIT_DESC="espejo git + push automático al remoto"
L_WELCOME_INFERENCE_DESC="ollama (LLM local)"

# ── Tips (rotatorios, mostrados al iniciar sesión) ────────────
L_TIP_1="Escribe help para aprender sobre el shell Fish"
L_TIP_2="Prueba Midnight Commander con mc"
L_TIP_3="Explora archivos con eza --tree"
L_TIP_4="Usa Tab para sugerencias de autocompletado"
L_TIP_5="Busca en el historial con Ctrl+R"
L_TIP_6="Salto de directorio inteligente con z <nombre-parcial>"
L_TIP_7="Vista previa de archivos con bat <archivo>"
L_TIP_8="Encuentra archivos rápido con fd <patrón>"
L_TIP_9="Búsqueda difusa de cualquier cosa con fzf"
L_TIP_10="Ver procesos con htop"
L_TIP_11="Muestra el árbol de directorios con tree"
L_TIP_12="Edita archivos con vim o nano"
L_TIP_13="Fish resalta comandos válidos en verde mientras escribes"
L_TIP_14="Fish sugiere del historial — presiona → para aceptar"
L_TIP_15="Usa .. para subir un directorio"
L_TIP_16="Lista archivos en detalle con ll"
L_TIP_17="Cambia a bash en cualquier momento: escribe bash"
L_TIP_18="Cambia a zsh en cualquier momento: escribe zsh"
L_TIP_19="Revisa el estado de git con git status"
L_TIP_20="GitHub CLI: gh repo view, gh pr list"
