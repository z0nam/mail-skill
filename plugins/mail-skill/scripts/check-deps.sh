#!/usr/bin/env bash
# mail-skill 의존성 점검 — himalaya, age 가 있는지 확인하고 없으면 설치법 안내.
ok=0
for tool in himalaya age; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "✓ $tool: $(command -v "$tool")"
  else
    ok=1
    echo "✗ $tool 없음 —"
    if [ "$(uname)" = "Darwin" ]; then echo "    brew install $tool"
    else echo "    apt install $tool   (또는 cargo install $tool / rage)"; fi
  fi
done
[ "$ok" = 0 ] && echo "모든 의존성 충족." || { echo "위 도구를 설치한 뒤 다시 셋업하세요."; exit 1; }
