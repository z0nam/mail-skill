---
description: Set up mail-skill — check deps (himalaya, age), install CLIs to PATH, create age key, scaffold config, and guide account setup.
---

# mail-skill 셋업

사용자가 이 명령을 호출하면 아래를 **순서대로, 한 단계씩 확인하며** 진행한다. 각 단계는 사용자 환경(macOS/Linux)에 맞춰 안내한다. `${CLAUDE_PLUGIN_ROOT}` 는 설치된 플러그인 경로다.

## 1) 의존성 점검
```sh
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-deps.sh"
```
실패하면(himalaya/age 없음) 출력된 설치 명령을 사용자에게 안내하고, 설치 후 재실행하게 한다.

## 2) CLI 를 PATH 에 연결
`mailskill`(어댑터)와 `mail-secret`(시크릿 조회)를 PATH 에 심링크한다. macOS=`/opt/homebrew/bin`(없으면 `/usr/local/bin`), Linux=`~/.local/bin`(PATH 포함 확인).
```sh
BINDIR=/opt/homebrew/bin; [ -d "$BINDIR" ] || BINDIR=/usr/local/bin
[ "$(uname)" = Darwin ] || { BINDIR="$HOME/.local/bin"; mkdir -p "$BINDIR"; }
ln -sfn "${CLAUDE_PLUGIN_ROOT}/bin/mailskill"     "$BINDIR/mailskill"
ln -sfn "${CLAUDE_PLUGIN_ROOT}/scripts/mail-secret" "$BINDIR/mail-secret"
```

## 3) age 키 생성 (시크릿 암호화용, 기계별·비공유)
```sh
mkdir -p ~/.config/mail-skill
[ -f ~/.config/mail-skill/age-key.txt ] || { age-keygen -o ~/.config/mail-skill/age-key.txt; chmod 600 ~/.config/mail-skill/age-key.txt; }
# 이 기계 공개키를 recipients 에 등록(시크릿 암호화 대상)
age-keygen -y ~/.config/mail-skill/age-key.txt >> ~/.config/mail-skill/recipients.txt
sort -u -o ~/.config/mail-skill/recipients.txt ~/.config/mail-skill/recipients.txt
```

## 4) Himalaya 설정 뼈대
없으면 샘플을 복사해 사용자가 계정을 채우게 안내한다.
```sh
mkdir -p ~/.config/himalaya
[ -f ~/.config/himalaya/config.toml ] || cp "${CLAUDE_PLUGIN_ROOT}/config/config.sample.toml" ~/.config/himalaya/config.toml
```
사용자에게: `~/.config/himalaya/config.toml` 에 계정 블록을 추가하고, `auth.cmd = "mail-secret himalaya-<name>"` 형식으로 둘 것. 제공사별 호스트는 샘플 주석 참고.

## 5) 계정 비밀번호(앱비번) 등록
계정마다 (대개 앱 전용 비밀번호):
```sh
mail-secret-set() { "${CLAUDE_PLUGIN_ROOT}/scripts/secret-set" "$@"; }
# 예: 사용자가 직접 실행 (비번은 프롬프트로 안전 입력)
"${CLAUDE_PLUGIN_ROOT}/scripts/secret-set" himalaya-<name>
```
구글 계정은 2단계인증+앱비번 필요(또는 주 1계정은 Claude Gmail connector 사용). 자세한 건 플러그인 README.

## 6) 동작 확인
```sh
mailskill accounts
mailskill list <account> 5
```
계정이 보이고 메일이 조회되면 완료. 이후 자연어로 "X 계정에서 … 찾아줘" 처럼 mail 스킬을 쓰면 된다.

## 참고
- 시크릿 저장: `~/.config/mail-skill/secrets.age`(age 암호화) + 기계별 키. 평문 없음.
- 과거 메일을 로컬에서 끌어와 검색하려면 `scripts/convert-local.py`(Apple Mail → Maildir) 참고.
- 엔진(Himalaya)을 바꾸려면 `bin/mailskill` 한 파일만 재구현.
