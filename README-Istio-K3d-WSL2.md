# Laboratorio Istio sobre K3d (Docker/WSL2) — Guía completa

Este documento describe **qué hacen los scripts**, **cómo instalarlos/ejecutarlos** y **requisitos de CPU/RAM** para correr **Istio** sobre **K3d** (K3s en Docker), incluyendo **modo multicluster** y compatibilidad con **WSL2**.

> **Contexto**: Istio necesita recursos y primitivas de Kubernetes (CRDs, webhooks, sidecars, etc.), por lo que **no se ejecuta sólo con Docker**; usamos **K3d** para simular uno o varios clusters dentro de contenedores Docker. La instalación de Istio puede hacerse con `istioctl` o con Helm; en esta guía usamos `istioctl` por simplicidad. (Plataforma K3d oficial e Istio docs) citeturn5search7

---

## 1) Scripts incluidos

### a) `istio-on-k3d.sh`
- Crea **un cluster** K3d (1 server, 2 agents) en Docker.
- Instala **Istio** (perfil configurable; por defecto `demo`).
- Crea `namespace demo` con **inyección automática** de sidecar.
- Despliega **Bookinfo** y su **Gateway** + **DestinationRules**.
- (Opcional) Despliega **add-ons**: Kiali, Prometheus, Grafana, Jaeger.

**Objetivo**: laboratorio “todo en uno” para empezar en minutos.

---

### b) `istio-on-k3d-wsl.sh`
- Igual que el anterior pero **optimizado para WSL2**:
  - Instala binarios en `~/.local/bin` (sin requerir `sudo`).
  - Verifica conexión con Docker Desktop (WSL2 backend) y muestra consejos si no está activo.
  - Advierte si ejecutas desde **`/mnt/c`** y recomienda mover a tu **`$HOME`** por rendimiento.

**Objetivo**: experiencia sin fricción en **Windows + WSL2 + Docker Desktop**.

---

### c) `istio-on-k3d-wsl-multicluster.sh`
- Crea **dos clusters** K3d (por defecto `cluster1` y `cluster2`) en una **red Docker compartida**.
- Instala **Istio multi‑primary** (un `istiod` por cluster) con **redes lógicas** distintas (`network1`/`network2`).
- Despliega **east‑west gateways**, **exposición de istiod**, **remote‑secrets** y **MeshNetworks** para descubrimiento/tráfico **cross‑cluster**.
- Despliega **Bookinfo** (por defecto en `cluster1`) y **add‑ons** opcionales.

**Objetivo**: practicar **multicluster Istio** en local, el patrón recomendado cuando necesitas alta disponibilidad del control plane o clusters en redes separadas. (Elección de topología multi‑primary vs primary‑remote) citeturn5search9

---

## 2) Requisitos previos

- **Docker Desktop** (Windows) con **WSL2 backend** habilitado y WSL Integration para tu distro (Ubuntu). (Requisitos de K3d + Docker) citeturn5search7
- **WSL2** actualizado (en Windows 10/11) y distro **Ubuntu** o similar.
- El script instala si faltan: **k3d**, **kubectl**, **istioctl**.

> Nota: K3d es un wrapper para ejecutar **K3s** (Kubernetes ligero) en Docker, ideal para laboratorios locales. citeturn5search7

---

## 3) Recursos (CPU/RAM) recomendados

**Por componente (recomendación de referencia):**

- `istiod`: **500m CPU** y **2048Mi RAM** (request). 
- `ingress/egress gateway`: **100m CPU** y **128Mi RAM** (request) cada uno.
- `proxy sidecar` (por pod): **10m CPU** y **10Mi RAM** (request). (Tabla de requisitos mínimos por componente) citeturn5search10

**Single‑cluster (con Bookinfo y add‑ons):**
- **Mínimo**: 4 vCPU, **8 GB RAM**.
- **Recomendado**: 6–8 vCPU, **12–16 GB RAM**.

**Multicluster (2 clusters):**
- **Mínimo**: 6 vCPU, **10–12 GB RAM**. 
- **Recomendado**: 8–10 vCPU, **16 GB RAM**. 
- **Ideal** (observabilidad completa y pruebas de tráfico): 12 vCPU, **24–32 GB RAM**.

> Un repo público que automatiza K3D+Istio multicluster reporta ~**4 vCPU / 12GiB** en idle para un stand de pruebas (3 clusters). Para 2 clusters, la recomendación práctica es 8–10 vCPU y ~16 GB para ir fluido. citeturn5search8

---

## 4) Instalación y ejecución

### 4.1 Descargar scripts
- **Single cluster (WSL2)**: [istio-on-k3d-wsl.sh](citeturn4file5)
- **Multicluster (WSL2)**: [istio-on-k3d-wsl-multicluster.sh](citeturn4file4)
- **Genérico Linux (single)**: [istio-on-k3d.sh](citeturn4file6)

> Marca como ejecutable si hiciera falta: `chmod +x <script>.sh`

### 4.2 Ejecutar en **WSL2** (recomendado)

1. **Arranca Docker Desktop** en Windows (backend WSL2 + WSL Integration). citeturn5search7
2. Abre **Ubuntu (WSL2)** y navega a tu **`$HOME`** (evita `/mnt/c`).
3. Ejecuta **single cluster**:
   ```bash
   bash istio-on-k3d-wsl.sh
   ```
   o **multicluster**:
   ```bash
   bash istio-on-k3d-wsl-multicluster.sh --multicluster
   ```

### 4.3 Opciones comunes

