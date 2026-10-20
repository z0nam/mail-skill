# mail-skill

여러 메일 계정(Gmail + IMAP + 로컬 아카이브)을 **AI 에이전트가 검색·읽기·회신초안**하도록 묶는 툴킷. "AI 기반 mail.app"의 재사용 가능한 코어 — Claude Code 스킬 + 엔진 중립 어댑터 + age 시크릿 관리.

> 메일 접속 엔진으로 [**Himalaya**](https://github.com/pimalaya/himalaya)(pimalaya)를 사용합니다. 훌륭한 도구를 만들어준 pimalaya에 감사드립니다. 개선점은 upstream에 기여하는 것을 지향합니다.

## 설계
- **엔진 중립 어댑터** `bin/mailskill` — 스킬/다른 스킬이 호출하는 안정적 계약(`accounts/list/search/read/reply`). 백엔드는 현재 Himalaya지만, 더 나은 도구로 갈아타면 **이 파일 하나만** 재구현하면 됨.
- **하이브리드 라우팅** — 주 Gmail 1계정은 OAuth connector, 그 외 IMAP은 Himalaya, 과거 메일은 로컬 변환 아카이브(Maildir).
- **age 시크릿** — 앱비번을 `secrets/secrets.age`(암호화)에 두고 git으로 여러 기계에 동기화, 기계별 age 키로 복호화. 평문 없음, macOS/Linux 공통(`security`/키체인 비의존).

## 구성
| 경로 | 역할 |
|---|---|
| `bin/mailskill` | 엔진 중립 어댑터(메인 인터페이스) |
| `.claude/skills/mail/` | Claude Code 스킬 |
| `scripts/mail-secret` | age에서 비번 조회(Himalaya `auth.cmd`가 호출) |
| `scripts/secret-set`/`secret-edit` | 시크릿 추가/편집(모든 recipient로 재암호화) |
| `scripts/bootstrap.sh` | 새 기계 셋업(deps + 심링크 + age 키) |
| `bin/mailskill.ps1`, `scripts/mail-secret.ps1`, `scripts/secret-set.ps1` | 위 3종의 **Windows 네이티브(PowerShell)** 포트 |
| `bin/*.cmd` (`mailskill`/`mail-secret`/`secret-set`) | Windows PATH 에서 bare 이름으로 부르는 shim |
| `scripts/bootstrap.ps1` | Windows 셋업(deps 안내 + age 키 + 심링크/복사) |
| `scripts/convert-local.py` | Apple Mail 로컬(.emlx) → Maildir 일괄 변환(읽기/검색용) |
| `scripts/sent-to-dayone.py` | 특정 Maildir의 보낸메일 → Day One 저널(작성시각 보존) |
| `scripts/mail-watch.py` | 새 메일/회신 폴링 대기(`mailskill watch` 백엔드, bash/ps1 공용) |
| `scripts/compose-mime.py` | raw MIME 메시지 조립 및 답장 헤더 자동 완성(bash/ps1 공용) |
| `scripts/dup-guard.py` | 보낸편지함 최근 발송 중복 가드(bash/ps1 공용) |
| `config/config.sample.toml`, `config/mbsyncrc.sample` | 템플릿 |

## 설치 (macOS 예)
```sh
brew install himalaya age          # 엔진 + 암호화
git clone <this-repo> ~/dev/mail-skill
~/dev/mail-skill/scripts/bootstrap.sh    # age 키 생성 + 심링크(config/스킬/mail-secret)
cp config/config.sample.toml ~/.config/himalaya/config.toml   # 계정 채우기
scripts/secret-set himalaya-<name>       # 계정별 앱비번 등록
mailskill accounts                            # 동작 확인
```
리눅스는 `age`/`himalaya`를 패키지매니저/`cargo`로 설치하고 `~/.local/bin`이 PATH에 있는지 확인.

## 설치 (Windows 네이티브)
Git Bash/WSL 없이 **PowerShell + cmd 만으로** 동작한다. 어댑터·시크릿 스크립트의 PowerShell 포트(`*.ps1`)와 PATH shim(`bin\*.cmd`)이 들어 있다.
```powershell
winget install pimalaya.himalaya FiloSottile.age   # 엔진 + 암호화 (또는 scoop)
git clone <this-repo> $HOME\dev\mail-skill
$HOME\dev\mail-skill\scripts\bootstrap.ps1          # age 키 + 심링크(개발자 모드 없으면 복사)
Copy-Item config\config.sample.toml $HOME\.config\himalaya\config.toml   # 계정 채우기
setx PATH "$env:PATH;$HOME\dev\mail-skill\bin"       # mailskill/mail-secret 를 PATH 에
# 새 터미널 열고:
mailskill accounts
secret-set himalaya-<name>                           # 계정별 앱비번 등록(숨김 입력)
```
- **PATH 의 `bin\` 이 핵심**이다. Himalaya 의 `auth.cmd = "mail-secret <name>"` 가 `mail-secret.cmd` 를 PATH 에서 찾아 비번을 얻는다 — 넣지 않으면 라이브 IMAP 인증이 실패한다.
- **심링크엔 개발자 모드(또는 관리자)** 가 필요하다. bootstrap.ps1 은 실패 시 복사로 폴백하지만, 복사하면 SSOT가 깨져(레포 수정이 반영 안 됨) 개발자 모드를 켜 심링크로 두길 권한다.
- **Python(선택)**: 날짜검색 클라이언트측 폴백(`date-search.py`)과 메일 수신 대기(`mail-watch.py`)에 쓴다. 없으면 대부분 동작하되, 일부 서버(네이버웍스 등)의 날짜검색 폴백과 `mailskill watch`가 안 된다.
- **caveat**: Himalaya 가 Windows 에서 `auth.cmd` 를 `cmd` 로 실행한다는 전제다(그럼 `.cmd` shim 이 걸린다). 만약 `sh` 로 실행하는 빌드라면 그 경우엔 Git Bash 의 bash `mail-secret` 이 대신 쓰인다. 실기계 최초 셋업 때 `mailskill doctor <acct>` 로 한 번 확인할 것.

## 어댑터 계약
```sh
mailskill accounts                     # 계정 목록(JSON)
mailskill list   <acct> [n]            # 최근 n통
mailskill search <acct> <query...>     # IMAP 쿼리 검색
mailskill read   <acct> <id> [folder]  # 메시지 읽기
mailskill reply  <acct> <id>           # 회신 초안 (대화형 $EDITOR)
mailskill send   <acct> [옵션...]      # 메일 발송/비대화형 답장 (미리보기 기본, --send 로 실전송)
mailskill watch  <acct> [옵션...]      # 새 메일/회신 폴링 대기 (도착 exit 0, 만료 exit 2)
```

## 시크릿 모델 (멀티머신)
- `secrets/recipients.txt` = 기계별 age **공개키**(커밋 OK). `secrets/secrets.age` = 그 전원에게 암호화된 비번 묶음(커밋 OK, 내용은 암호화).
- 기계별 **개인키** `~/.config/mail-skill/age-key.txt` 는 **절대 커밋/공유 금지**.
- 새 기계: bootstrap → 출력된 공개키를 `recipients.txt`에 추가 → 기존 기계에서 `secret-edit` 저장(재암호화) → push → 새 기계 pull.

## 라이선스 / 기여
MIT. Himalaya 관련 개선은 [upstream](https://github.com/pimalaya/himalaya)에 PR 권장.
