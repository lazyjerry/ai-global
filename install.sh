#!/bin/bash

# AI Global Installation Script
# Usage: curl -fsSL https://raw.githubusercontent.com/lazyjerry/ai-global/main/install.sh | bash

set -e

# 取得最新 release tag，依序嘗試三種來源，成功即輸出 tag：
#   1. gh api：走已登入帳號的認證額度
#   2. GitHub API：有 GITHUB_TOKEN 時帶認證；未認證時每個 IP 每小時只有 60 次
#   3. 網頁 releases/latest 的轉址：不經 API，不受上述限流
# 全部失敗時把各來源的失敗原因寫到 stderr，回傳 1。
# 與 ai-global 的 fetch_latest_tag 同一套邏輯：安裝時主程式還沒下載，無法 source，
# 只能各留一份；改其中一份時另一份要一起改。
# 本檔有 set -e，curl 的指派都要補 || true，網路錯誤才不會直接中止安裝。
fetch_latest_tag() {
  local repo="$1"
  local tag
  local -a reasons=()

  if command -v gh > /dev/null 2>&1; then
    # gh api 失敗時會把錯誤 JSON 印到 stdout，要連同回傳值一起判斷
    if tag=$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2> /dev/null) && [[ -n "$tag" ]]; then
      echo "$tag"
      return 0
    fi
    reasons+=("gh api：查詢失敗（未登入、沒有 release 或網路問題）")
  fi

  local -a auth_args=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth_args=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  local response status
  response=$(curl -sSL --max-time 15 ${auth_args[@]+"${auth_args[@]}"} -w '\n%{http_code}' \
    "https://api.github.com/repos/$repo/releases/latest" 2> /dev/null) || true
  status="${response##*$'\n'}"
  if [[ "$status" == "200" ]]; then
    tag=$(echo "$response" | grep '"tag_name"' | sed 's/.*"tag_name": "\(.*\)".*/\1/') || true
    if [[ -n "$tag" ]]; then
      echo "$tag"
      return 0
    fi
    reasons+=("GitHub API：回應中沒有 tag_name")
  elif [[ "$status" == "403" || "$status" == "429" ]]; then
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      reasons+=("GitHub API：HTTP ${status}，限流或 GITHUB_TOKEN 權限不足")
    else
      reasons+=("GitHub API：HTTP ${status}，未認證請求已達限流（每 IP 每小時 60 次），可設定 GITHUB_TOKEN 或執行 gh auth login")
    fi
  else
    reasons+=("GitHub API：HTTP ${status:-000}")
  fi

  local redirect
  redirect=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code} %{redirect_url}' \
    "https://github.com/$repo/releases/latest" 2> /dev/null) || true
  if [[ "$redirect" == *"/releases/tag/"* ]]; then
    echo "${redirect##*/releases/tag/}"
    return 0
  fi
  reasons+=("releases/latest 轉址：HTTP ${redirect%% *}")

  echo "無法取得最新版本：" >&2
  local reason
  for reason in "${reasons[@]}"; do
    echo "  $reason" >&2
  done
  return 1
}

main() {
  REPO="lazyjerry/ai-global"
  CONFIG_DIR="$HOME/.ai-global"

  BLUE='\033[0;34m'
  GREEN='\033[0;32m'
  GRAY='\033[0;90m'
  NC='\033[0m'

  echo "正在安裝 AI Global..."

  # 取得最新 release tag；全部來源都失敗才退回 main 分支
  if ! LATEST_TAG=$(fetch_latest_tag "$REPO"); then
    echo "改用 main 分支" >&2
    LATEST_TAG="main"
  fi

  # 建立設定目錄
  mkdir -p "$CONFIG_DIR"

  # 從 raw.githubusercontent.com 下載主程式，不經 API、不受限流。
  # tag 內容不會變，CDN 快取不影響正確性；只有退回 main 時可能拿到幾分鐘前的版本。
  # 先寫暫存檔、驗證是腳本後才搬進去，避免把錯誤頁面裝成主程式。
  local exec_temp
  exec_temp=$(mktemp)
  if ! curl -fsSL "https://raw.githubusercontent.com/$REPO/$LATEST_TAG/ai-global" -o "$exec_temp"; then
    rm -f -- "$exec_temp"
    echo "下載主程式失敗（ref: ${LATEST_TAG}）" >&2
    exit 1
  fi
  if ! head -1 "$exec_temp" | grep -q '^#!/bin/bash'; then
    rm -f -- "$exec_temp"
    echo "下載的檔案不是有效的腳本（ref: ${LATEST_TAG}）" >&2
    exit 1
  fi
  chmod +x "$exec_temp"
  mv -- "$exec_temp" "$CONFIG_DIR/ai-global"

  # 從下載的腳本取得版本號
  VERSION=$(grep '^VERSION=' "$CONFIG_DIR/ai-global" | head -1 | sed 's/VERSION="//' | sed 's/"//')

  # 加入 PATH
  mkdir -p "$HOME/.local/bin"
  ln -sf "$CONFIG_DIR/ai-global" "$HOME/.local/bin/ai-global"

  # 檢查 ~/.local/bin 是否已在 PATH 中
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo ""
    echo "請將 ~/.local/bin 加入您的 PATH："
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi

  echo ""
  echo -e "${GREEN}[OK]${NC} AI Global v$VERSION 安裝完成！"
  echo ""
  echo -e "在 ~ ${GRAY}（或專案目錄）${NC}中執行 ${BLUE}ai-global${NC} 即可開始使用。"
  echo ""
}

main "$@"
