#!/usr/bin/env bash
# 在 K3s VM 上安裝磁碟守門員（systemd timer）
#
# 用法：
#   sudo bash scripts/install-vm-maintenance.sh
#   sudo bash scripts/install-vm-maintenance.sh --webhook http://localhost:5678/webhook/disk-alert
#   sudo bash scripts/install-vm-maintenance.sh --fix-kubeconfig
#
# 選項：
#   --webhook URL     告警要 POST 到哪裡（建議指向 VM 上已在跑的 n8n）
#   --warn-pct N      磁碟警戒門檻，預設 80
#   --crit-pct N      磁碟緊急回收門檻，預設 85
#   --keep-hours N    例行回收保留多久內的 build cache，預設 48
#   --fix-kubeconfig  順便修好 k3s.yaml 的權限（見下方說明）
#   --enable-ci-sudo  讓 CI 的 deploy job 能免密碼執行守門員（見下方說明）
#   --ci-user NAME    CI runner 跑在哪個使用者下，預設為執行 sudo 的本人
#   --uninstall       移除所有安裝的內容
#
# --enable-ci-sudo 在做什麼：
#   守門員需要 root（docker.sock 與 k3s crictl）。CI 的 deploy job 想在部署後
#   順手回收空間，就需要免密碼 sudo。這個選項寫入 /etc/sudoers.d/care-vm-maintenance，
#   只授權「執行 /usr/local/sbin/vm-disk-guard.sh」這一件事，不是全面 NOPASSWD。
#   授權對象是已安裝的固定路徑，不是 repo 裡的檔案 —— 後者可被 CI checkout 覆寫，
#   等於把 root 交給任何能 push 的人。
#
# --fix-kubeconfig 在做什麼：
#   k3s 每次啟動都會把 /etc/rancher/k3s/k3s.yaml 重寫為 0600 root:root。
#   這會讓一般使用者與 GitHub Actions self-hosted runner 都讀不到 kubeconfig，
#   CI 的 deploy job 會因此失敗（它的 `[ -r /etc/rancher/k3s/k3s.yaml ]` 測試不過）。
#   這個選項建立 k3s 群組、把相關使用者加進去，並透過 /etc/rancher/k3s/config.yaml
#   讓 k3s 之後都以 0640 root:k3s 寫出 kubeconfig —— 比 chmod 644 安全，
#   因為 cluster-admin 憑證不會變成全機器可讀。

set -euo pipefail

WEBHOOK=""
WARN_PCT="80"
CRIT_PCT="85"
KEEP_HOURS="48"
FIX_KUBECONFIG="false"
ENABLE_CI_SUDO="false"
CI_USER=""
UNINSTALL="false"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SBIN_TARGET="/usr/local/sbin/vm-disk-guard.sh"
ENV_FILE="/etc/care/disk-guard.env"
SUDOERS_FILE="/etc/sudoers.d/care-vm-maintenance"
UNITS=(care-disk-guard.service care-disk-guard.timer care-docker-prune.service care-docker-prune.timer)
TIMERS=(care-disk-guard.timer care-docker-prune.timer)
K3S_GROUP="k3s"

usage() {
  sed -n '2,32p' "$0"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --webhook) WEBHOOK="$2"; shift 2 ;;
    --warn-pct) WARN_PCT="$2"; shift 2 ;;
    --crit-pct) CRIT_PCT="$2"; shift 2 ;;
    --keep-hours) KEEP_HOURS="$2"; shift 2 ;;
    --fix-kubeconfig) FIX_KUBECONFIG="true"; shift ;;
    --enable-ci-sudo) ENABLE_CI_SUDO="true"; shift ;;
    --ci-user) CI_USER="$2"; shift 2 ;;
    --uninstall) UNINSTALL="true"; shift ;;
    -h | --help) usage ;;
    *) echo "未知參數: $1" >&2; usage ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || {
  echo "請用 sudo 執行" >&2
  exit 1
}

# --- 解除安裝 -----------------------------------------------------------------

if [[ "$UNINSTALL" == "true" ]]; then
  for t in "${TIMERS[@]}"; do
    systemctl disable --now "$t" 2>/dev/null || true
  done
  for u in "${UNITS[@]}"; do
    rm -f "/etc/systemd/system/$u"
  done
  rm -f "$SBIN_TARGET" "$SUDOERS_FILE"
  systemctl daemon-reload
  echo "已移除磁碟守門員（保留 $ENV_FILE，如不需要請自行刪除）"
  exit 0
fi

# CI runner 預設就是執行 sudo 的這個人 —— 本專案的 self-hosted runner 跑在 care 使用者下
CI_USER="${CI_USER:-${SUDO_USER:-}}"

# --- 安裝 ---------------------------------------------------------------------

echo "==> 安裝守門員腳本到 $SBIN_TARGET"
install -m 0755 -o root -g root "$SCRIPT_DIR/vm-disk-guard.sh" "$SBIN_TARGET"

echo "==> 寫入設定 $ENV_FILE"
install -d -m 0755 /etc/care
# 設定檔可能含 webhook URL，限制為 root 可讀
umask 077
cat >"$ENV_FILE" <<EOF
# 由 scripts/install-vm-maintenance.sh 產生
# 改完設定後不需重載 systemd，下次 timer 觸發即生效
DISK_GUARD_WARN_PCT=${WARN_PCT}
DISK_GUARD_CRIT_PCT=${CRIT_PCT}
DISK_GUARD_KEEP_HOURS=${KEEP_HOURS}
CARE_ALERT_WEBHOOK=${WEBHOOK}
EOF
chmod 0600 "$ENV_FILE"
umask 022

