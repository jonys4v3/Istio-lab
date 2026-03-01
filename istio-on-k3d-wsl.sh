#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Istio en Kubernetes (K3d sobre Docker) - WSL2 Friendly
# Crea un cluster k3d, instala Istio (perfil demo), despliega Bookinfo
# y, opcionalmente, los add-ons (Kiali, Prometheus, Grafana, Jaeger).
# Probado en WSL2 (Ubuntu) + Docker Desktop (WSL2 backend) y Linux nativo.
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
  command -v "$1" >/dev/null 2>&1
}

is_wsl() {
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
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

# --- Requisitos Docker ---
if ! require_cmd docker; then
  err "Docker no está en PATH. En WSL2, asegúrate de tener Docker Desktop con backend WSL2 activo y 'Expose daemon to WSL' habilitado. Luego abre una nueva terminal WSL."
  exit 1
fi

# Consejos específicos WSL2
if is_wsl; then
  warn "WSL2 detectado. Asegúrate de:
   - Docker Desktop en Windows en ejecución (backend WSL2).
   - Settings > Resources > WSL integration: habilitado para esta distro.
   - Settings > General: 'Use the WSL 2 based engine' activado."
fi

# Verificar conectividad al daemon de Docker
if ! docker version >/dev/null 2>&1; then
  err "No se puede conectar al daemon de Docker. Abre Docker Desktop en Windows y reintenta."
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
  # En WSL evitamos sudo si no está configurado; instalamos en ~/.local/bin
  mkdir -p "$HOME/.local/bin"
  mv kubectl "$HOME/.local/bin/"
  export PATH="$HOME/.local/bin:$PATH"
fi
log "kubectl versión: $(kubectl version --client --short 2>/dev/null || true)"

# --- Instalar istioctl si falta ---
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
  mkdir -p "$HOME/.local/bin"
  cp "$ISTIO_DIR/bin/istioctl" "$HOME/.local/bin/"
  export PATH="$HOME/.local/bin:$PATH"
  popd >/dev/null
fi
log "istioctl versión: $(istioctl version --remote=false 2>/dev/null || true)"

# --- Rendimiento WSL2: evitar /mnt/c y usar filesystem de la distro ---
if is_wsl; then
  CURR=$(pwd)
  if [[ "$CURR" == /mnt/* ]]; then
    warn "Estás ejecutando desde $CURR (filesystem de Windows). Para mejor rendimiento, copia el script a tu home WSL (~) y ejecútalo allí."
  fi
fi

# --- Crear cluster k3d ---
if k3d cluster list | grep -q "^${CLUSTER_NAME}\>"; then
  warn "El cluster '${CLUSTER_NAME}' ya existe. Se reutilizará."
else
  log "Creando cluster k3d '${CLUSTER_NAME}' (servers=${SERVERS}, agents=${AGENTS})..."
  # En Docker Desktop/WSL2 el LB mapea puertos al localhost del host Windows y también accesibles desde WSL
  k3d cluster create "$CLUSTER_NAME" \
    --agents "$AGENTS" \
    --servers "$SERVERS" \
    -p "${HTTP_PORT}:80@loadbalancer" \
    -p "${HTTPS_PORT}:443@loadbalancer"
fi

# Seleccionar contexto kubeconfig que k3d gestiona automáticamente
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

# --- Descargar manifests de ejemplo (otra vez, sólo para samples) ---
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
  echo "- Kiali: ejecuta 'istioctl dashboard kiali' (se abre en tu navegador)"
fi

echo "\nComandos útiles:"
echo "  kubectl -n istio-system get pods"
echo "  kubectl -n demo get pods"
echo "  kubectl get svc -n istio-system"
echo "  k3d cluster delete ${CLUSTER_NAME}   # para borrar el cluster"
