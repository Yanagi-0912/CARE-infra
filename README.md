# CARE-infra

CARE 的 **Kubernetes** 與 **NGINX Ingress Controller**（[ingress-nginx](https://github.com/kubernetes/ingress-nginx)）部署資源，與應用程式碼分開維護。

## 目錄

- `k8s/`：Namespace、ConfigMap、Secret、前後端與 n8n 的 Deployment／Service／PVC、Ingress、Kustomize base
- `.github/workflows/`：Kubernetes manifest 驗證與部署流程

## 前置需求

- `kubectl` 已設定並可連到目標叢集
- 已安裝 [Helm](https://helm.sh/)

## k3s 初始化建議（Ubuntu VM）

若目標是單機 VM 的 k3s，建議先安裝 k3s 並停用內建 Traefik，避免與 ingress-nginx 重複：

```bash
curl -sfL https://get.k3s.io | sh -s - --disable traefik
sudo kubectl get nodes
```

若你需要讓 GitHub Actions 連進 k3s，先匯出 kubeconfig 並 base64 後放入 repo secret：

```bash
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
chmod 600 ~/.kube/config
base64 -w 0 ~/.kube/config
```

將輸出字串設定到 GitHub Secret：`KUBE_CONFIG_DATA`。

## Kubernetes：以 Helm 安裝 NGINX Ingress

以下流程為「ingress-nginx 當 Ingress Controller，由 `k8s/` 控制路由」的最小可用版本。請在**本 repo 根目錄**執行。

1) 套用整包資源：

```bash
kubectl apply -k k8s
```

2) 若要分開處理，也可以先套 namespace，再套 Kustomize：

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -k k8s
```

3) 套用 Secret 前，請先改為佔位符以外的真值，或改用本機／CI 注入，勿將含真值的檔案提交 git：

```bash
kubectl apply -f k8s/secret.yaml
```

### image tag 建議

- 後端與前端建議在各自的應用程式 repo 內，以 commit SHA 當 image tag，例如 `jamessu0530/care-backend:${GITHUB_SHA}`。
- 這個 infra repo 的 [k8s/kustomization.yaml](k8s/kustomization.yaml) 只負責定義預設 tag，CI/CD 要部署新版本時，先在 workflow 裡用 `kustomize edit set image` 改成當次要發布的 tag，再 `kubectl apply -k k8s`。
- n8n 目前先用 `latest` 當範本值，正式環境建議也改成固定版本。

### GitHub Actions

- `pull_request`：只做 manifest render 與 dry-run 驗證。
- `push` 到 `main`：套用 `k8s/` 到目標叢集。
- `workflow_dispatch`：可手動指定 `backend_image_tag`、`frontend_image_tag`、`n8n_image_tag`。

### GitHub Secrets / Variables

| 類型 | 名稱 | 用途 |
| --- | --- | --- |
| Secret | `KUBE_CONFIG_DATA` | base64 編碼 kubeconfig，讓 GitHub Actions 連到 k3s / Kubernetes |
| Variable | `BACKEND_IMAGE_TAG` | 後端預設發布 tag |
| Variable | `FRONTEND_IMAGE_TAG` | 前端預設發布 tag |
| Variable | `N8N_IMAGE_TAG` | n8n 預設發布 tag |

### 本機測試順序

```bash
kubectl apply -k k8s
kubectl get pods -n care-dev
kubectl get ingress -n care-dev
```

### 說明

- 路由由 Kubernetes `Ingress`（`k8s/ingress.yaml`）管理；`ingressClassName` 為 `nginx`（對應 ingress-nginx 預設 IngressClass）。
- 預設 namespace 為 `care-dev`。
- 若叢集內曾安裝 Kong，請先依原安裝方式卸載（例如 `helm uninstall kong -n kong`）並刪除舊 IngressClass，避免與新 Ingress 混淆。

### 入口路徑

| 路徑 | 服務 |
| --- | --- |
| `/` | `care-frontend:80` |
| `/api` | `care-backend:8000` |
| `/n8n` | `n8n-service:8100` |

### Kubernetes Service Port

| Service | Port | targetPort |
| --- | ---: | ---: |
| `care-frontend` | 80 | 80 |
| `care-backend` | 8000 | 8000 |
| `n8n-service` | 8100 | 8100 |

### ingress-nginx 安裝

加入 ingress-nginx Helm repo 並更新：

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

安裝 ingress-nginx（範例 namespace：`ingress-nginx`）：

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace
```

若是純 VM 的 k3s（無雲端 LoadBalancer），可改用 NodePort：

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=NodePort
```

若需自訂（例如 `controller.service.type`），可另建 values 檔並加上 `-f your-values.yaml`。

確認 ingress-nginx 與服務：

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
kubectl get svc -n care-dev
```

### 測試

將 `<NGINX_LB_IP>` 換成 `kubectl get svc -n ingress-nginx` 中 `ingress-nginx-controller` 的 EXTERNAL-IP，或本機／雲上對應的入口位址：

```bash
curl http://<NGINX_LB_IP>/api
curl http://<NGINX_LB_IP>/n8n
curl http://<NGINX_LB_IP>/
```

## 本機 Secret（可選）

若要在本機用檔案覆寫而不改 git 內的 `secret.yaml`，可建立 `k8s/secret.local.yaml`（已列入 `.gitignore`），再以 `kubectl apply -f k8s/secret.local.yaml` 套用。
