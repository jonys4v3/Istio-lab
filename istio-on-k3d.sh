#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Istio en Kubernetes (K3d sobre Docker) - Instalación 1 comando
# Crea un cluster k3d, instala Istio (perfil demo), despliega Bookinfo
# y los add-ons (Kiali, Prometheus, Grafana, Jaeger).
# ------------------------------------------------------------
# Requisitos: Docker en host. El script instalará k3d/kubectl/istioctl si faltan.
# Probado en Linux x86_64. En macOS se recomienda tener Docker Desktop ya instalado.
# ------------------------------------------------------------

# Defaults
CLUSTER_NAME="istio-demo"
AGENTS=2
SERVERS=1
HTTP_PORT=8080
HTTPS_PORT=8443
ISTIO_PROFILE="demo"
SKIP_ADDONS=false

usage() {
  cat <<EOF
Uso: $0 [opciones]

Opciones:
  --cluster-name NOMBRE     Nombre del cluster k3d (por defecto: ${CLUSTER_NAME})
  --agents N                Número de nodos worker (por defecto: ${AGENTS})
  --servers N               Número de nodos server (por defecto: ${SERVERS})
  --http-port P             Puerto host -> 80 del LB (por defecto: ${HTTP_PORT})
  --https-port P            Puerto host -> 443 del LB (por defecto: ${HTTPS_PORT})
  --istio-profile PERFIL    Perfil de Istio (demo|minimal|default) (por defecto: ${ISTIO_PROFILE})
  --skip-addons             No instala Kiali/Prometheus/Grafana/Jaeger
  --delete                  Elimina el cluster y sale
  -h, --help                Muestra esta ayuda

Ejemplos:
  $0
  $0 --cluster-name lab --agents 1 --servers 1 --http-port 8081
  $0 --delete --cluster-name lab
EOF
}

DELETE_MODE=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --agents) AGENTS="$2"; shift 2 ;;
    --servers) SERVERS="$2"; shift 2 ;;
    --http-port) HTTP_PORT="$2"; shift 2 ;;
    --https-port) HTTPS_PORT="$2"; shift 2 ;;
    --istio-profile) ISTIO_PROFILE="$2"; shift 2 ;;
    --skip-addons) SKIP_ADDONS=true; shift 1 ;;
    --delete) DELETE_MODE=true; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[!] Opción no reconocida: $1"; usage; exit 1 ;;
  esac
done

log() { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*"; }
err() { echo -e "\n[ERROR] $*" >&2; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    return 1
  fi
}

# --- Borrado de cluster ---
if [[ "$DELETE_MODE" == true ]]; then
  if require_cmd k3d; then
    log "Eliminando cluster k3d '${CLUSTER_NAME}'..."
    k3d cluster delete "$CLUSTER_NAME" || true
    log "Listo."
  else
    warn "k3d no está instalado; nada que borrar."
  fi
  exit 0
fi

# --- Requisitos: Docker ---
if ! require_cmd docker; then
  err "Docker no está instalado o no está en PATH. Instálalo primero (p.ej., en Ubuntu: 'sudo apt-get install -y docker.io' y 'sudo usermod -aG docker $USER')."
  exit 1
fi

# --- Instalar k3d si falta ---
if ! require_cmd k3d; then
  log "Instalando k3d..."
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi
log "k3d versión: $(k3d version | head -n1)"

# --- Instalar kubectl si falta ---
if ! require_cmd kubectl; then
  log "Instalando kubectl (última estable)..."
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) ARCH_BIN=amd64 ;;
    arm64|aarch64) ARCH_BIN=arm64 ;;
    *) err "Arquitectura no soportada automáticamente: $ARCH"; exit 1 ;;
  esac
  curl -sL "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/$(uname | tr '[:upper:]' '[:lower:]')/${ARCH_BIN}/kubectl" -o kubectl
  chmod +x kubectl
  if require_cmd sudo && sudo -n true 2>/dev/null; then
    sudo mv kubectl /usr/local/bin/
  else
    warn "Sin sudo. Instalando kubectl en ~/.local/bin"
    mkdir -p "$HOME/.local/bin"
    mv kubectl "$HOME/.local/bin/"
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi
log "kubectl versión: $(kubectl version --client --short 2>/dev/null || true)"

# --- Descarga e instala istioctl (temporal o global) ---
if ! require_cmd istioctl; then
  log "Descargando Istio (estable) e instalando istioctl..."
  WORKDIR=$(mktemp -d)
  trap 'rm -rf "$WORKDIR"' EXIT
  pushd "$WORKDIR" >/dev/null
  curl -sL https://istio.io/downloadIstio | sh -
  ISTIO_DIR=$(find . -maxdepth 1 -type d -name "istio-*" | head -n1)
  if [[ -z "$ISTIO_DIR" ]]; then
    err "No se pudo encontrar el directorio de Istio descargado."
    exit 1
  fi
  # Intentar instalar istioctl globalmente
  if require_cmd sudo && sudo -n true 2>/dev/null; then
    sudo cp "$ISTIO_DIR/bin/istioctl" /usr/local/bin/
  else
    warn "Sin sudo. Usaré istioctl desde el directorio temporal durante este script."
    export PATH="$WORKDIR/$ISTIO_DIR/bin:$PATH"
  fi
  popd >/dev/null
