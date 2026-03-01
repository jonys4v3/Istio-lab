#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Limpieza total de laboratorio Istio + K3d (WSL2/Linux)
# - Elimina clusters k3d (cluster1/cluster2 por defecto y cualquiera que empiece por 'k3d-')
# - Borra contextos y entradas kubeconfig asociadas
# - Elimina la red docker compartida (k3d-mc-net) si está vacía
# - Opcional (--nuke): elimina contenedores, redes, volúmenes e imágenes "k3d/*"
# ------------------------------------------------------------

# Ajusta aquí si usaste otros nombres en tus scripts:
CLUSTER1_NAME="${CLUSTER1_NAME:-cluster1}"
CLUSTER2_NAME="${CLUSTER2_NAME:-cluster2}"
SHARED_DOCKER_NET="${SHARED_DOCKER_NET:-k3d-mc-net}"

# Docker CLI (permitir sudo si hace falta)
: "${DOCKER_CMD:=docker}"
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

if ! cmd_exists "${DOCKER_CMD%% *}"; then
  if cmd_exists sudo; then
    DOCKER_CMD="sudo docker"
  fi
fi

NUKE=false
FORCE=false

usage() {
  cat <<EOF
Uso: $0 [opciones]

Opciones:
  --nuke     Borra también contenedores, volúmenes e imágenes relacionadas (k3d/*, rancher/k3s, istio/*, grafana/prometheus/jaeger si deseas)
  --force    No pide confirmación
  -h, --help Muestra esta ayuda

Ejemplos:
  $0
  $0 --nuke --force
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nuke) NUKE=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[!] Opción no reconocida: $1"; usage; exit 1 ;;
  esac
done

confirm() {
  if [[ "$FORCE" == true ]]; then return 0; fi
  read -rp "¿Continuar? [y/N]: " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]]
}

log()  { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*"; }
err()  { echo -e "\n[ERROR] $*" >&2; }

# 0) Información preliminar
log "Preparando limpieza de K3d + Istio..."
if ! cmd_exists k3d; then
  warn "k3d no está instalado; se omitirá la parte de k3d."
fi
if ! cmd_exists kubectl; then
  warn "kubectl no está instalado; se omitirá la limpieza de kubeconfig."
fi

# 1) Mostrar qué se va a borrar
log "Se intentará borrar:
- Clusters k3d: ${CLUSTER1_NAME}, ${CLUSTER2_NAME} (si existen)
- Cualquier cluster adicional 'k3d-*' (opcional)
- Contextos kube 'k3d-*' asociados
- Red Docker '${SHARED_DOCKER_NET}' (si existe y queda sin uso)
- Recursos Istio/Bookinfo en 'istio-system' y 'demo' (si existieran)"

if ! confirm; then
  echo "Cancelado."
  exit 0
fi

# 2) Borrar clusters específicos (si existen)
if cmd_exists k3d; then
  for C in "$CLUSTER1_NAME" "$CLUSTER2_NAME"; do
    if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$C"; then
      log "Eliminando cluster k3d '${C}'..."
      k3d cluster delete "$C" || true
    else
      warn "Cluster '${C}' no existe; se omite."
    fi
  done

  # 2.1) Extra: eliminar cualquier otro cluster k3d-* si quieres
  # Descomenta si deseas eliminar TODOS:
  # for C in $(k3d cluster list 2>/dev/null | awk 'NR>1{print $1}'); do
  #   log "Eliminando cluster adicional k3d '${C}'..."
  #   k3d cluster delete "$C" || true
  # done
fi

# 3) Limpiar kubeconfig (contextos y clusters 'k3d-*')
if cmd_exists kubectl; then
  log "Limpiando contextos 'k3d-*' de kubeconfig (si existen)..."
  # contextos
  for CTX in $(kubectl config get-contexts -o name 2>/dev/null | grep -E '^k3d-'); do
    log " - Borrando contexto: $CTX"
    kubectl config delete-context "$CTX" || true
  done
  # clusters
  for CLU in $(kubectl config get-clusters 2>/dev/null | grep -E '^k3d-'); do
    log " - Borrando cluster en kubeconfig: $CLU"
    kubectl config delete-cluster "$CLU" || true
  done
  # usuarios
  for USR in $(kubectl config get-users 2>/dev/null | grep -E '^k3d-'); do
    log " - Borrando credencial de usuario: $USR"
    kubectl config unset "users.${USR}" || true
  done
fi

# 4) Borrar namespaces de demo/istio (si quedaron en otro cluster activo)
# Aviso: Sólo si tu contexto actual apunta a algo local distinto. Si no hay cluster, no hará nada.
if cmd_exists kubectl; then
  warn "Intentando borrar namespaces 'demo' e 'istio-system' en el contexto actual (si existen)..."
  kubectl delete ns demo --ignore-not-found=true || true
  kubectl delete ns istio-system --ignore-not-found=true || true
fi

# 5) Red Docker compartida (si queda y no la usa nadie)
if cmd_exists "${DOCKER_CMD%% *}"; then
  if $DOCKER_CMD network inspect "$SHARED_DOCKER_NET" >/dev/null 2>&1; then
    # Si ya no hay contenedores conectados, la borra
    ATTACHED="$($DOCKER_CMD network inspect "$SHARED_DOCKER_NET" -f '{{json .Containers}}' 2>/dev/null || echo '{}')"
    if [[ "$ATTACHED" == "null" || "$ATTACHED" == "{}" ]]; then
      log "Eliminando red Docker compartida '${SHARED_DOCKER_NET}'..."
      $DOCKER_CMD network rm "$SHARED_DOCKER_NET" || true
    else
      warn "La red '${SHARED_DOCKER_NET}' aún tiene contenedores adjuntos; no se elimina."
    fi
  else
    warn "La red '${SHARED_DOCKER_NET}' no existe; se omite."
  fi
fi

# 6) Limpieza opcional agresiva (--nuke)
if [[ "$NUKE" == true ]]; then
  log "Modo --nuke: borrado de contenedores/volúmenes/imágenes relacionados con k3d/k3s/istio."

  # Contenedores detenidos con etiqueta típica de k3d
  $DOCKER_CMD ps -a --filter "label=app=k3d" -q | xargs -r $DOCKER_CMD rm -f || true

  # Volúmenes k3d
  $DOCKER_CMD volume ls --filter "name=k3d" -q | xargs -r $DOCKER_CMD volume rm || true

  # Imágenes comunes de lab (ajusta si quieres conservar)
  # Rancher k3s, k3d tools, istio, grafana/prometheus/jaeger
  $DOCKER_CMD images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | awk '
    $1 ~ /^(rancher\/|docker\.io\/rancher\/)?k3s/ ||
    $1 ~ /^ghcr\.io\/k3d-io\/k3d-tools/ ||
    $1 ~ /^istio\/|^gcr\.io\/istio-release\// ||
    $1 ~ /^grafana\/|^prom\/|^jaegertracing\//
  { print $2 }' | xargs -r $DOCKER_CMD rmi -f || true
fi

# 7) Carpeta local (kube/k3d) — opcional
# OJO: sólo borra ficheros locales de cliente, no recursos del cluster (ya borrados arriba)
log "Limpieza de carpetas locales (opcional)…"
rm -rf ~/.k3d 2>/dev/null || true
# Si quieres resetear kubeconfig (¡cuidado!):
# rm -rf ~/.kube 2>/dev/null || true

log "✅ Limpieza completada."
echo "Ahora puedes volver a ejecutar tu script de instalación."
