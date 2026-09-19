#!/usr/bin/env bash
# CARE K3s VM 磁碟守門員
#
# 背景：2026-08-10 事故 —— VM 上 Docker build cache 累積到 13.8G（單筆 whisper ASR
# build 就 9.8G）把 / 塞到 100%，kubelet 觸發 DiskPressure 驅逐 Traefik 與所有
# care-dev pod，導致 care.jamessu2016.com 回 502。這支腳本負責在同樣的情況
# 再次發生「之前」把空間收回來。
#
# 用法：
#   vm-disk-guard.sh status   # 只印出目前狀態，不做任何變更
#   vm-disk-guard.sh check    # 檢查水位，超過 CRIT 時分級回收（給 15 分鐘一次的 timer）
#   vm-disk-guard.sh prune    # 例行回收：舊 k3s 映像＋過期 build cache（給每日 timer 與部署後）
#
# 為什麼例行回收不能只靠 check：
#   check 只在水位 ≥ CRIT（85%）時才動手，那是「快出事了」的緊急手段。日常的
#   映像累積要在還沒逼近門檻時就處理掉，否則磁碟會長期貼著 85% 上下震盪——
#   而告警門檻 WARN 就在 80%，等於告警永遠在報告一件系統本來就會自己處理的事。
#   2026-09-19 實測：74 個映像只有 14 個在用，#220 一路堆到 #237，全靠 85% 才清。
#
# 設定（可寫進 /etc/care/disk-guard.env，systemd unit 會自動載入）：
#   DISK_GUARD_MOUNT       預設 /      監看的掛載點
#   DISK_GUARD_WARN_PCT    預設 80     超過就告警
#   DISK_GUARD_CRIT_PCT    預設 85     超過就啟動分級回收
#   DISK_GUARD_KEEP_HOURS  預設 48     例行回收保留多久內的 build cache
#   DISK_GUARD_KEEP_BUILDS 預設 3      例行回收每個映像 repository 保留幾個 tag
#   DISK_GUARD_COOLDOWN_MIN 預設 360   同一等級的告警最短間隔（分鐘），避免洗版
#   CARE_ALERT_WEBHOOK     選填        設了就 POST JSON 告警（可指向 VM 上的 n8n）
#
# 門檻怎麼訂的（對齊 kubelet 的行為，留出反應餘裕）：
#   85% — kubelet imagefs GC 的 HighThresholdPercent 預設值，開始自動刪映像
#   90% — kubelet eviction 的 nodefs.available<10%，開始驅逐 pod（= 上述事故）
#   所以 CRIT 設 85%：在 kubelet 自己動手前先清，避免走到驅逐那一步。
#   WARN 設 80%：留 5 個百分點給人類反應。

set -euo pipefail

MOUNT="${DISK_GUARD_MOUNT:-/}"
WARN_PCT="${DISK_GUARD_WARN_PCT:-80}"
CRIT_PCT="${DISK_GUARD_CRIT_PCT:-85}"
KEEP_HOURS="${DISK_GUARD_KEEP_HOURS:-48}"
KEEP_BUILDS="${DISK_GUARD_KEEP_BUILDS:-3}"
COOLDOWN_MIN="${DISK_GUARD_COOLDOWN_MIN:-360}"
WEBHOOK="${CARE_ALERT_WEBHOOK:-}"
TAG="care-disk-guard"
STATE_DIR="${DISK_GUARD_STATE_DIR:-/var/lib/care}"
STATE_FILE="${STATE_DIR}/disk-guard.state"

# --- 基本量測 -----------------------------------------------------------------

disk_pct() { df -P "$MOUNT" | awk 'NR==2 { gsub(/%/, "", $5); print $5 }'; }
inode_pct() { df -Pi "$MOUNT" | awk 'NR==2 { gsub(/%/, "", $5); print $5 }'; }
disk_avail() { df -Ph "$MOUNT" | awk 'NR==2 { print $4 }'; }

# --- 告警 ---------------------------------------------------------------------

# 讀出上次告警的等級（沒有紀錄就當作 ok）
last_level() {
  [[ -r "$STATE_FILE" ]] || {
    echo "ok"
    return 0
  }
  awk '{ print $1 }' "$STATE_FILE" 2>/dev/null || echo "ok"
}

