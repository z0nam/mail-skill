---
name: mail
description: Search, read, and draft replies to email across many accounts (Gmail + IMAP + local archives) for an AI agent. Use when the user wants to find emails, check an inbox, read a message, or draft a reply across their mail accounts. Korean or English both apply.
---

# mailskill — 멀티계정 메일 (엔진 중립 어댑터)

여러 메일 계정을 검색·읽기·회신초안 작성. **`mailskill` 어댑터**(`bin/mailskill`)를 통해 호출한다 — 백엔드는 현재 [Himalaya](https://github.com/pimalaya/himalaya)지만 어댑터 뒤에 숨어 있어 엔진을 바꿔도 사용법은 동일하다.

## 라우팅 (세 갈래)
- **주 Gmail 1계정** → Claude Gmail connector(`mcp__claude_ai_Gmail__*`)가 있으면 그걸 사용(OAuth, 앱비번 불필요).
- **그 외 IMAP 계정** → `mailskill` 어댑터(Himalaya). 시크릿은 age 암호화(`mail-secret`)로 공급.
- **로컬 변환 아카이브**(읽기 전용 Maildir) → 같은 `mailskill` 어댑터로 검색/읽기.

요청이 어느 계정인지 불명확하면 `mailskill accounts`로 목록을 보고 판단하거나 사용자에게 묻는다.

## 어댑터 사용 (항상 JSON)
```sh
mailskill accounts                      # 계정 목록
mailskill list   <acct> [n]             # 최근 n통
mailskill search <acct> <query...>      # IMAP 쿼리 (예: subject "송장" / from foo.com since 2026-01-01)
mailskill read   <acct> <id> [folder]   # 메시지 읽기
mailskill folders <acct>                # 폴더 목록
mailskill reply  <acct> <id>            # 회신 초안
```
멀티계정 횡단 검색은 `mailskill accounts`로 이름을 얻어 각 계정에 `search`를 돌리고 합친다.

## 회신/발송 — 승인 필수
1. 대상 메시지를 `read`로 파악.
2. 회신 초안(받는사람/제목/본문)을 **사용자에게 보여준다**.
3. **명시적 승인 후에만** 전송. 승인 없이는 절대 보내지 않는다. (connector는 `create_draft`로 초안만.)

## 시크릿 (age, 선택적 멀티머신)
비번은 `secrets/secrets.age`(age 암호화)에 있고 `auth.cmd = "mail-secret <name>"`가 복호화 공급. 기계별 키 `~/.config/mail-mcp/age-key.txt`. macOS/Linux 공통. 디버그: `mail-secret <name>`.

## 트러블슈팅
- 연결/인증: `mailskill doctor <acct>`.
- 비번 조회 실패: `mail-secret <name>` 값 확인 → `scripts/secret-set <name>` 재등록.
- 새 기계: `scripts/bootstrap.sh`.
