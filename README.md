# CARE-infra

CARE 應用的 **Kubernetes** 部署與 **GitHub Actions CI/CD**，使用 **Helm** 管理叢集資源（不再使用 Kustomize）。

## 目錄

- `helm/care/`：Helm chart（Deployment、Service、ConfigMap、Ingress、n8n PVC 等）
- `.github/workflows/cicd.yml`：建置映像、驗證 chart、部署到叢集

## 前置需求

- `kubectl`、`helm`（v3）
- 可連線的 Kubernetes 叢集（實踐室為 **K3s**）
- **Ingress Controller**：K3s 已內建 **Traefik**，chart 預設 `ingress.className: traefik`（無需另裝 ingress-nginx）

### K3s 與 Ingress 怎麼對應？

路由仍用標準 **`networking.k8s.io/v1` 的 `Ingress`** 資源（路徑 `/`、`/api`、`/n8n` 寫法不變），差別只在 `spec.ingressClassName` 要與叢集一致：

| 叢集 | `ingress.className` |
|------|---------------------|
| K3s（內建 Traefik） | `traefik`（預設） |
| 自裝 ingress-nginx | `nginx` |

確認指令：`kubectl get ingressclass`

## 本機部署（Helm）

在 repo 根目錄執行：

```bash
# 1. Secret（建議勿提交真值；本機可複製 values-local.yaml.example）
kubectl create secret generic care-backend-secret \
  --from-literal=GEMINI_API_KEY='...' \
  --from-literal=MONGODB_URI='...' \
  --from-literal=LINE_CHANNEL_ID='...' \
  --from-literal=LINE_CHANNEL_SECRET='...' \
  --from-literal=LINE_CHANNEL_ACCESS_TOKEN='...' \
  --from-literal=LIFF_CHANNEL_ID='...' \
  --from-literal=LIFF_CHANNEL_SECRET='...' \
  --from-literal=LIFF_ID='...' \
  -n care-dev --dry-run=client -o yaml | kubectl apply -f -

# 2. 安裝或升級 release
helm upgrade --install care ./helm/care \
  --namespace care-dev \
  --create-namespace

# 3. 等待 rollout
kubectl rollout status deployment/care-backend -n care-dev --timeout=5m
kubectl rollout status deployment/care-frontend -n care-dev --timeout=5m
kubectl rollout status deployment/care-n8n -n care-dev --timeout=5m
```

### 常用覆寫

```bash
# 指定映像 tag
helm upgrade --install care ./helm/care -n care-dev \
  --set backend.image.tag=123-abc1234 \
  --set frontend.image.tag=123-abc1234

# 修改對外 IP／域名（會同步更新 CORS、n8n webhook URL）
helm upgrade --install care ./helm/care -n care-dev \
  --set public.host=your.domain.com \
  --set public.scheme=https
```

本機完整設定可複製 `helm/care/values-local.yaml.example` 為 `values-local.yaml`（已列入 `.gitignore`），再加上 `-f helm/care/values-local.yaml`。

### 驗證 chart（不連叢集）

```bash
helm lint helm/care
helm template care helm/care --namespace care-dev > rendered.yaml
kubeconform -summary -ignore-missing-schemas rendered.yaml
```

## 路由

| 路徑 | Service |
|------|---------|
| `/` | care-frontend:80 |
| `/api` | care-backend:8000 |
| `/n8n` | n8n-service:8100 |

## CI/CD 摘要

- **validate**：`helm lint` + `helm template` + `kubeconform`（離線驗證，不需連叢集）
- **deploy**（push `main` 或手動觸發）：建立 Secret → `helm upgrade --install` 並 `--set` 注入後端／前端映像 tag

需在 GitHub Secrets 設定：`DOCKERHUB_*`、`KUBE_CONFIG_DATA`、以及各應用金鑰（見 workflow 註解）。

## K3s 快速部署（實踐室主機）

```bash
# kubeconfig（若一般使用者無權限）
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl get ingressclass   # 應有 traefik
kubectl get storageclass   # n8n 預設使用 local-path（K3s 內建）

cd CARE-infra   # jamesbranch
# 建立 Secret 後：
helm upgrade --install care ./helm/care \
  --namespace care-dev \
  --create-namespace \
  --set public.host=140.121.196.16
```

`ingress.className` 已預設 `traefik`，通常不必再加 `--set`。

## Docker Hub 映像

| 服務 | 映像 |
|------|------|
| 後端 | `yanagi0912/care` |
| 前端 | `yanagi0912/care-liff` |
| n8n | `n8nio/n8n`（官方） |

## 設定檔

主要可調項目在 `helm/care/values.yaml`：

- `public.host` / `public.scheme`：對外 URL（n8n、CORS）
- `ingress.className`：K3s 用 `traefik`；nginx 叢集改 `nginx`
- `backend.image.repository` / `frontend.image.repository`：上表 Docker Hub 名稱
- `backend.*` / `frontend.*` / `n8n.*`：映像 tag、資源、副本數
- `secret.create`：預設 `false`（由 CI／kubectl 建立 Secret）