fi
log "istioctl versión: $(istioctl version --remote=false 2>/dev/null || true)"

# --- Crear cluster k3d ---
if k3d cluster list | grep -q "^${CLUSTER_NAME}\>"; then
  warn "El cluster '${CLUSTER_NAME}' ya existe. Se reutilizará."
else
  log "Creando cluster k3d '${CLUSTER_NAME}' (servers=${SERVERS}, agents=${AGENTS})..."
  k3d cluster create "$CLUSTER_NAME" \
    --agents "$AGENTS" \
    --servers "$SERVERS" \
    -p "${HTTP_PORT}:80@loadbalancer" \
    -p "${HTTPS_PORT}:443@loadbalancer"
fi

# Seleccionar contexto
kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
log "Nodos del cluster:"
kubectl get nodes -o wide

# --- Instalar Istio control plane ---
log "Instalando Istio (perfil: ${ISTIO_PROFILE})..."
istioctl install --set profile="${ISTIO_PROFILE}" -y

log "Esperando a que los deployments de istio-system estén disponibles..."
kubectl -n istio-system wait --for=condition=Available deployment --all --timeout=10m
kubectl -n istio-system get pods

# --- Preparar namespace de demo ---
if kubectl get ns demo >/dev/null 2>&1; then
  warn "El namespace 'demo' ya existe."
else
  kubectl create namespace demo
fi
kubectl label namespace demo istio-injection=enabled --overwrite

# --- Obtener los manifests de muestra de Istio ---
SAMPLES_DIR=""
if istioctl version --remote=false >/dev/null 2>&1; then
  # Intentar deducir el directorio de samples desde istioctl
  # Truco: descargar de nuevo el tar si no encontramos samples
  if [[ -d "/usr/local/bin" && -x "/usr/local/bin/istioctl" ]]; then
    # No tenemos ruta a samples desde binario
    :
  fi
fi

# Descargamos Istio en un temp para aplicar samples/addons (no afecta si ya existe)
WORKDIR2=$(mktemp -d)
trap 'rm -rf "$WORKDIR2"' EXIT
pushd "$WORKDIR2" >/dev/null
curl -sL https://istio.io/downloadIstio | sh -
ISTIO_DIR2=$(find . -maxdepth 1 -type d -name "istio-*" | head -n1)
if [[ -z "$ISTIO_DIR2" ]]; then
  err "No se pudo obtener el directorio con los samples de Istio."
  exit 1
fi
cd "$ISTIO_DIR2"
export PATH="$PWD/bin:$PATH"

# --- Desplegar Bookinfo ---
log "Desplegando aplicación de ejemplo Bookinfo..."
kubectl apply -n demo -f samples/bookinfo/platform/kube/bookinfo.yaml
kubectl -n demo wait --for=condition=Ready pod -l app=productpage --timeout=10m || true
kubectl -n demo get pods -o wide

log "Aplicando Gateway y DestinationRules..."
kubectl apply -n demo -f samples/bookinfo/networking/bookinfo-gateway.yaml
kubectl apply -n demo -f samples/bookinfo/networking/destination-rule-all.yaml

# --- Addons (opcional) ---
if [[ "$SKIP_ADDONS" == false ]]; then
  log "Instalando add-ons (Kiali, Prometheus, Grafana, Jaeger)..."
  kubectl apply -f samples/addons
  # Esperar Kiali
  kubectl -n istio-system rollout status deploy/kiali --timeout=10m || true
  kubectl -n istio-system get svc,deploy | grep -E 'kiali|prometheus|grafana|jaeger' || true
else
  warn "Omitidos add-ons por --skip-addons"
fi

popd >/dev/null

log "\n✅ Entorno listo"
echo "- Contexto kube: k3d-${CLUSTER_NAME}"
echo "- Istio perfil: ${ISTIO_PROFILE}"
echo "- URL Bookinfo: http://localhost:${HTTP_PORT}/productpage"
if [[ "$SKIP_ADDONS" == false ]]; then
  echo "- Abre Kiali: ejecuta 'istioctl dashboard kiali' (se abre en tu navegador)"
fi

echo "\nComandos útiles:"
echo "  kubectl -n istio-system get pods"
echo "  kubectl -n demo get pods"
echo "  kubectl get svc -n istio-system"
echo "  k3d cluster delete ${CLUSTER_NAME}   # para borrar el cluster"
