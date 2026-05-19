**Overview**
- **專案**: CARE-infra，包含 Kubernetes 部署與 GitHub Actions CI/CD。此目錄管理整個應用的叢集設定與部署流程。
- **主要內容**: k8s 目錄存放所有 Kubernetes 資源，CI 流程位於 [.github/workflows/cicd.yml](.github/workflows/cicd.yml#L1)。

**Prerequisites**
- **本機需求**: 安裝 `kubectl`、`kustomize`、`docker`（若要在本機建置映像）。
- **Cluster**: 取得有效的 kubeconfig 並設定為將要部署的叢集。
- **CI Secrets**: 在 GitHub repository secrets 中設定：`DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN`、`KUBE_CONFIG_DATA`、以及所有應用所需的金鑰（例如 `GEMINI_API_KEY`, `MONGODB_URI`, `LINE_*`, `LIFF_*`）。

**CI/CD 流程（摘要）**
- **檔案**: [.github/workflows/cicd.yml](.github/workflows/cicd.yml#L1)
- **觸發條件**: push 到 `main` 或 `feature/*` 分支、pull request 到 `main`、或手動 `workflow_dispatch`。
- **Tag 產生**: `generate-tag` 工作會以 `run_number-short_sha` 或 `workflow_dispatch` 提供的 `custom_tag` 產生映像標籤。
- **建置與推送**: `build-backend` 與 `build-frontend` 使用 `docker/build-push-action` 將映像推到 Docker Hub，標籤包含產生的 tag 與 `latest`。
- **驗證**: `validate` 會用 `kustomize build` 與 `kubectl apply --dry-run=client` 驗證 k8s 資源的組合。
- **部署**: `deploy` 取得 kubeconfig，建立或更新 Secret（使用 CI secrets），更新 kustomize 的 images，最後 `kubectl apply -k k8s` 並等待 deployments rollout 完成。

**Kubernetes 目錄結構**
- **kustomization**: [k8s/kustomization.yaml](k8s/kustomization.yaml#L1)（定義 namespace、resources 與 images 佈署替換）
- **Namespace**: [k8s/namespace.yaml](k8s/namespace.yaml#L1)
- **Secrets**: [k8s/secret.yaml](k8s/secret.yaml#L1)（範本，請勿放真實金鑰）；本地測試用的 `secret.local.yaml` 可供參考。
- **ConfigMap**: [k8s/configmap.yaml](k8s/configmap.yaml#L1)（後端設定）與 [k8s/n8n-configmap.yaml](k8s/n8n-configmap.yaml#L1)
- **Backend**: [k8s/backend-deployment.yaml](k8s/backend-deployment.yaml#L1) 與 [k8s/backend-service.yaml](k8s/backend-service.yaml#L1)
- **Frontend**: [k8s/frontend-deployment.yaml](k8s/frontend-deployment.yaml#L1) 與 [k8s/frontend-service.yaml](k8s/frontend-service.yaml#L1)
- **n8n**: PVC、Deployment、Service 與 ConfigMap（[k8s/n8n-pvc.yaml](k8s/n8n-pvc.yaml#L1), [k8s/n8n-deployment.yaml](k8s/n8n-deployment.yaml#L1), [k8s/n8n-service.yaml](k8s/n8n-service.yaml#L1)）
- **Ingress**: [k8s/ingress.yaml](k8s/ingress.yaml#L1)（路由 `/` → 前端、`/api` → 後端、`/n8n` → n8n）

**本機驗證與部署步驟**
- 1) 在 `CARE-infra/k8s` 目錄執行 `kustomize build . > ../rendered.yaml`。
- 2) 驗證：
```
kubectl apply --dry-run=client --validate=false -f ../rendered.yaml
```
- 3) 若一切正常，將 kubeconfig 設定好後套用：
```
kubectl apply -k k8s
```
- 4) 等待 rollout：
```
kubectl rollout status deployment/care-backend -n care-dev --timeout=5m
kubectl rollout status deployment/care-frontend -n care-dev --timeout=5m
kubectl rollout status deployment/care-n8n -n care-dev --timeout=5m
```

**注意事項與安全**
- **Secret 管理**: `k8s/secret.yaml` 僅為範本。請使用 CI secrets 或 `kubectl create secret generic ... --from-literal` 在部署時注入真實值，避免將敏感資訊提交至 Git。
- **映像標籤管理**: CI 會同時推 `latest` 與帶 tag 的 image，生產環境應以明確 tag 為主以避免不可預期的變更。
- **n8n 資料持久化**: n8n 使用 PVC（local-path storage class）。請確認 cluster 有相對應的 StorageClass 或調整為合適的 storage class。
- **CORS / 外部 URL**: ConfigMap 中 `CORS_ALLOW_ORIGINS` 與 `LIFF_URL` 需要根據實際域名或 IP 調整。

**快速檢查清單**
- **CI secrets** 已設定。
- **kubeconfig** 可使用且具有適當權限。
- **kustomize build** 通過本地 dry-run。
- **StorageClass** 支援 `n8n` 的 PVC。

若要我把 README 提交到 git（commit & push），或補充更詳細的操作教學（例如本機模擬、debug tips），請告訴我。

**改動紀錄 (本次重構)**
- 若本機存在 `k8s/secret.local.yaml`，請移出 repo 並加入 `.gitignore`，避免未來意外提交本機敏感資訊。
- 移除 `kustomization.yaml` 中的靜態 `newTag`，改以僅保留映像名稱（CI 使用 `kustomize edit set image` 注入 tag）。
- 將 `n8n-deployment.yaml` 與 `configmap.yaml` 中的硬編碼 IP/URL 改為占位符（`REPLACE_WITH_...`），並加上註解，建議透過 overlay 或 CI 注入真值。

**建議的下一步（敏感資訊清理）**
- 若想從 Git 歷史中移除已提交的機敏資料，請使用 `git filter-repo` 或 `BFG Repo-Cleaner` 清除，範例（在本機備份後執行）：
```
# 使用 BFG 清除包含 secret.local.yaml 的歷史
bfg --delete-files secret.local.yaml
git reflog expire --expire=now --all && git gc --prune=now --aggressive
```
或使用 `git filter-repo`（更精細）：
```
git filter-repo --invert-paths --paths k8s/secret.local.yaml
```

請在執行清理歷史前務必備份 repo，並通知協作者重新 clone。