# 巡檢每 15 分鐘一次，若磁碟長期停在警戒線上，同一則訊息會被重複送出。
# 規則：等級改變一定送（升壓或恢復都值得知道），等級沒變則受冷卻時間限制。
should_notify() {
  local level="$1" now prev prev_ts
  now="$(date +%s)"
  prev="$(last_level)"

  [[ "$level" == "$prev" ]] || return 0

  prev_ts="$(awk '{ print $2 }' "$STATE_FILE" 2>/dev/null)"
  [[ -n "${prev_ts:-}" ]] || return 0

  ((now - prev_ts >= COOLDOWN_MIN * 60))
}

record_state() {
  install -d -m 0755 "$STATE_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$1" "$(date +%s)" >"$STATE_FILE" 2>/dev/null || true
}

notify() {
  local level="$1" msg="$2"

  # journal 一律留完整紀錄，冷卻只作用在對外通知
  logger -t "$TAG" -p "daemon.${level}" -- "$msg" 2>/dev/null || true
  echo "[${level}] ${msg}"

  [[ -n "$WEBHOOK" ]] || return 0

  if ! should_notify "$level"; then
    logger -t "$TAG" -p daemon.info -- "冷卻中（${COOLDOWN_MIN} 分鐘內同等級不重送），略過 webhook"
    return 0
  fi
  record_state "$level"

  # 訊息一律不含雙引號，這裡再保險替換一次，避免手工組出的 JSON 破格
  local safe="${msg//\"/\'}"
  curl -fsS -m 10 -X POST "$WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d "{\"source\":\"${TAG}\",\"host\":\"$(hostname)\",\"level\":\"${level}\",\"disk_pct\":$(disk_pct),\"message\":\"${safe}\"}" \
    >/dev/null 2>&1 ||
    logger -t "$TAG" -p daemon.warning -- "webhook 送出失敗: ${WEBHOOK}"
}

# --- 回收動作 -----------------------------------------------------------------

has_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
has_k3s() { command -v k3s >/dev/null 2>&1; }

# 例行回收：只清超過 KEEP_HOURS 的 build cache，近期的留著讓 build 還有快取可用
routine_prune() {
  # docker 不在時只跳過 build cache 那一段，不是整支放棄。
  #
  # 這一行原本是 `has_docker || return 0`，於是本函式在沒有 docker 的機器上
  # 變成完全的空轉：每日 timer 天天觸發、天天只印一行「docker 不可用，跳過」，
  # 而 k3s 的映像一個都沒清（2026-09-19 查 journal，9/16～9/18 每天如此）。
  # 這台 VM 早就不在本機 build ——映像由 GitHub Actions 的 ubuntu-latest 建好
  # 推上 Docker Hub、VM 只負責 pull ——所以「沒有 docker」是常態，不是異常。
  if has_docker; then
    echo "--- docker builder prune (until=${KEEP_HOURS}h) ---"
    docker builder prune -f --filter "until=${KEEP_HOURS}h" || true
    echo "--- docker image prune (僅 dangling) ---"
    docker image prune -f || true
  else
    echo "--- 沒有 docker，跳過 build cache 回收 ---"
  fi

  echo "--- k3s 舊映像回收（每個 repository 保留最新 ${KEEP_BUILDS} 個 tag）---"
  prune_k3s_images
}

# 每個映像 repository 只留最新 KEEP_BUILDS 個 tag，其餘沒在用的刪掉。
#
# 為什麼不是 `crictl rmi --prune`：那會把上一版一起刪掉，回滾時得重新從
# Docker Hub 拉整包映像（光 care-asr 一個就 392MB）。保留最近幾版的代價很小
# ——連續兩次 build 之間多數 layer 是共用的，增量遠小於標稱大小——換到的是
# 回滾即時完成。KEEP_BUILDS=3 約等於保留最近三次部署。
#
# 使用中的映像絕不刪：先從 `crictl ps -a` 取出映像 ID 當黑名單。crictl rmi
# 本身對使用中的映像也會拒絕，這裡多一道，是為了連「滾動更新進行到一半、
# 新舊 pod 並存」那個瞬間都不去碰它。
#
# tag 用 `sort -Vr` 排序：本專案的 tag 形如 `237-dfdace9`，版本排序能正確處理
# 84 < 220 < 237（字典序會把 84 排在 220 後面）。對沒有數字前綴的 tag
# （latest、v1.2）它一樣給得出穩定順序，不會因為排不出來就把整個 repo 清光。
prune_k3s_images() {
  has_k3s || {
    echo "k3s 不可用，跳過映像回收"
    return 0
  }

  local in_use listing repos repo tags keep victims keep_ids tag id out
  local removed=0 skipped=0

  in_use="$(k3s crictl ps -a -o json 2>/dev/null | grep -o 'sha256:[a-f0-9]\{64\}' | sort -u)"
  # repo<TAB>tag<TAB>id；<none> 的 dangling 映像沒有 tag 可依據，留給緊急回收處理
  listing="$(k3s crictl images 2>/dev/null | awk 'NR > 1 && $2 != "<none>" { print $1"\t"$2"\t"$3 }')"
  [[ -n "$listing" ]] || {
    echo "    沒有可回收的映像"
    return 0
  }
  repos="$(cut -f1 <<<"$listing" | sort -u)"

  # 第一遍：決定每個 repository 留哪些 tag、刪哪些 tag
  keep=""
  victims=""
  while read -r repo; do
    [[ -n "$repo" ]] || continue
    tags="$(awk -F'\t' -v r="$repo" '$1 == r { print $2 }' <<<"$listing" | sort -Vr)"
    keep+="$(head -n "$KEEP_BUILDS" <<<"$tags" | awk -v r="$repo" '{ print r"\t"$0 }')"$'\n'
    victims+="$(tail -n "+$((KEEP_BUILDS + 1))" <<<"$tags" | awk -v r="$repo" '{ print r"\t"$0 }')"$'\n'
  done <<<"$repos"

  # 要保留的 tag 對應到哪些映像 ID。
  #
  # 這一步是必要的，不是多餘的保險：連續兩次 build 若產出的內容相同，會是
  # **同一個映像 ID 掛兩個 tag**（2026-09-19 實測 care-asr 的 237 與 238 就是）。
  # 而 crictl rmi 是「把名稱解析成映像 ID、再把整個映像移除」，不是只拿掉一個
  # tag —— 所以刪一個舊 tag 會連同共用該 ID 的新 tag 一起帶走，保留數形同虛設，
  # 下次 pod 重啟就得重新 pull。只能在刪之前先把保留側的 ID 圈起來避開。
  keep_ids="$(while IFS=$'\t' read -r repo tag; do
    [[ -n "$tag" ]] || continue
    awk -F'\t' -v r="$repo" -v t="$tag" '$1 == r && $2 == t { print $3 }' <<<"$listing"
  done <<<"$keep" | sort -u)"

  # 第二遍：逐個刪，三種情況都不碰
  while IFS=$'\t' read -r repo tag; do
    [[ -n "$tag" ]] || continue
    id="$(awk -F'\t' -v r="$repo" -v t="$tag" '$1 == r && $2 == t { print $3 }' <<<"$listing")"
    [[ -n "$id" ]] || continue

    # crictl images 的 ID 欄是截斷過的（13 碼），crictl ps 給的是完整 digest，
    # 所以用子字串比對；截斷 ID 是完整 digest 的前綴，這個方向是安全的。
    if grep -q -- "$id" <<<"$in_use"; then
      echo "    略過 ${repo}:${tag}（使用中）"
      skipped=$((skipped + 1))
      continue
    fi
    if grep -qx -- "$id" <<<"$keep_ids"; then
      echo "    略過 ${repo}:${tag}（與要保留的版本是同一個映像）"
      skipped=$((skipped + 1))
      continue
    fi

    if out="$(k3s crictl rmi "${repo}:${tag}" 2>&1)"; then
      echo "    已刪 ${repo}:${tag}"
      removed=$((removed + 1))
    elif grep -q "no such image" <<<"$out"; then
      # 同一個映像掛多個 tag 時，刪前一個就已經把整個映像移除了，後面這個
      # 自然找不到。這是正常路徑，不是錯誤。
      echo "    已隨其他 tag 一併移除 ${repo}:${tag}"
    else
      echo "    刪不掉 ${repo}:${tag}：$(tail -n 1 <<<"$out")"
    fi
  done <<<"$victims"

  echo "    回收 ${removed} 個、略過 ${skipped} 個，目前磁碟 $(disk_pct)%（可用 $(disk_avail)）"
}