echo "==> 安裝 systemd unit"
for u in "${UNITS[@]}"; do
  install -m 0644 -o root -g root "$REPO_ROOT/systemd/$u" "/etc/systemd/system/$u"
done

systemctl daemon-reload
for t in "${TIMERS[@]}"; do
  systemctl enable --now "$t"
done

# --- 可選：修好 kubeconfig 權限 -----------------------------------------------

if [[ "$FIX_KUBECONFIG" == "true" ]]; then
  echo "==> 修復 kubeconfig 權限"

  getent group "$K3S_GROUP" >/dev/null || groupadd --system "$K3S_GROUP"

  # 把需要 kubectl 的使用者加進群組：執行 sudo 的本人 + CI runner
  # （github-runner 是 setup-self-hosted-runner.sh 的預設值，本 VM 上未使用，不存在就略過）
  for u in "${SUDO_USER:-}" "$CI_USER" github-runner; do
    [[ -n "$u" ]] || continue
    id "$u" >/dev/null 2>&1 || continue
    if id -nG "$u" | tr ' ' '\n' | grep -qx "$K3S_GROUP"; then
      echo "    $u 已在 $K3S_GROUP 群組中，略過"
      continue
    fi
    usermod -aG "$K3S_GROUP" "$u"
    echo "    已將 $u 加入 $K3S_GROUP 群組"
  done

  # 立即生效（這次不必重啟 k3s）
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    chgrp "$K3S_GROUP" /etc/rancher/k3s/k3s.yaml
    chmod 0640 /etc/rancher/k3s/k3s.yaml
    echo "    已將 k3s.yaml 設為 0640 root:$K3S_GROUP"
  fi

  # 持久化：k3s 下次啟動重寫 kubeconfig 時沿用同樣的群組與模式
  K3S_CONFIG="/etc/rancher/k3s/config.yaml"
  if [[ -f "$K3S_CONFIG" ]]; then
    echo "    !! $K3S_CONFIG 已存在，未自動修改，請手動確認含有："
    echo "         write-kubeconfig-group: \"$K3S_GROUP\""
    echo "         write-kubeconfig-mode: \"0640\""
  else
    cat >"$K3S_CONFIG" <<EOF
# 讓 k3s 重啟後仍以 0640 root:${K3S_GROUP} 寫出 kubeconfig，
# 避免每次重啟都把一般使用者與 CI runner 擋在門外。
write-kubeconfig-group: "${K3S_GROUP}"
write-kubeconfig-mode: "0640"
EOF
    chmod 0644 "$K3S_CONFIG"
    echo "    已建立 $K3S_CONFIG"
  fi

  echo "    注意：群組變更要重新登入才會生效於現有 shell"

  # self-hosted runner 是常駐服務，不重啟就拿不到新的群組成員資格，
  # CI 的 `[ -r /etc/rancher/k3s/k3s.yaml ]` 會繼續失敗。
  RUNNER_SVC="$(systemctl list-units --type=service --no-legend 'actions.runner.*' 2>/dev/null | awk '{ print $1 }' | head -1)"
  if [[ -n "${RUNNER_SVC:-}" ]]; then
    echo "    偵測到 CI runner 服務 $RUNNER_SVC，重啟以套用群組變更"
    systemctl restart "$RUNNER_SVC" || echo "    !! 重啟失敗，請手動執行：sudo systemctl restart $RUNNER_SVC"
  fi
fi

# --- 可選：讓 CI 能免密碼執行守門員 -------------------------------------------

if [[ "$ENABLE_CI_SUDO" == "true" ]]; then
  echo "==> 設定 CI 免密碼 sudo"

  if [[ -z "$CI_USER" ]] || ! id "$CI_USER" >/dev/null 2>&1; then
    echo "    !! 找不到 CI 使用者（$CI_USER），略過。請用 --ci-user 指定" >&2
  else
    # 只授權執行已安裝的守門員，且路徑固定在 root 擁有的 /usr/local/sbin。
    # 不要授權 repo 裡的腳本 —— 那是 CI checkout 出來的，能 push 就等於能拿 root。
    tmp_sudoers="$(mktemp)"
    cat >"$tmp_sudoers" <<EOF
# 由 CARE-infra/scripts/install-vm-maintenance.sh 產生
# 只允許執行磁碟守門員，供 CI 的 deploy job 在部署後回收空間
${CI_USER} ALL=(root) NOPASSWD: ${SBIN_TARGET}
EOF
    # sudoers 語法錯誤會讓全機器無法 sudo，務必先驗證再安裝
    if visudo -cqf "$tmp_sudoers"; then
      install -m 0440 -o root -g root "$tmp_sudoers" "$SUDOERS_FILE"
      echo "    已授權 $CI_USER 免密碼執行 $SBIN_TARGET"
    else
      echo "    !! sudoers 語法驗證失敗，未安裝" >&2
    fi
    rm -f "$tmp_sudoers"
  fi
fi

# --- 收尾 ---------------------------------------------------------------------

echo
echo "==> 完成。目前狀態："
"$SBIN_TARGET" status
echo
systemctl list-timers --no-pager 'care-*' || true
echo
echo "查看紀錄： journalctl -t care-disk-guard -n 50"
echo "手動試跑： sudo $SBIN_TARGET check"
