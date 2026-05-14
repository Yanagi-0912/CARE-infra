# CARE-infra

CARE 後端的 **Kubernetes** 與 **Kong（Ingress Controller）** 部署資源，與應用程式碼分開維護。

## 目錄

- `k8s/`：後端 Deployment／Service／Secret 範本、Kong Ingress、`kong-values.yaml`（Helm）

## 前置需求

- `kubectl` 已設定並可連到目標叢集
- 已安裝 [Helm](https://helm.sh/)

## Kubernetes：以 Helm 安裝 Kong（Ingress）

以下流程為「Kong 當 Ingress Controller，由 `k8s/ingress.yaml` 控制路由」的最小可用版本。請在**本 repo 根目錄**執行（讓 `-f k8s/...` 路徑正確）。

1) 套用後端 Secret（請先改為佔位符以外的真值，或改用本機／CI 注入，勿將含真值的檔案提交 git）：

```bash
kubectl apply -f k8s/secret.yaml
```

2) 套用其餘後端資源：

```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

3) 加入 Kong Helm repo 並更新：

```bash
helm repo add kong https://charts.konghq.com
helm repo update
```

4) 安裝 Kong（使用 `k8s/kong-values.yaml`）：

```bash
helm upgrade --install kong kong/kong -n kong --create-namespace -f k8s/kong-values.yaml
```

5) 確認 Kong 與後端 Service：

```bash
kubectl get pods -n kong
kubectl get svc -n kong
kubectl get svc care-backend
```

6) 套用 Ingress：

```bash
kubectl apply -f k8s/ingress.yaml
kubectl get ingress
```

7) 測試（將 `<KONG_PROXY_IP>` 換成 `kubectl get svc -n kong` 看到的 EXTERNAL-IP）：

```bash
curl http://<KONG_PROXY_IP>/api
```

### 說明

- `k8s/kong-values.yaml` 已啟用 Kong Ingress Controller（`ingressController.enabled: true`）。
- 路由由 Kubernetes `Ingress`（`k8s/ingress.yaml`）管理；`ingressClassName` 為 `kong`。

## 本機 Secret（可選）

若要在本機用檔案覆寫而不改 git 內的 `secret.yaml`，可建立 `k8s/secret.local.yaml`（已列入 `.gitignore`），再以 `kubectl apply -f k8s/secret.local.yaml` 套用。