# 緊急回收：分級升壓，每一級做完就重新量測，夠了就停手，不做多餘的破壞
emergency_prune() {
  local before
  before="$(disk_pct)"
  notify crit "磁碟達 ${before}%（門檻 ${CRIT_PCT}%），開始緊急回收"

  if has_docker; then
    echo "--- 第 1 級：清空全部 build cache ---"
    docker builder prune -a -f || true
    [[ "$(disk_pct)" -lt "$CRIT_PCT" ]] && {
      finish_emergency "$before"
      return 0
    }

    echo "--- 第 2 級：清掉未被任何容器使用的映像 ---"
    docker image prune -a -f || true
    [[ "$(disk_pct)" -lt "$CRIT_PCT" ]] && {
      finish_emergency "$before"
      return 0
    }
  fi

  if has_k3s; then
    echo "--- 第 3 級：清掉 k3s 未使用的映像 ---"
    k3s crictl rmi --prune || true
  fi

  finish_emergency "$before"
}

finish_emergency() {
  local before="$1" after
  after="$(disk_pct)"
  if [[ "$after" -lt "$CRIT_PCT" ]]; then
    notify notice "緊急回收完成：${before}% -> ${after}%（可用 $(disk_avail)）"
  else
    notify crit "緊急回收後仍達 ${after}%（可用 $(disk_avail)），已無自動手段可用，需要人工介入"
  fi
}

