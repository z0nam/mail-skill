#!/usr/bin/env bash
# 새 기계 셋업 — 기계당 한 번. deps 설치 + age 키 생성 + 심링크.
# 끝나면 출력되는 '이 기계 공개키'를 다른(등록된) 기계에서 recipients.txt 에 추가하고
# secret-edit 로 재암호화·push → 이 기계에서 git pull 하면 비번 복호화 가능.
set -euo pipefail
_self="$0"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t";; *) _self="$(dirname "$_self")/$_t";; esac; done
REPO="${MAIL_SKILL_REPO:-$(cd "$(dirname "$_self")/.." && pwd)}"
cd "$REPO"

# 1) 의존성 확인 (선언만, 자가설치 안 함 — TS-RUNTIME-2)
if [ "$(uname)" = "Darwin" ]; then
  BINDIR="/opt/homebrew/bin"; [ -d "$BINDIR" ] || BINDIR="/usr/local/bin"
else
  BINDIR="$HOME/.local/bin"; mkdir -p "$BINDIR"
fi

for p in himalaya age; do
  if ! command -v "$p" >/dev/null 2>&1; then
    echo "⚠ '$p' 설치 필요 (선언만, 자가설치 안 함 — brew install $p 또는 apt install $p / cargo install $p)"
  fi
done

if ! command -v uv >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
  echo "⚠ Python 필요: send·watch·attachment에 필수이며, 런타임은 스스로 설치하지 않고(TS-RUNTIME-2) jaix setup(또는 사용자가 uv/python)이 제공합니다."
fi

# 2) age 키 (기계별, 절대 동기화 안 함)
# 경로는 리졸버(mail-secret)·README 와 일치해야 한다: mail-skill (과거 mail-mcp 였음).
mkdir -p "$HOME/.config/mail-skill"
KEY="$HOME/.config/mail-skill/age-key.txt"
if command -v age-keygen >/dev/null 2>&1; then
  [ -f "$KEY" ] || { age-keygen -o "$KEY"; chmod 600 "$KEY"; }
  PUB="$(age-keygen -y "$KEY")"
else
  PUB="(age-keygen 없음 — age 설치 후 다시 실행 필요)"
fi

# 3) 심링크: himalaya config / mail 스킬 / mail-secret(PATH)
mkdir -p "$HOME/.config/himalaya" "$HOME/.claude/skills"
ln -sfn "$REPO/config/config.toml"      "$HOME/.config/himalaya/config.toml"
ln -sfn "$REPO/.claude/skills/mail"     "$HOME/.claude/skills/mail"
ln -sfn "$REPO/scripts/mail-secret"     "$BINDIR/mail-secret"
ln -sfn "$REPO/bin/mailskill"            "$BINDIR/mailskill"
ln -sfn "$REPO/scripts/mail-watch.py"    "$BINDIR/mail-watch"
echo "심링크 완료: himalaya config, mail 스킬, mail-secret/mailskill/mail-watch($BINDIR)"

echo
echo "── 이 기계 age 공개키 ──"
echo "  $PUB"
echo "→ 등록된 기계에서 secrets/recipients.txt 에 추가 후 'scripts/secret-edit' 저장 → push."
echo "  그 다음 이 기계에서 git pull 하면 끝."
case ":$PATH:" in *":$BINDIR:"*) ;; *) echo "⚠ $BINDIR 가 PATH 에 없음 — 셸 rc 에 추가 필요";; esac