```bash
# Cambiar nombre del cluster y tamaño
bash istio-on-k3d-wsl.sh --cluster-name lab --servers 1 --agents 1

# Cambiar puertos del LoadBalancer
bash istio-on-k3d-wsl.sh --http-port 8081 --https-port 8444

# Cambiar perfil de Istio (minimal/default/demo)
bash istio-on-k3d-wsl.sh --istio-profile minimal

# Omitir add-ons (más ligero)
bash istio-on-k3d-wsl.sh --skip-addons

# Borrar el cluster
bash istio-on-k3d-wsl.sh --delete --cluster-name lab
```

En multicluster:
```bash
# Dos clusters con nombres/redes/puertos personalizados
bash istio-on-k3d-wsl-multicluster.sh \
  --multicluster \
  --cluster1-name c1 --cluster2-name c2 \
  --network1 netA --network2 netB \
  --http1 8081 --https1 8444 \
  --http2 9081 --https2 9444 \
  --istio-profile minimal

# Desplegar Bookinfo en cluster2
bash istio-on-k3d-wsl-multicluster.sh --multicluster --bookinfo-on cluster2

# Sin add-onsash istio-on-k3d-wsl-multicluster.sh --multicluster --skip-addons

# Limpieza de ambos clusters
bash istio-on-k3d-wsl-multicluster.sh --delete
```

---

## 5) ¿Qué instalan y configuran exactamente?

### 5.1 Single cluster (WSL2 y genérico)
1. **Herramientas**: instala `k3d`, `kubectl` y `istioctl` si faltan. (K3d y kubectl como prerequisitos) citeturn5search7
2. **Cluster K3d**: crea 1 server + 2 agents y expone `80/443` vía un **load balancer** mapeado a puertos del host.
3. **Istio**: `istioctl install --set profile=<perfil>` instala **CRDs**, **istiod**, **gateways**.
4. **Namespace `demo`**: etiqueta `istio-injection=enabled` para inyección automática de Envoy.
5. **Bookinfo**: despliegue de los microservicios + `Gateway` + `VirtualService`/`DestinationRule` de ejemplo.
6. **Add-ons** (opcional): Kiali, Prometheus, Grafana, Jaeger (desde `samples/addons`).

### 5.2 Multicluster (WSL2)
1. Crea **2 clusters** en una **red Docker** compartida.
2. Instala **Istio multi‑primary** con `values.global.multiCluster.clusterName` y `values.global.network` distintos por cluster. (Selección de topología: multi‑primary) citeturn5search9
3. Genera y aplica **east‑west gateways** (scripts de `samples/multicluster` de Istio). (Guía de plataforma K3d en Istio) citeturn5search7
4. Expone **istiod** en ambos clusters para descubrimiento.
5. Crea **remote‑secrets** cruzados (`istioctl x create-remote-secret`).
6. Construye y aplica **`MeshNetworks`** con las direcciones de ambos east‑west gateways (puerto **15443** por defecto para mTLS cross‑network). (Prácticas comunes en multicluster) citeturn5search9
7. Despliega **Bookinfo** en el cluster elegido y (opcional) los **add‑ons**.

---

## 6) Consejos para WSL2

- Configura límites de WSL2 en `C:\\Users\\<usuario>\\.wslconfig` para asignar **RAM/CPU** al backend (recomendaciones en función de single vs multi‑cluster):

```ini
[wsl2]
memory=16GB   # 24GB si usarás multicluster + observabilidad
processors=8  # 12 si tu CPU lo permite
swap=0
```

- Mantén los proyectos dentro de tu **`$HOME` en WSL** (mejor I/O) y evita `/mnt/c`.
- Asegúrate de tener **Docker Desktop** abierto antes de ejecutar los scripts. (K3d requiere Docker) citeturn5search7

---

## 7) Verificación rápida

```bash
# Nodos del/los cluster(s)
kubectl --context k3d-cluster1 get nodes -o wide
kubectl --context k3d-cluster2 get nodes -o wide  # si multicluster

# Istio en marcha
kubectl --context k3d-cluster1 -n istio-system get pods
kubectl --context k3d-cluster2 -n istio-system get pods  # si multicluster

# East-west gateway (multicluster)
kubectl --context k3d-cluster1 -n istio-system get svc istio-eastwestgateway -o wide
kubectl --context k3d-cluster2 -n istio-system get svc istio-eastwestgateway -o wide

# App de ejemplo
xdg-open http://localhost:8080/productpage  # cluster1
xdg-open http://localhost:9080/productpage  # cluster2 si desplegaste ahí
```

---

## 8) Problemas comunes

- **Docker no responde desde WSL2**: abre Docker Desktop en Windows y revisa *Settings → Resources → WSL Integration*. (Requisito/Integración K3d) citeturn5search7
- **Recursos insuficientes**: sube límites en `.wslconfig` (ver sección 6) y cierra/reabre WSL: `wsl --shutdown`.
- **East‑west sin IP/hostname**: si el `LoadBalancer` no expone IP (entorno local), usa el **hostname** del servicio o ajusta `MeshNetworks` manualmente.

---

## 9) Referencias

- **Istio — k3d (plataforma)**: pasos y prerequisitos de plataforma K3d, instalación con Helm/istio. citeturn5search7
- **Topologías Multicluster Istio (multi‑primary vs primary‑remote)**: guía de planificación y trade‑offs. citeturn5search9
- **Requisitos de CPU/RAM por componente de Istio** (referencia de dimensionamiento). citeturn5search10
- **Experiencia práctica multicluster K3D+Istio (consumo en idle)**. citeturn5search8
