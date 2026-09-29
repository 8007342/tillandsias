#!/usr/bin/env bash
# @trace spec:help-system-localization
# help-es.sh — Sistema de ayuda de Tillandsias Forge
# Versión en español

cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                   Ayuda de Tillandsias Forge                   ║
╚════════════════════════════════════════════════════════════════╝

CONSEJOS RÁPIDOS
────────────────
• Escribe `help` para ver este mensaje de nuevo
• Usa Fish atajos de teclado: Tab para autocompletar, Ctrl+R para buscar en historial
• Vista previa de archivos con: bat <archivo>
• Explora directorios con: eza --tree
• Búsqueda difusa con: fzf

AGENTES Y DESARROLLO
────────────────────
Claude Code:
  • Inicia con: /claude (o simplemente 'claude')
  • Ejecuta: /opsx (comandos OpenSpec)
  • Chat: Pide revisión de código, genera boilerplate, depura

OpenCode:
  • Inicia con: /opencode (o 'opencode')
  • Edita código eficientemente con sugerencias inteligentes
  • Ejecuta: opencode <comando> (ej: opencode run)

Operaciones Git
  • Clonar: git clone <repo>
  • Commit: git add . && git commit -m "mensaje"
  • Push: git push origin <rama>
  • Estado: git status
  • GitHub CLI: gh repo view, gh pr list, gh issue create

CONTENEDOR Y ENTORNO
────────────────────
Proyecto Actual: ${TILLANDSIAS_PROJECT:-desconocido}
Directorio del Proyecto: /home/forge/src/<proyecto>
Red: Solo enclave (sin internet)
Credenciales: Ninguna en el contenedor (auth git vía servicio espejo)

Cambios de Código:
  ✓ Todo trabajo no confirmado es EFÍMERO (se pierde al detener)
  ✓ Confirma cambios para persistir: git commit
  ✓ Push para actualizar remoto: git push

SOLUCIÓN DE PROBLEMAS
─────────────────────
Problema: Comando no encontrado
  → Verifica si está instalado: which <comando>
  → Lista comandos: ls -la /usr/local/bin/

Problema: Git push falla
  → Verifica configuración: git config -l
  → Reinicia servicio git: reconecta al contenedor
  → Verifica credenciales: gh auth status

Problema: npm/cargo/pip install falla
  → Paquetes usan proxy: verifica env var HTTPS_PROXY
  → Limpia cache: rm -rf ~/.cache/tillandsias/<herramienta>/
  → Reintentar: npm install

Problema: Permiso denegado
  → Verifica tu usuario: whoami
  → Propiedad de archivo: ls -l <archivo>
  → Hazlo ejecutable: chmod +x <archivo>

COMANDOS ÚTILES
───────────────
Navegación de Archivos:
  eza <dir>          Lista archivos (elegante)
  eza --tree         Vista de árbol
  tree               Árbol de directorios
  cd /home/forge/src Ir a raíz del proyecto

Procesamiento de Texto:
  bat <archivo>      Vista previa con sintaxis
  rg <patrón>        Ripgrep (búsqueda rápida)
  fd <patrón>        Busca archivos por patrón
  fzf                Buscador difuso

Información del Sistema:
  df -h              Uso de disco
  du -sh <dir>       Tamaño de directorio
  ps aux             Procesos ejecutándose
  htop               Visor interactivo
  top                Monitor CPU/memoria

DOCUMENTACIÓN
──────────────
Libros de Consulta:
  ls /opt/cheatsheets/        Explora libros disponibles
  cat /opt/cheatsheets/INDEX.md

Aprende el Shell:
  man <comando>      Páginas manuales
  help <builtin>     Ayuda de builtins bash
  type <comando>     Muestra tipo de comando

¿Necesitas más ayuda?
  • Escribe: /claude (pregunta a Claude Code)
  • Explora: /opt/cheatsheets/
  • Verifica: git log --oneline (commits recientes)

═══════════════════════════════════════════════════════════════════
Escribe q para salir o un comando para continuar.
EOF
