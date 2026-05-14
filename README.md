# CARE-infra

CARE 後端的 **Kubernetes** 與 **NGINX Ingress Controller**（[ingress-nginx](https://github.com/kubernetes/ingress-nginx)）部署資源，與應用程式碼分開維護。

## 目錄

- `k8s/`：後端 Deployment／Service／Secret 範本、Ingress（`ingressClassName: nginx`）

## 前置需求

- `kubectl` 已設定並可連到目標叢集
- 已安裝 [Helm](https://helm.sh/)

## Kubernetes：以 Helm 安裝 NGINX Ingress

以下流程為「ingress-nginx 當 Ingress Controller，由 `k8s/ingress.yaml` 控制路由」的最小可用版本。請在**本 repo 根目錄**執行（讓 `kubectl apply -f k8s/...` 路徑正確）。

1) 套用後端 Secret（請先改為佔位符以外的真值，或改用本機／CI 注入，勿將含真值的檔案提交 git）：

```bash
kubectl apply -f k8s/secret.yaml
```

2) 套用其餘後端資源：

```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

3) 加入 ingress-nginx Helm repo 並更新：

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

4) 安裝 ingress-nginx（範例 namespace：`ingress-nginx`）：

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace
```

若需自訂（例如 `controller.service.type`），可另建 values 檔並加上 `-f your-values.yaml`。

5) 確認 ingress-nginx 與後端 Service：

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
kubectl get svc care-backend
```

6) 套用 Ingress：

```bash
kubectl apply -f k8s/ingress.yaml
kubectl get ingress
```

7) 測試（將 `<NGINX_LB_IP>` 換成 `kubectl get svc -n ingress-nginx` 中 `ingress-nginx-controller` 的 EXTERNAL-IP，或本機／雲上對應的入口位址）：

```bash
curl http://<NGINX_LB_IP>/api
```

### 說明

- 路由由 Kubernetes `Ingress`（`k8s/ingress.yaml`）管理；`ingressClassName` 為 `nginx`（對應 ingress-nginx 預設 IngressClass）。
- 若叢集內曾安裝 Kong，請先依原安裝方式卸載（例如 `helm uninstall kong -n kong`）並刪除舊 IngressClass，避免與新 Ingress 混淆。

## 本機 Secret（可選）

若要在本機用檔案覆寫而不改 git 內的 `secret.yaml`，可建立 `k8s/secret.local.yaml`（已列入 `.gitignore`），再以 `kubectl apply -f k8s/secret.local.yaml` 套用。