# --- 子命令 -------------------------------------------------------------------

cmd_status() {
  printf '掛載點      : %s\n' "$MOUNT"
  printf '磁碟使用    : %s%% (可用 %s)\n' "$(disk_pct)" "$(disk_avail)"
  printf 'inode 使用  : %s%%\n' "$(inode_pct)"
  printf '門檻        : WARN %s%% / CRIT %s%%\n' "$WARN_PCT" "$CRIT_PCT"
  if has_docker; then
    echo '--- docker system df ---'
    docker system df
  fi
}

cmd_check() {
  local pct inodes
  pct="$(disk_pct)"
  inodes="$(inode_pct)"

  if [[ "$pct" -ge "$CRIT_PCT" ]]; then
    emergency_prune
  elif [[ "$pct" -ge "$WARN_PCT" ]]; then
    notify warning "磁碟達 ${pct}%（可用 $(disk_avail)），已超過警戒 ${WARN_PCT}%，尚未觸發自動回收"
  else
    # 從告警狀態回到正常水位時送一則恢復通知，之後保持安靜。
    # 沒有這則通知的話，收到告警的人無從得知問題已經解決。
    if [[ "$(last_level)" != "ok" ]]; then
      notify notice "磁碟已回到 ${pct}%（可用 $(disk_avail)），低於警戒 ${WARN_PCT}%"
      record_state ok
    fi
  fi

  # inode 用盡同樣會讓 kubelet 判定 DiskPressure，但清 build cache 不見得救得回來，
  # 所以只告警不自動處理 —— 通常兇手是 node_modules 這類使用者資料，不該自動刪。
  if [[ "$inodes" -ge "$CRIT_PCT" ]]; then
    notify crit "inode 使用達 ${inodes}%，kubelet 可能因 inodesFree 觸發 DiskPressure，需人工清理小檔案"
  fi
}

case "${1:-status}" in
  status) cmd_status ;;
  check) cmd_check ;;
  prune) routine_prune ;;
  -h | --help) sed -n '2,33p' "$0" ;;
  *)
    echo "未知子命令: $1" >&2
    sed -n '2,25p' "$0" >&2
    exit 1
    ;;
esac
