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
| `scripts/convert-local.py` | Apple Mail 로컬(.emlx) → Maildir 일괄 변환(읽기/검색용) |
| `scripts/sent-to-dayone.py` | 특정 Maildir의 보낸메일 → Day One 저널(작성시각 보존) |
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

## 어댑터 계약
```sh
mailskill accounts                     # 계정 목록(JSON)
mailskill list   <acct> [n]            # 최근 n통
mailskill search <acct> <query...>     # IMAP 쿼리 검색
mailskill read   <acct> <id> [folder]  # 메시지 읽기
mailskill reply  <acct> <id>           # 회신 초안 (발송은 사용자 승인 후)
```

## 시크릿 모델 (멀티머신)
- `secrets/recipients.txt` = 기계별 age **공개키**(커밋 OK). `secrets/secrets.age` = 그 전원에게 암호화된 비번 묶음(커밋 OK, 내용은 암호화).
- 기계별 **개인키** `~/.config/mail-mcp/age-key.txt` 는 **절대 커밋/공유 금지**.
- 새 기계: bootstrap → 출력된 공개키를 `recipients.txt`에 추가 → 기존 기계에서 `secret-edit` 저장(재암호화) → push → 새 기계 pull.

## 라이선스 / 기여
MIT. Himalaya 관련 개선은 [upstream](https://github.com/pimalaya/himalaya)에 PR 권장.
