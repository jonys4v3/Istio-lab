#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Istio + K3d + Docker Desktop (WSL2 compatible) - Multicluster
# - Crea 1 o 2 clusters k3d (por defecto 2 si --multicluster)
# - Instala Istio (perfil configurable) en cada cluster
# - Configura Multi-Primary en redes diferentes (east-west gateways)
# - Crea remote-secrets y MeshNetworks para descubrimiento cross-cluster
# - Despliega Bookinfo (en cluster1 por defecto) y add-ons opcionales
# ------------------------------------------------------------
# Requisitos:
#   - Docker Desktop (backend WSL2) en Windows y abierto
#   - WSL2 Ubuntu (o Linux nativo) con acceso al daemon de Docker
#   - Este script instala k3d/kubectl/istioctl en ~/.local/bin si faltan
# ------------------------------------------------------------

# Defaults
CLUSTER1_NAME="cluster1"
CLUSTER2_NAME="cluster2"
NETWORK1="network1"
NETWORK2="network2"
MULTICLUSTER=false
CLUSTERS=1
HTTP1=8080
HTTPS1=8443
HTTP2=9080
HTTPS2=9443
ISTIO_PROFILE="demo"
SKIP_ADDONS=false
SHARED_DOCKER_NET="k3d-mc-net"
INSTALL_BOOKINFO_CLUSTER="cluster1"  # dónde desplegar Bookinfo

usage() {
  cat <<EOF
Uso: $0 [opciones]

Opciones:
  --multicluster              Activa despliegue multicluster (2 clusters)
  --clusters N                Número de clusters (1 o 2). Si usas --multicluster, N se fuerza a 2
  --cluster1-name NAME        Nombre cluster 1 (por defecto: ${CLUSTER1_NAME})
  --cluster2-name NAME        Nombre cluster 2 (por defecto: ${CLUSTER2_NAME})
  --network1 NAME             Nombre lógico de red Istio para cluster1 (por defecto: ${NETWORK1})
  --network2 NAME             Nombre lógico de red Istio para cluster2 (por defecto: ${NETWORK2})
  --http1 PORT                Puerto host para HTTP del LB cluster1 (por defecto: ${HTTP1})
  --https1 PORT               Puerto host para HTTPS del LB cluster1 (por defecto: ${HTTPS1})
  --http2 PORT                Puerto host para HTTP del LB cluster2 (por defecto: ${HTTP2})
  --https2 PORT               Puerto host para HTTPS del LB cluster2 (por defecto: ${HTTPS2})
  --istio-profile PERFIL      Perfil de Istio (demo|minimal|default) (por defecto: ${ISTIO_PROFILE})
  --skip-addons               No instala Kiali/Prometheus/Grafana/Jaeger
  --bookinfo-on NAME          cluster destino para Bookinfo (cluster1|cluster2). Por defecto: ${INSTALL_BOOKINFO_CLUSTER}
  --delete                    Elimina los clusters creados y sale
  -h, --help                  Muestra esta ayuda

Ejemplos:
  # Single cluster (por defecto)
  $0

  # Multicluster (2 clusters), Bookinfo en cluster1
  $0 --multicluster

  # Multicluster con puertos personalizados
  $0 --multicluster --http1 8081 --http2 9081
EOF
}

DELETE_MODE=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --multicluster) MULTICLUSTER=true; CLUSTERS=2; shift ;;
    --clusters) CLUSTERS="$2"; shift 2 ;;
    --cluster1-name) CLUSTER1_NAME="$2"; shift 2 ;;
    --cluster2-name) CLUSTER2_NAME="$2"; shift 2 ;;
    --network1) NETWORK1="$2"; shift 2 ;;
    --network2) NETWORK2="$2"; shift 2 ;;
    --http1) HTTP1="$2"; shift 2 ;;
    --https1) HTTPS1="$2"; shift 2 ;;
    --http2) HTTP2="$2"; shift 2 ;;
    --https2) HTTPS2="$2"; shift 2 ;;
    --istio-profile) ISTIO_PROFILE="$2"; shift 2 ;;
    --skip-addons) SKIP_ADDONS=true; shift ;;
    --bookinfo-on) INSTALL_BOOKINFO_CLUSTER="$2"; shift 2 ;;
    --delete) DELETE_MODE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[!] Opción no reconocida: $1"; usage; exit 1 ;;
  esac
done

if [[ "$MULTICLUSTER" == true ]]; then
  CLUSTERS=2
fi

log() { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*"; }
err() { echo -e "\n[ERROR] $*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1; }

is_wsl() { grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }

# --- Borrado de clusters ---
if [[ "$DELETE_MODE" == true ]]; then
  if require_cmd k3d; then
    log "Eliminando clusters..."
    k3d cluster delete "$CLUSTER1_NAME" || true
    if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER2_NAME}\>"; then
      k3d cluster delete "$CLUSTER2_NAME" || true
    fi
    # No borramos la red compartida (puede usarse por otros labs)
    log "Listo."
  else
    warn "k3d no está instalado; nada que borrar."
  fi
  exit 0
fi

# --- Requisitos Docker ---
if ! require_cmd docker; then
  err "Docker no está en PATH. En WSL2, activa Docker Desktop (WSL2 backend) e integra tu distro."
  exit 1
fi
if ! docker version >/dev/null 2>&1; then
  err "No se puede conectar al daemon de Docker. Abre Docker Desktop y reintenta."
  exit 1
fi
if is_wsl; then
  warn "WSL2 detectado. Asegúrate de tener Docker Desktop en ejecución y WSL integration habilitada."
  CURR=$(pwd)
  if [[ "$CURR" == /mnt/* ]]; then
    warn "Estás en $CURR. Para mejor rendimiento, ejecuta desde tu home WSL (~)."
  fi
fi

# --- Instalar herramientas si faltan ---
if ! require_cmd k3d; then
  log "Instalando k3d..."
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi
if ! require_cmd kubectl; then
  log "Instalando kubectl (última estable)..."
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) ARCH_BIN=amd64 ;;
    arm64|aarch64) ARCH_BIN=arm64 ;;
    *) err "Arquitectura no soportada: $ARCH"; exit 1 ;;
  esac
  curl -sL "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/$(uname | tr '[:upper:]' '[:lower:]')/${ARCH_BIN}/kubectl" -o kubectl
  chmod +x kubectl
  mkdir -p "$HOME/.local/bin" && mv kubectl "$HOME/.local/bin/"
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! require_cmd istioctl; then
  log "Descargando Istio (estable) e instalando istioctl..."
  WORKDIR=$(mktemp -d)
  trap 'rm -rf "$WORKDIR"' EXIT
  pushd "$WORKDIR" >/dev/null
  curl -sL https://istio.io/downloadIstio | sh -
  ISTIO_DIR=$(find . -maxdepth 1 -type d -name "istio-*" | head -n1)
  if [[ -z "$ISTIO_DIR" ]]; then
    err "No se encontró el directorio de Istio."
    exit 1
  fi
  mkdir -p "$HOME/.local/bin" && cp "$ISTIO_DIR/bin/istioctl" "$HOME/.local/bin/"
  export PATH="$HOME/.local/bin:$PATH"
  popd >/dev/null
fi

log "k3d: $(k3d version | head -n1)"
log "kubectl: $(kubectl version --client --short 2>/dev/null || true)"
log "istioctl: $(istioctl version --remote=false 2>/dev/null || true)"

# --- Red Docker compartida para multicluster ---
if [[ "$CLUSTERS" -eq 2 ]]; then
  if ! docker network inspect "$SHARED_DOCKER_NET" >/dev/null 2>&1; then
    log "Creando red Docker compartida: ${SHARED_DOCKER_NET}"
    docker network create "$SHARED_DOCKER_NET"
  else
    warn "Red Docker compartida '${SHARED_DOCKER_NET}' ya existe."
  fi
fi

# --- Crear cluster1 ---
if k3d cluster list | grep -q "^${CLUSTER1_NAME}\>"; then
  warn "El cluster '${CLUSTER1_NAME}' ya existe."
else
  log "Creando cluster '${CLUSTER1_NAME}'..."
  if [[ "$CLUSTERS" -eq 2 ]]; then
    k3d cluster create "$CLUSTER1_NAME" \
      --agents 2 --servers 1 \
      --network "$SHARED_DOCKER_NET" \
      -p "${HTTP1}:80@loadbalancer" \
      -p "${HTTPS1}:443@loadbalancer"
  else
    k3d cluster create "$CLUSTER1_NAME" \
      --agents 2 --servers 1 \
      -p "${HTTP1}:80@loadbalancer" \
      -p "${HTTPS1}:443@loadbalancer"
  fi
fi

# --- Crear cluster2 si procede ---
if [[ "$CLUSTERS" -eq 2 ]]; then
  if k3d cluster list | grep -q "^${CLUSTER2_NAME}\>"; then
    warn "El cluster '${CLUSTER2_NAME}' ya existe."
  else
    log "Creando cluster '${CLUSTER2_NAME}'..."
    k3d cluster create "$CLUSTER2_NAME" \
      --agents 2 --servers 1 \
      --network "$SHARED_DOCKER_NET" \
      -p "${HTTP2}:80@loadbalancer" \
      -p "${HTTPS2}:443@loadbalancer"
  fi
fi

CTX1="k3d-${CLUSTER1_NAME}"
CTX2="k3d-${CLUSTER2_NAME}"

# --- Instalar Istio en cluster1 ---
log "Instalando Istio en ${CLUSTER1_NAME} (perfil=${ISTIO_PROFILE})..."
kubectl config use-context "$CTX1" >/dev/null
istioctl install -y \
  --set profile="${ISTIO_PROFILE}" \
  --set values.global.multiCluster.clusterName="${CLUSTER1_NAME}" \
  --set values.global.network="${NETWORK1}"

kubectl -n istio-system wait --for=condition=Available deployment --all --timeout=10m

# --- Instalar Istio en cluster2 si multicluster ---
if [[ "$CLUSTERS" -eq 2 ]]; then
  log "Instalando Istio en ${CLUSTER2_NAME} (perfil=${ISTIO_PROFILE})..."
  kubectl config use-context "$CTX2" >/dev/null
  istioctl install -y \
    --set profile="${ISTIO_PROFILE}" \
    --set values.global.multiCluster.clusterName="${CLUSTER2_NAME}" \
    --set values.global.network="${NETWORK2}"
  kubectl -n istio-system wait --for=condition=Available deployment --all --timeout=10m
fi

# --- Preparar namespaces demo ---
for CTX in "$CTX1" "$CTX2"; do
  if kubectl --context "$CTX" get ns demo >/dev/null 2>&1; then
    :
  else
    kubectl --context "$CTX" create namespace demo
  fi
  kubectl --context "$CTX" label namespace demo istio-injection=enabled --overwrite
  # Etiqueta de red a nivel de namespace/control-plane (opcional pero útil)
  kubectl --context "$CTX" label namespace istio-system topology.istio.io/network="${NETWORK1}" --overwrite || true
  # Nota: Para CTX2, se sobreescribirá a NETWORK2 más abajo si existe
  if [[ "$CTX" == "$CTX2" ]]; then
    kubectl --context "$CTX" label namespace istio-system topology.istio.io/network="${NETWORK2}" --overwrite || true
  fi
done

# --- Descargar samples Istio una vez para usar generadores ---
TMPDL=$(mktemp -d)
trap 'rm -rf "$TMPDL"' EXIT
pushd "$TMPDL" >/dev/null
curl -sL https://istio.io/downloadIstio | sh -
ISTIO_S_DIR=$(find . -maxdepth 1 -type d -name "istio-*" | head -n1)
if [[ -z "$ISTIO_S_DIR" ]]; then
  err "No se pudo obtener el directorio con los samples de Istio."
  exit 1
fi
cd "$ISTIO_S_DIR"

# --- Multicluster wiring ---
if [[ "$CLUSTERS" -eq 2 ]]; then
  log "Configurando east-west gateway en ambos clusters..."

  # Generar manifiesto gateway para cluster1
  pushd samples/multicluster >/dev/null
  export CLUSTER=${CLUSTER1_NAME}
  export NETWORK=${NETWORK1}
  ./gen-eastwest-gateway.sh --mesh-network "$NETWORK" > /tmp/eastwest-${CLUSTER1_NAME}.yaml
  kubectl --context "$CTX1" -n istio-system apply -f /tmp/eastwest-${CLUSTER1_NAME}.yaml
  kubectl --context "$CTX1" -n istio-system rollout status deploy/istio-eastwestgateway --timeout=10m || true

  # Generar manifiesto gateway para cluster2
  export CLUSTER=${CLUSTER2_NAME}
  export NETWORK=${NETWORK2}
  ./gen-eastwest-gateway.sh --mesh-network "$NETWORK" > /tmp/eastwest-${CLUSTER2_NAME}.yaml
  kubectl --context "$CTX2" -n istio-system apply -f /tmp/eastwest-${CLUSTER2_NAME}.yaml
  kubectl --context "$CTX2" -n istio-system rollout status deploy/istio-eastwestgateway --timeout=10m || true

  # Exponer istiod para descubrimiento entre clusters
  kubectl --context "$CTX1" -n istio-system apply -f expose-istiod.yaml || true
  kubectl --context "$CTX2" -n istio-system apply -f expose-istiod.yaml || true
  popd >/dev/null

  log "Creando remote-secrets..."
  istioctl x create-remote-secret --context "$CTX2" --name "$CLUSTER2_NAME" | kubectl --context "$CTX1" apply -f -
  istioctl x create-remote-secret --context "$CTX1" --name "$CLUSTER1_NAME" | kubectl --context "$CTX2" apply -f -

  log "Obteniendo direcciones de east-west gateways..."
  EW1=$(kubectl --context "$CTX1" -n istio-system get svc istio-eastwestgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}')
  EW2=$(kubectl --context "$CTX2" -n istio-system get svc istio-eastwestgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}')
  if [[ -z "$EW1" || -z "$EW2" ]]; then
    warn "No se logró resolver IP/hostname de eastwest gateways. Continuaré, pero MeshNetworks puede requerir edición manual."
  fi

  cat >/tmp/meshnetworks.yaml <<YAML
apiVersion: networking.istio.io/v1alpha1
kind: MeshNetworks
networks:
  ${NETWORK1}:
    endpoints:
    - fromRegistry: ${CLUSTER1_NAME}
    gateways:
    - address: ${EW1}
      port: 15443
  ${NETWORK2}:
    endpoints:
    - fromRegistry: ${CLUSTER2_NAME}
    gateways:
    - address: ${EW2}
      port: 15443
YAML

  # Aplicar MeshNetworks en ambos clusters
  kubectl --context "$CTX1" apply -f /tmp/meshnetworks.yaml || true
  kubectl --context "$CTX2" apply -f /tmp/meshnetworks.yaml || true
fi

# --- Despliegue de Bookinfo ---
TARGET_CTX="$CTX1"
if [[ "$INSTALL_BOOKINFO_CLUSTER" == "$CLUSTER2_NAME" ]]; then
  TARGET_CTX="$CTX2"
fi

log "Desplegando Bookinfo en ${INSTALL_BOOKINFO_CLUSTER}..."
kubectl --context "$TARGET_CTX" apply -n demo -f samples/bookinfo/platform/kube/bookinfo.yaml
kubectl --context "$TARGET_CTX" -n demo wait --for=condition=Ready pod -l app=productpage --timeout=10m || true
kubectl --context "$TARGET_CTX" -n demo apply -f samples/bookinfo/networking/bookinfo-gateway.yaml
kubectl --context "$TARGET_CTX" -n demo apply -f samples/bookinfo/networking/destination-rule-all.yaml

# --- Addons ---
if [[ "$SKIP_ADDONS" == false ]]; then
  log "Instalando add-ons en ${CLUSTER1_NAME} (puedes replicar en el otro si quieres)..."
  kubectl --context "$CTX1" apply -f samples/addons
  kubectl --context "$CTX1" -n istio-system rollout status deploy/kiali --timeout=10m || true
fi

popd >/dev/null

# --- Output final ---
log "\n✅ Entorno listo"
if [[ "$CLUSTERS" -eq 1 ]]; then
  echo "- Cluster: ${CLUSTER1_NAME} (contexto: ${CTX1})"
  echo "- URL Bookinfo: http://localhost:${HTTP1}/productpage"
else
  echo "- Clusters:"
  echo "    * ${CLUSTER1_NAME} (ctx: ${CTX1})  Ingress: http://localhost:${HTTP1}"
  echo "    * ${CLUSTER2_NAME} (ctx: ${CTX2})  Ingress: http://localhost:${HTTP2}"
  echo "- Redes Istio: ${NETWORK1} ↔ ${NETWORK2} (east-west gateways configurados)"
  echo "- Bookinfo desplegado en: ${INSTALL_BOOKINFO_CLUSTER}"
fi
if [[ "$SKIP_ADDONS" == false ]]; then
  echo "- Kiali: 'istioctl dashboard kiali' (se abrirá en el navegador)"
fi

echo "\nComandos útiles:"
echo "  kubectl --context ${CTX1} -n istio-system get pods"
echo "  kubectl --context ${CTX2} -n istio-system get pods   # si hay 2 clusters"
echo "  kubectl --context ${TARGET_CTX} -n demo get pods"
echo "  k3d cluster delete ${CLUSTER1_NAME}  && k3d cluster delete ${CLUSTER2_NAME}  # limpieza"
