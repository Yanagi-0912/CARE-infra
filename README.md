# CARE-infra

CARE 應用的 **Kubernetes** 部署與 **GitHub Actions CI/CD**，使用 **Helm** 管理叢集資源（不再使用 Kustomize）。

## 目錄

- `helm/care/`：Helm chart（Deployment、Service、ConfigMap、Ingress、n8n PVC 等）
- `.github/workflows/cicd.yml`：建置映像、驗證 chart、部署到叢集
- `scripts/vm-disk-guard.sh`：VM 磁碟守門員（見「VM 維運」）
- `scripts/install-vm-maintenance.sh`：把守門員裝成 systemd timer
- `systemd/`：守門員的 service / timer unit
- `n8n/disk-alert-to-line.json`：把磁碟告警轉發到 LINE 的 n8n workflow

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
  --from-literal=COHERE_API_KEY='...' \
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

**任一 repo merge 到 `main` → 自動 build 前後端映像 + deploy 到 K3s**

| 誰 merge 到 main | 會發生什麼 |
|------------------|------------|
| **CARE**（後端） | `trigger-deploy.yml` → 通知 CARE-infra → build 前後端 + deploy |
| **CARE-LIFF**（前端） | 同上 |
| **CARE-infra**（Helm） | 直接跑 `cicd.yml` → build 前後端 + deploy |

- **build**（GitHub 雲端 runner）：建置並推送 Docker Hub 映像
- **validate**（GitHub 雲端 runner）：`helm lint` + `helm template` + `kubeconform`
- **deploy**（**self-hosted runner，K3s VM**）：建立 Secret → `helm upgrade --install`

### Secrets

**CARE-infra**（Settings → Secrets）：`DOCKERHUB_*`、LINE/Gemini/MongoDB 等（見 workflow）。

**CARE** 與 **CARE-LIFF** 各需一個 **`INFRA_DEPLOY_TOKEN`**（Personal Access Token，能觸發 CARE-infra 的 workflow）：

1. GitHub → Settings → Developer settings → Personal access tokens
2. 建立 token（classic：`repo` 權限；或 fine-grained：CARE-infra 的 Actions 寫入）
3. 分別加到 **CARE**、**CARE-LIFF** repo 的 Secrets，名稱：`INFRA_DEPLOY_TOKEN`

`KUBE_CONFIG_DATA` 在 VM runner 上**可選**（deploy 會優先讀 `/etc/rancher/k3s/k3s.yaml`）。

### Self-hosted runner（CD 必備）

K3s API 位址為 `127.0.0.1:6443`，GitHub 雲端 runner 無法連線，**deploy job 必須在 K3s VM 上跑 self-hosted runner**。

1. GitHub → **Yanagi-0912/CARE-infra** → **Settings** → **Actions** → **Runners** → **New self-hosted runner**
2. 在 VM（`192.168.101.41`）執行（token 一次性，從上一步複製）：

```bash
git clone https://github.com/Yanagi-0912/CARE-infra.git
cd CARE-infra
sudo bash scripts/setup-self-hosted-runner.sh \
  --url https://github.com/Yanagi-0912/CARE-infra \
  --token PASTE_TOKEN_HERE
```

3. Runners 頁面出現 **Idle** 的 `care-k3s-vm` 後，push `main` 或手動 **workflow_dispatch** 即會自動部署。

Runner labels：`self-hosted`, `Linux`, `care-k3s`（對應 workflow `runs-on: [self-hosted, Linux, care-k3s]`）。

維護指令（在 VM）：

```bash
sudo /opt/actions-runner/svc.sh status
sudo /opt/actions-runner/svc.sh stop
sudo /opt/actions-runner/svc.sh start
```

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

## VM 維運（磁碟守門員）

### 為什麼需要

2026-08-10 曾發生一次全站 502。成因鏈：

1. VM 上手動 `docker compose build` CARE-n8n stack，build cache 累積到 **13.8G**（單筆 whisper ASR build 就 9.8G）
2. `/` 被塞到 **100%**
3. kubelet 觸發 **DiskPressure**，替節點打上 `node.kubernetes.io/disk-pressure:NoSchedule`
4. **Traefik 與所有 care-dev pod 被驅逐**
5. Traefik 沒有 endpoint → svclb 的 iptables 無轉發目標 → VM `:80` REJECT
6. Cloudflare Tunnel 連 origin 被拒 → **502**

