# Mail Skill (Claude Code plugin)

여러 메일 계정(Gmail + IMAP + 로컬 아카이브)을 **AI가 검색·읽기·회신초안**하게 해주는 스킬. 엔진 중립 어댑터(`mailskill`, 현재 [Himalaya](https://github.com/pimalaya/himalaya) 백엔드) + age 암호화 시크릿.

## 설치
```text
/plugin marketplace add z0nam/mail-skill
/plugin install mail-skill@mail-skill
/mail-skill:mailskill-setup
```
`mailskill-setup` 이 의존성(himalaya, age) 확인 → CLI를 PATH에 연결 → age 키 생성 → Himalaya 설정 뼈대 → 계정 비번 등록까지 안내합니다. (수동 설치는 아래 참고)

## 의존성
- [`himalaya`](https://github.com/pimalaya/himalaya) (메일 엔진) · [`age`](https://age-encryption.org) (시크릿 암호화)
- macOS: `brew install himalaya age`  ·  Linux: 패키지매니저 또는 `cargo install`

## 사용 (어댑터 계약)
```sh
mailskill accounts                  # 계정 목록(JSON)
mailskill list   <acct> [n]         # 최근 n통
mailskill search <acct> <query...>  # IMAP 쿼리 검색
mailskill read   <acct> <id>        # 메시지 읽기
mailskill reply  <acct> <id>        # 회신 초안 (발송은 사용자 승인 후)
```
또는 그냥 자연어로 "X 계정에서 … 메일 찾아줘" — `mail` 스킬이 알아서 라우팅.

## 시크릿 모델
앱비번은 `~/.config/mail-skill/secrets.age`(age 암호화) + 기계별 키 `~/.config/mail-skill/age-key.txt`. 평문 없음, macOS/Linux 공통.
- 등록: `scripts/secret-set himalaya-<name>` (config의 `auth.cmd = "mail-secret himalaya-<name>"` 와 일치)
- 여러 기계 git-동기화를 원하면 시크릿을 별도 private 레포의 `secrets/secrets.age` 에 두고 `MAIL_SKILL_SECRETS` 로 지정(고급).

## 구글 계정
Himalaya 라이브 접속은 계정마다 2단계인증+앱비번 필요. 주 Gmail 1개는 Claude Gmail connector(OAuth)로, 과거 메일은 `scripts/convert-local.py`(Apple Mail 로컬 → Maildir, 읽기 전용)로 붙일 수 있습니다.

## 엔진 교체
`mailskill` 은 얇은 어댑터입니다. 더 나은 메일 도구로 갈아타면 `bin/mailskill` **한 파일만** 다시 구현하면 스킬·계약은 그대로.

## 크레딧 / 라이선스
메일 엔진 [Himalaya](https://github.com/pimalaya/himalaya) by pimalaya — 감사합니다. MIT.
