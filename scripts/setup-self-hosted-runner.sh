#!/usr/bin/env bash
# 在 K3s VM 上安裝 GitHub Actions self-hosted runner（供 deploy job 使用）
#
# 用法：
#   1. GitHub → Yanagi-0912/CARE-infra → Settings → Actions → Runners → New self-hosted runner
#   2. 複製設定指令裡的 --url 與 --token
#   3. 在 VM 上執行：
#        sudo bash scripts/setup-self-hosted-runner.sh \
#          --url https://github.com/Yanagi-0912/CARE-infra \
#          --token YOUR_ONE_TIME_TOKEN
#
# 可選環境變數：
#   RUNNER_USER   預設：github-runner
#   RUNNER_NAME   預設：care-k3s-vm
#   RUNNER_LABELS 預設：self-hosted,Linux,care-k3s

set -euo pipefail

RUNNER_USER="${RUNNER_USER:-github-runner}"
RUNNER_NAME="${RUNNER_NAME:-care-k3s-vm}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,Linux,care-k3s}"
RUNNER_VERSION="${RUNNER_VERSION:-2.323.0}"
INSTALL_DIR="/opt/actions-runner"

REPO_URL=""
REG_TOKEN=""

usage() {
  sed -n '2,12p' "$0"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) REPO_URL="$2"; shift 2 ;;
    --token) REG_TOKEN="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知參數: $1"; usage ;;
  esac
done

if [[ -z "$REPO_URL" || -z "$REG_TOKEN" ]]; then
  echo "錯誤：請提供 --url 與 --token（從 GitHub Runners 頁面取得，token 一次性）"
  usage
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "請用 sudo 執行此腳本"
  exit 1
fi

echo "==> 安裝 kubectl / helm（若尚未安裝）"
if ! command -v kubectl >/dev/null 2>&1; then
  if [[ -x /usr/local/bin/k3s ]]; then
    ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
  else
    echo "錯誤：找不到 kubectl，請先在此 VM 安裝 K3s 或 kubectl"
    exit 1
  fi
fi
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "==> 建立 runner 使用者: ${RUNNER_USER}"
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /bin/bash "$RUNNER_USER"
fi

echo "==> 設定 kubeconfig 給 ${RUNNER_USER}"
if [[ ! -f /etc/rancher/k3s/k3s.yaml ]]; then
  echo "錯誤：找不到 /etc/rancher/k3s/k3s.yaml，請確認此 VM 已安裝 K3s"
  exit 1
fi
install -d -m 700 -o "$RUNNER_USER" -g "$RUNNER_USER" "/home/${RUNNER_USER}/.kube"
install -m 600 -o "$RUNNER_USER" -g "$RUNNER_USER" \
  /etc/rancher/k3s/k3s.yaml "/home/${RUNNER_USER}/.kube/config"

echo "==> 下載 actions-runner ${RUNNER_VERSION}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
curl -fsSLO "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
tar xzf "actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
chown -R "$RUNNER_USER:$RUNNER_USER" "$INSTALL_DIR"

echo "==> 設定 runner（labels: ${RUNNER_LABELS}）"
sudo -u "$RUNNER_USER" bash -lc "
  cd '$INSTALL_DIR'
  ./config.sh \
    --url '$REPO_URL' \
    --token '$REG_TOKEN' \
    --name '$RUNNER_NAME' \
    --labels '$RUNNER_LABELS' \
    --unattended \
    --replace
"

echo "==> 安裝 systemd 服務"
./svc.sh install "$RUNNER_USER"
./svc.sh start

echo ""
echo "完成。請到 GitHub → CARE-infra → Settings → Actions → Runners 確認 ${RUNNER_NAME} 為 Idle。"
echo "deploy job 使用 runs-on: [self-hosted, Linux, care-k3s]"
