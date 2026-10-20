---
name: mail
description: Search, read, watch for new messages/replies, and draft replies to email across many accounts (Gmail + IMAP + local archives) for an AI agent. Use when the user wants to find emails, check an inbox, wait/poll for incoming replies, read a message, or draft a reply across their mail accounts. Korean or English both apply.
---

# mailskill — 멀티계정 메일 (엔진 중립 어댑터)

여러 메일 계정을 검색·읽기·수신 대기·회신초안 작성. **`mailskill` 어댑터**(`bin/mailskill`)를 통해 호출한다 — 백엔드는 현재 [Himalaya](https://github.com/pimalaya/himalaya)지만 어댑터 뒤에 숨어 있어 엔진을 바꿔도 사용법은 동일하다.

## 라우팅 (세 갈래)
- **주 Gmail 1계정**(설정의 `gmail` 계정) → OAuth Gmail 커넥터가 호스트에 있으면 사용(예: Claude/Codex Gmail connector). 커넥터가 노출되지 않았거나 재인증이 필요하면 사용자에게 연결/재인증을 안내한다. 앱비번이 없어 `mailskill`로는 못 붙으니, 커넥터를 쓸 수 없는 호스트에선 다른 계정으로 안내.
- **그 외 IMAP 계정** → `mailskill` 어댑터(Himalaya). 시크릿은 age 암호화(`mail-secret`)로 공급.
- **로컬 변환 아카이브**(읽기 전용 Maildir) → 같은 `mailskill` 어댑터로 검색/읽기.

요청이 어느 계정인지 불명확하면 `mailskill accounts`로 목록을 보고 판단하거나 사용자에게 묻는다.

## 어댑터 사용 (항상 JSON, `watch`/`reply`/`doctor` 제외)
```sh
mailskill accounts                      # 계정 목록
mailskill list   <acct> [-f <폴더>] [n]  # 최근 n통 (폴더 미지정 시 INBOX)
mailskill search <acct> [-f <폴더>] <query...>   # 쿼리 검색 (문법은 아래)
mailskill read   <acct> <id> [folder]   # 메시지 읽기
mailskill folders <acct>                # 폴더 목록
mailskill reply  <acct> <id>            # 회신 초안 (대화형 $EDITOR)
mailskill send   <acct> [옵션...]       # 메일 발송/비대화형 답장 (미리보기 기본, --send 로 실전송)
mailskill watch  <acct> [옵션...]       # 새 메일/회신 폴링 대기 (별칭: mail-watch)
```
멀티계정 횡단 검색은 `mailskill accounts`로 이름을 얻어 각 계정에 `search`를 돌리고 합친다.

### search 쿼리 문법
조건: `date <yyyy-mm-dd>` `before <날짜>` `after <날짜>` `from <패턴>` `to <패턴>`
`subject <패턴>` `body <패턴>` `flag <플래그>`.
연산자: `and` `or` `not`. 정렬: `order by date desc` 등.

```sh
mailskill search ji after 2026-06-16 and before 2026-06-18
mailskill search ji subject 송장 and from example.com
mailskill search ji after 2026-07-01 order by date desc
mailskill search ji -f "Sent Messages" after 2026-07-01   # 보낸편지함
```

폴더 이름은 계정마다 다르다(`Sent` / `Sent Messages` / `보낸메일함` …).
`mailskill folders <acct>` 로 실제 이름을 먼저 확인할 것.

> **`since` 는 없다.** 기간 필터는 `after`/`before` 를 `and` 로 묶는다.
> 잘못된 쿼리는 exit 1 + stderr 에러로 떨어진다(빈 결과와 구분됨).
> `after`/`before` 경계는 **배타적**이다 — 7/1 을 포함하려면 `after 2026-06-30`.

날짜 검색은 서버가 0건을 답하면 **어댑터가 클라이언트측으로 자동 재확인**한다.
일부 IMAP 서버(네이버웍스 등)가 himalaya 의 `SENTSINCE`/`SENTBEFORE` 에 에러 없이
늘 0건을 답하기 때문이다. 사용자는 신경 쓸 필요 없다 — 결과만 맞으면 된다.
(자세한 배경: `scripts/date-search.py` 머리말)

> 자동 재확인은 **날짜 조건만으로 이루어진 질의**(`and` 결합, `order by` 꼬리 허용)에만
> 적용된다. 날짜+`from`/`subject` 복합 질의가 네이버웍스류 계정에서 0건이면 오탐일 수
> 있다 — 그 땐 **날짜만으로 검색한 뒤 나머지 조건은 결과 JSON 에서 직접 필터링**할 것.

### 출력 계약
JSON 동사(`accounts`/`folders`/`list`/`search`/`read`)는 **stdout 에 JSON 만** 낸다.
경고·에러·진단은 전부 stderr. 따라서 두 스트림을 합쳐 받는 호출측(에이전트의 Bash 도구)도
그대로 파싱하면 된다. 실패는 exit code 로 판별한다 — stdout 이 비어 있으면 실패다.
백엔드 로그를 보려면 `MAILSKILL_LOG=debug`(stderr 로만 나감).

`read` 만 모양이 다르다 — 배열·객체가 아니라 **JSON 문자열 스칼라 하나**다.
헤더와 본문이 `\n` 으로 이어진 메시지 전문이 통째로 들어 있다.

```
$ mailskill read ji 10895
"From: ...\nSubject: ...\n\n주무관님 안녕하세요.\n..."
```

파싱하면 `dict`/`list` 가 아니라 `str` 이 나온다. 제목·발신자만 필요하면 `list`/`search`
결과를 쓰고, 본문이 필요할 때만 `read` 한다.

## 새 메일 / 회신 대기 (`mailskill watch`)
상대방의 회신이나 특정 메일이 올 때까지 주기적으로 폴링한다. **회신을 기다릴 때는 백그라운드로 띄운다** (Claude Code의 Bash `run_in_background` 등 — 조건이 충족되어 프로세스가 종료되는 순간 세션이 깨어난다).

```sh
mailskill watch <acct> --from a@x,b@y [--subject 키워드] [--until 18:30] [--interval 300]
mailskill watch <acct> --subject "검토 의견" --timeout 2h
mailskill watch <acct> --from a@x --after-id 11090 --once
```

- **기준점 자동 감지**: `--after-id N`과 `--since 시각`을 모두 생략하면 **시작할 때 폴더의 최신 메일 ID를 자동으로 잡아** 그 이후에 도착하는 메일만 감시한다(수동 ID 입력 실수 방지). 이미 도착했을 수 있는 메일까지 포함해 찾으려면 `--after-id N` 또는 `--since HH:MM`(또는 `YYYY-MM-DD HH:MM`)을 명시한다.
- **필터**: `--from`은 콤마(`,`)로 여러 발신자를 지정하거나 옵션을 반복할 수 있으며 발신자 주소·이름 모두에 대소문자 무시 부분 일치한다. `--subject`는 제목 부분 일치다. 서버측 IMAP 검색 버그(네이버웍스 등)를 타지 않도록 최신 봉투 목록을 가져와 클라이언트에서 필터링한다.
- **종료 코드 (`pr-watch`와 동일 체계)**:
  - `0`: 새 메일 도착 — ID·보낸사람·제목·시각과 후속 `mailskill read` 명령을 출력하고 종료 (`--json` 지정 시 매칭 봉투 JSON 배열 출력)
  - `2`: 대기 시간 만료 (`--until` 또는 `--timeout` 도달, 혹은 `--once`에서 미도착)
  - `3`: 연속 백엔드 조회 실패 한도 초과 (기본 5회)
  - `1`: 초기 조회 실패(계정·인증 오류) 또는 인자 오류
- **한계**:
  - 세션을 닫으면 백그라운드 대기 프로세스도 함께 멈춘다.
  - 백그라운드 명령 종료 시 자동 웨이크업을 지원하지 않는 호스트(Codex 등)에서는 동기로 기다리는 용도로만 쓰인다.

## 회신/발송 (`mailskill send`) — 승인 필수
에이전트가 비대화형으로 메일을 발송하거나 회신할 때는 **반드시 `mailskill send`**를 사용한다 (himalaya 직접 호출 금지).

```sh
# 1) 일반 새 메일 발송 (기본: 미리보기)
mailskill send ji --to user@example.com --subject "안내" --body "본문입니다."
# 승인 후 실제 전송: 동일 명령에 --send 추가
mailskill send ji --to user@example.com --subject "안내" --body "본문입니다." --send

# 2) 비대화형 답장 (--reply-to <id>)
# 원 메일의 Message-ID 로 In-Reply-To/References 를 채우고, 제목 Re: 및 수신자 자동 매핑
mailskill send ji --reply-to 11127 --body "확인했습니다."
# 승인 후 실제 전송:
mailskill send ji --reply-to 11127 --body "확인했습니다." --send

# 3) 첨부파일 및 본문 파일
mailskill send ji --to user@example.com --subject "자료 송부" --body-file ./report.txt --attach ./file.pdf --send
```

### 안전 보호 장치 (이슈 #7 해결)
1. **미리보기 게이트**: `--send` 옵션이 없으면 절대 전송되지 않고 헤더와 본문 미리보기만 출력한다.
2. **중복 발송 가드**: `--send` 실행 직전 보낸편지함에서 최근 10분(기본) 내 **동일 수신자 + 동일 제목** 메일이 감지되면 발송을 차단(exit 3)하고 경고를 출력한다. 의도적인 재발송은 `--force` 플래그를 추가한다.
3. **APPEND-UID 오류 안전 처리**: 네이버웍스(`ji`) 등 일부 IMAP/SMTP 서버에서 SMTP 전송 성공 후 보낸편지함 저장 단계에서 `cannot find UID of appended IMAP message` 오류로 비정상 종료되는 현상이 있다. 메일은 이미 수신자에게 전송되었으므로, `mailskill send`는 이를 **발송 성공(보낸함 저장 확인 실패)으로 자동 분류하여 exit 0**으로 종료하고 "재시도 금지" 경고를 출력한다 (에이전트가 실패로 오인해 재전송하는 버그 원천 방지).
4. **한글 제목 RFC 2047 인코딩 보호**: `compose-mime.py`(파이썬 표준 라이브러리)를 통해 MIME을 조립하므로, 3바이트 UTF-8 한글 글자가 인코딩 단어 경계에서 쪼개지는 깨짐 현상이 발생하지 않는다.

## 시크릿 (age, 선택적 멀티머신)
비번은 `secrets/secrets.age`(age 암호화)에 있고 `auth.cmd = "mail-secret <name>"`가 복호화 공급. 기계별 키 `~/.config/mail-skill/age-key.txt`. macOS/Linux 공통. 디버그: `mail-secret <name>`.

## 트러블슈팅
> ⚠️ **`MAILSKILL_LOG=trace` 는 IMAP `AUTHENTICATE PLAIN` 줄을 그대로 찍는다** —
> 계정 비밀번호가 base64 로 로그에 남는다. 공유되는 터미널·트랜스크립트에서 쓰지 말 것.
> 대부분의 진단은 `debug` 로 충분하다.

- 연결/인증: `mailskill doctor <acct>`.
- 비번 조회 실패: `mail-secret <name>` 값 확인 → `scripts/secret-set <name>` 재등록.
- 새 기계: `scripts/bootstrap.sh`.