關鍵是 K3s VM 上有**兩套獨立的 containerd**，清理時別搞混：

| 路徑 | 屬於 | socket | 清理指令 |
|------|------|--------|----------|
| `/var/lib/rancher/k3s/agent/containerd` | k3s | `/run/k3s/containerd/containerd.sock` | `k3s crictl rmi --prune` |
| `/var/lib/containerd` | Docker | `/run/containerd/containerd.sock` | `docker builder prune` / `docker image prune` |

清 Docker 那側**不影響 k3s 叢集**。

### 為什麼這件事 CI/CD 做不到

CI/CD 管的是**叢集裡的東西**（`helm upgrade` 部署 Deployment、Service、Ingress）。守門員是**主機層的東西**：systemd unit、`/usr/local/sbin/`、`/etc/care/`。

它必須活在 k8s 外面，因為它要處理的正是「k8s 自己因磁碟滿而癱瘓」的情況 —— 裝進叢集裡就會跟 Traefik 一起被 kubelet 驅逐，需要它的時候剛好不在。

所以這是**一次性的主機 bootstrap**，跟當初手動跑 `setup-self-hosted-runner.sh` 同一類。裝完之後 systemd timer 自動運作，CI 也會在每次部署時呼叫它回收空間、並檢查 VM 上的版本有沒有跟 repo 脫節。

### 安裝

一行搞定（**建議**，含 kubeconfig 修復與 CI 授權）：

```bash
sudo bash scripts/install-vm-maintenance.sh --fix-kubeconfig --enable-ci-sudo
```

之後補上告警管道（見「告警轉發到 LINE」取得 webhook URL）：

```bash
sudo bash scripts/install-vm-maintenance.sh \
  --fix-kubeconfig --enable-ci-sudo \
  --webhook http://localhost:5678/webhook/disk-alert
```

腳本可重複執行，重跑就是更新。

| 選項 | 作用 |
|------|------|
| `--fix-kubeconfig` | 修好 k3s.yaml 權限，並重啟 CI runner 服務套用群組變更 |
| `--enable-ci-sudo` | 讓 CI 的 deploy job 免密碼執行守門員 |
| `--ci-user NAME` | CI runner 跑在哪個使用者下，預設為執行 sudo 的本人 |
| `--webhook URL` | 告警要 POST 到哪裡 |
| `--uninstall` | 移除所有安裝的內容 |

> 本 VM 的 self-hosted runner 跑在 **`care`** 使用者下（不是 `setup-self-hosted-runner.sh` 預設的 `github-runner`），所以直接用 `sudo` 執行即可，不必額外指定 `--ci-user`。

### CI 授權的界線

`--enable-ci-sudo` 寫入 `/etc/sudoers.d/care-vm-maintenance`，**只授權執行 `/usr/local/sbin/vm-disk-guard.sh` 這一件事**，不是全面 NOPASSWD。

授權對象刻意指向已安裝的固定路徑，而不是 repo 裡的腳本 —— 後者每次 CI 都會被 checkout 覆寫，授權它等於把 VM 的 root 交給任何能 push 到 main 的人。

同理，CI **不會自動更新守門員本身**，只在版本與 repo 不一致時發出 warning，由你手動重跑安裝腳本。

裝好後有兩個 timer：

| Timer | 頻率 | 行為 |
|-------|------|------|
| `care-disk-guard.timer` | 每 15 分鐘 | 超過 80% 告警；超過 85% 分級回收（build cache → 未用映像 → k3s 映像），每級做完重新量測，夠了就停手 |
| `care-docker-prune.timer` | 每日 04:00 | 清掉超過 48 小時的 build cache，近期的保留讓 build 仍有快取可用 |

門檻對齊 kubelet 的行為，刻意留出反應餘裕：

- **85%** — kubelet 映像 GC 的 `HighThresholdPercent` 預設值
- **90%** — kubelet 驅逐門檻 `nodefs.available<10%`（即上述事故）

