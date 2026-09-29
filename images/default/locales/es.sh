#!/usr/bin/env bash
# @trace spec:shell-prompt-localization-fr, spec:shell-prompt-localization-ja
# Tillandsias Forge — paquete de localización en español
# Se importa con source en entrypoint.sh y forge-welcome.sh.
# Traducción por: Tlatoāni (hablante nativo)

# ── entrypoint.sh ────────────────────────────────────────────
L_BANNER_FORGE="tillandsias forge"
L_BANNER_PROJECT="proyecto:"
L_BANNER_AGENT="agente:"

# ── forge-welcome.sh ──────────────────────────────────────────
L_WELCOME_TITLE="🌱 Tillandsias Forge"
L_WELCOME_PROJECT="Proyecto"
L_WELCOME_FORGE="Forge"
L_WELCOME_MOUNTS="Montajes"
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

# ── Cheatsheets ────────────────────────────────────────────
# Note: The cheatsheet pointer is currently hardcoded in forge-welcome.sh
# and does not use locale variables. This is kept for future localization
# if we make the banner fully locale-aware.

# ── Mensajes de error (lib-localized-errors.sh) ──────────────
L_ERROR_CONTAINER_FAILED="ERROR: No se pudo iniciar el contenedor"
L_ERROR_CONTAINER_HINT="Intenta reiniciar el contenedor o revisa los registros para obtener detalles."

L_ERROR_IMAGE_MISSING="ERROR: Imagen de contenedor no encontrada"
L_ERROR_IMAGE_HINT="Reconstruye la imagen o verifica que exista. Verifica el espacio en disco."

L_ERROR_NETWORK="ERROR: Error de red"
L_ERROR_NETWORK_HINT="Verifica la configuración del proxy (env HTTPS_PROXY) y que los servicios de red estén ejecutándose."

L_ERROR_GIT_CLONE="ERROR: No se pudo clonar git"
L_ERROR_GIT_HINT="Verifica credenciales, claves SSH, o reinicia el servicio git. Revisa la configuración de git."

L_ERROR_AUTH="ERROR: Error de autenticación"
L_ERROR_AUTH_HINT="Reconfigura credenciales con 'gh auth login' o revisa la configuración de git."

# ── Agent onboarding ──────────────────────────
L_AGENT_ONBOARDING="🤖 Incorporación de agentes"
L_AGENT_ONBOARDING_HINT="cat $TILLANDSIAS_CHEATSHEETS/welcome/readme-discipline.md para la guía de primer turno"
