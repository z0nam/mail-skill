#!/usr/bin/env bash
# 새 기계 셋업 — 기계당 한 번. deps 설치 + age 키 생성 + 심링크.
# 끝나면 출력되는 '이 기계 공개키'를 다른(등록된) 기계에서 recipients.txt 에 추가하고
# secret-edit 로 재암호화·push → 이 기계에서 git pull 하면 비번 복호화 가능.
set -euo pipefail
_self="$0"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t";; *) _self="$(dirname "$_self")/$_t";; esac; done
REPO="${MAIL_SKILL_REPO:-$(cd "$(dirname "$_self")/.." && pwd)}"
cd "$REPO"

# 1) 의존성
if [ "$(uname)" = "Darwin" ]; then
  command -v brew >/dev/null || { echo "Homebrew 필요: https://brew.sh"; exit 1; }
  for p in himalaya age; do command -v "$p" >/dev/null || brew install "$p"; done
  BINDIR="/opt/homebrew/bin"; [ -d "$BINDIR" ] || BINDIR="/usr/local/bin"
else
  for p in himalaya age; do command -v "$p" >/dev/null || echo "⚠ '$p' 설치 필요 (apt install $p / cargo install $p)"; done
  BINDIR="$HOME/.local/bin"; mkdir -p "$BINDIR"
fi

# 2) age 키 (기계별, 절대 동기화 안 함)
mkdir -p "$HOME/.config/mail-mcp"
KEY="$HOME/.config/mail-mcp/age-key.txt"
[ -f "$KEY" ] || { age-keygen -o "$KEY"; chmod 600 "$KEY"; }
PUB="$(age-keygen -y "$KEY")"

# 3) 심링크: himalaya config / mail 스킬 / mail-secret(PATH)
mkdir -p "$HOME/.config/himalaya" "$HOME/.claude/skills"
ln -sfn "$REPO/config/config.toml"      "$HOME/.config/himalaya/config.toml"
ln -sfn "$REPO/.claude/skills/mail"     "$HOME/.claude/skills/mail"
ln -sfn "$REPO/scripts/mail-secret"     "$BINDIR/mail-secret"
ln -sfn "$REPO/bin/mailskill"            "$BINDIR/mailskill"
echo "심링크 완료: himalaya config, mail 스킬, mail-secret($BINDIR)"

echo
echo "── 이 기계 age 공개키 ──"
echo "  $PUB"
echo "→ 등록된 기계에서 secrets/recipients.txt 에 추가 후 'scripts/secret-edit' 저장 → push."
echo "  그 다음 이 기계에서 git pull 하면 끝."
case ":$PATH:" in *":$BINDIR:"*) ;; *) echo "⚠ $BINDIR 가 PATH 에 없음 — 셸 rc 에 추가 필요";; esac