守門員設在 85% 動手，目的是在 kubelet 自己開始驅逐 pod 之前就把空間收回來。

### 告警轉發到 LINE

守門員預設只寫 journal，**沒人會主動去看**。設定 `CARE_ALERT_WEBHOOK` 後它會 POST 這樣的 JSON：

```json
{ "source": "care-disk-guard", "host": "care", "level": "crit", "disk_pct": 87, "message": "..." }
```

`n8n/disk-alert-to-line.json` 是現成的接收端（Webhook → 格式化 → LINE Push → 回應）。

**要送到哪個 n8n？用 Docker 那個（`localhost:5678`），不要用 k8s 裡的。**
理由：這則告警的用途正是「叢集快掛了」。k8s 裡的 n8n 會跟 Traefik 一起被 kubelet 驅逐 —— 用它當告警管道，等於在火災時把警報器接在燒起來的房間裡。Docker 那套不歸 kubelet 管，能在驅逐事件中存活。

設定步驟：

1. n8n → Credentials → 新增 **Header Auth**，Name 填 `Authorization`，Value 填 `Bearer <LINE_CHANNEL_ACCESS_TOKEN>`
2. 匯入 `n8n/disk-alert-to-line.json`
3. 編輯 **Format Alert** 節點，把 `LINE_TO` 換成你的 LINE user ID（`U` 開頭）或群組 ID（`C` 開頭）
4. 在 **LINE Push** 節點選擇步驟 1 建立的 credential
5. 啟用 workflow，取得 webhook URL
6. 用該 URL 重跑安裝腳本的 `--webhook`

### 告警頻率

巡檢每 15 分鐘一次，若磁碟長期停在警戒線上會重複觸發。守門員的規則：

- **等級改變一定送** —— 升壓（warning → crit）或恢復都值得立刻知道
- **等級沒變則受冷卻限制** —— 預設 6 小時（`DISK_GUARD_COOLDOWN_MIN`）
- **恢復時送一則 notice** —— 沒有這則，收到告警的人無從得知問題已解決
- **journal 一律留完整紀錄** —— 冷卻只作用在對外通知，不影響 `journalctl -t care-disk-guard`

狀態記在 `/var/lib/care/disk-guard.state`。

### 常用指令

```bash
sudo /usr/local/sbin/vm-disk-guard.sh status   # 只看狀態，不做任何變更
sudo /usr/local/sbin/vm-disk-guard.sh check    # 手動跑一次巡檢
journalctl -t care-disk-guard -n 50            # 看歷史紀錄
systemctl list-timers 'care-*'                 # 確認排程

sudo bash scripts/install-vm-maintenance.sh --uninstall
```

設定放在 `/etc/care/disk-guard.env`，改完不必重載 systemd，下次觸發即生效。

### kubeconfig 權限（`--fix-kubeconfig`）

k3s **每次啟動**都會把 `/etc/rancher/k3s/k3s.yaml` 重寫為 `0600 root:root`。這會同時擋住兩者：

- 一般使用者的 `kubectl`
- CI deploy job 的 `[ -r /etc/rancher/k3s/k3s.yaml ]` 測試 —— 測試失敗會退回 `KUBE_CONFIG_DATA` secret，**若該 secret 未設定則部署直接失敗**

`--fix-kubeconfig` 會建立 `k3s` 群組、把當前使用者與 `github-runner` 加進去，並寫入 `/etc/rancher/k3s/config.yaml`：

```yaml
write-kubeconfig-group: "k3s"
write-kubeconfig-mode: "0640"
```

這樣 k3s 重啟後仍以 `0640 root:k3s` 寫出 kubeconfig。比 `chmod 644` 安全 —— cluster-admin 憑證不會變成全機器可讀。群組變更需重新登入才會對現有 shell 生效。

> `kubectl` 在 VM 上是 k3s 的 symlink，`KUBECONFIG` 為空時會**寫死回退**到 `/etc/rancher/k3s/k3s.yaml`。所以用家目錄的 kubeconfig 時必須明確 `export KUBECONFIG=$HOME/.kube/config`，`unset KUBECONFIG` 沒有用。

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
