---
name: mail
description: Search, read, and draft replies to email across many accounts (Gmail + IMAP + local archives) for an AI agent. Use when the user wants to find emails, check an inbox, read a message, or draft a reply across their mail accounts. Korean or English both apply.
---

# mailskill — 멀티계정 메일 (엔진 중립 어댑터)

여러 메일 계정을 검색·읽기·회신초안 작성. **`mailskill` 어댑터**(`bin/mailskill`)를 통해 호출한다 — 백엔드는 현재 [Himalaya](https://github.com/pimalaya/himalaya)지만 어댑터 뒤에 숨어 있어 엔진을 바꿔도 사용법은 동일하다.

## 라우팅 (세 갈래)
- **주 Gmail 1계정**(설정의 `gmail` 계정) → OAuth Gmail 커넥터가 호스트에 있으면 사용(예: Claude/Codex Gmail connector). 커넥터가 노출되지 않았거나 재인증이 필요하면 사용자에게 연결/재인증을 안내한다. 앱비번이 없어 `mailskill`로는 못 붙으니, 커넥터를 쓸 수 없는 호스트에선 다른 계정으로 안내.
- **그 외 IMAP 계정** → `mailskill` 어댑터(Himalaya). 시크릿은 age 암호화(`mail-secret`)로 공급.
- **로컬 변환 아카이브**(읽기 전용 Maildir) → 같은 `mailskill` 어댑터로 검색/읽기.

요청이 어느 계정인지 불명확하면 `mailskill accounts`로 목록을 보고 판단하거나 사용자에게 묻는다.

## 어댑터 사용 (항상 JSON)
```sh
mailskill accounts                      # 계정 목록
mailskill list   <acct> [-f <폴더>] [n]  # 최근 n통 (폴더 미지정 시 INBOX)
mailskill search <acct> [-f <폴더>] <query...>   # 쿼리 검색 (문법은 아래)
mailskill read   <acct> <id> [folder]   # 메시지 읽기
mailskill folders <acct>                # 폴더 목록
mailskill reply  <acct> <id>            # 회신 초안
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

## 회신/발송 — 승인 필수
1. 대상 메시지를 `read`로 파악.
2. 회신 초안(받는사람/제목/본문)을 **사용자에게 보여준다**.
3. **명시적 승인 후에만** 전송. 승인 없이는 절대 보내지 않는다. (connector는 `create_draft`로 초안만.)

## 시크릿 (age, 선택적 멀티머신)
비번은 `secrets/secrets.age`(age 암호화)에 있고 `auth.cmd = "mail-secret <name>"`가 복호화 공급. 기계별 키 `~/.config/mail-skill/age-key.txt`. macOS/Linux 공통. 디버그: `mail-secret <name>`.

## 트러블슈팅
> ⚠️ **`MAILSKILL_LOG=trace` 는 IMAP `AUTHENTICATE PLAIN` 줄을 그대로 찍는다** —
> 계정 비밀번호가 base64 로 로그에 남는다. 공유되는 터미널·트랜스크립트에서 쓰지 말 것.
> 대부분의 진단은 `debug` 로 충분하다.

- 연결/인증: `mailskill doctor <acct>`.
- 비번 조회 실패: `mail-secret <name>` 값 확인 → `scripts/secret-set <name>` 재등록.
- 새 기계: `scripts/bootstrap.sh`.
