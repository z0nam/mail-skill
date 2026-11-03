#!/usr/bin/env python3
"""날짜 범위 검색의 클라이언트측 폴백.

왜 필요한가
-----------
himalaya 는 날짜 조건을 IMAP `SENTSINCE`/`SENTBEFORE`(= Date: 헤더 기준)로만 보낸다.
그런데 일부 서버(확인됨: imap.worksmobile.com / 네이버웍스)는 이 검색어를 **거부하지 않고
받아준 뒤 항상 0건**을 돌려준다. Date 헤더를 색인하지 않기 때문이다. 같은 서버에서
`SINCE`(= INTERNALDATE 기준)는 정상 동작한다.

결과적으로 서버는 `OK 0건`이라 답하고, himalaya 는 빈 목록을 내고, 호출측은 그걸
"그 기간에 메일이 없다"로 읽는다. **에러가 아니라서 아무도 눈치채지 못한다.**
이 도구에서 가장 위험한 실패 모드다.

그래서 서버측 날짜 검색이 0건을 낼 때, 여기서 봉투를 직접 훑어 클라이언트에서 거른다.
봉투는 최신순이므로 `after` 경계보다 오래된 메일이 나오면 멈춘다 — 최근 며칠을 묻는
브리핑/worklog 용례에선 보통 한 페이지로 끝난다.

경계 의미는 himalaya 와 맞춘다: `after`/`before` 는 **배타적**, `date` 는 일치.
"""
import json
import os
import re
import subprocess
import sys

PAGE_STEPS = (200, 1000, 5000)  # 점증. 마지막까지 경계를 못 넘으면 잘렸다고 알린다.
DATE_RE = re.compile(r"(\d{4})-(\d{2})-(\d{2})")


def day(s):
    """봉투 date 문자열 앞부분의 YYYY-MM-DD 만 취해 비교 가능한 튜플로."""
    m = DATE_RE.match(s or "")
    return tuple(int(g) for g in m.groups()) if m else None


def parse_bound(s):
    m = DATE_RE.fullmatch(s.strip())
    if not m:
        sys.exit(f"date-search: 날짜 형식이 아님: {s!r} (YYYY-MM-DD)")
    return tuple(int(g) for g in m.groups())


def fetch(acct, folder, size):
    cmd = [os.environ.get("HIMALAYA_BIN", "himalaya"), "envelope", "list", "-a", acct]
    if folder:
        cmd += ["-f", folder]
    cmd += ["--page-size", str(size), "-o", "json"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        # 봉투가 0통인 폴더에서 himalaya 가 "page out of bounds" 로 죽는 케이스.
        if "out of bounds" in (p.stderr or ""):
            return []
        sys.stderr.write(p.stderr)
        sys.exit(f"date-search: 봉투 조회 실패 (exit {p.returncode})")
    return json.loads(p.stdout or "[]")


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: date-search.py <acct> <folder|-> [after=YYYY-MM-DD] "
                 "[before=YYYY-MM-DD] [date=YYYY-MM-DD]")
    acct = sys.argv[1]
    folder = None if sys.argv[2] == "-" else sys.argv[2]
    after = before = exact = None
    for arg in sys.argv[3:]:
        k, _, v = arg.partition("=")
        if k == "after":
            after = parse_bound(v)
        elif k == "before":
            before = parse_bound(v)
        elif k == "date":
            exact = parse_bound(v)
        else:
            sys.exit(f"date-search: 알 수 없는 인자 {arg!r}")
    if after is None and before is None and exact is None:
        sys.exit("date-search: 날짜 조건이 하나도 없음")

    # 하한(이보다 오래되면 더 볼 필요 없음). exact 는 그 날짜가 곧 하한.
    floor = exact or after

    envelopes, truncated = [], False
    for size in PAGE_STEPS:
        envelopes = fetch(acct, folder, size)
        if floor is None:
            # 상한만 있으면 전수 확인이 필요하다 — 최신순이라 조기 종료 불가.
            truncated = len(envelopes) >= size
            break
        oldest = day(envelopes[-1].get("date")) if envelopes else None
        # 마지막 봉투가 하한보다 오래됐다면 경계를 넘겼다 = 더 가져올 필요 없음.
        if len(envelopes) < size or (oldest is not None and oldest <= floor):
            break
    else:
        truncated = True

    out = []
    for e in envelopes:
        d = day(e.get("date"))
        if d is None:
            continue
        if exact is not None and d != exact:
            continue
        if after is not None and not d > after:
            continue
        if before is not None and not d < before:
            continue
        out.append(e)

    if truncated:
        # 잘린 결과를 조용히 내주면 호출측은 그걸 완전한 답으로 읽는다 —
        # 이 도구에서 가장 위험한 실패 모드다. stdout 을 비우고 실패로 끝낸다.
        sys.exit(f"date-search: {PAGE_STEPS[-1]}통까지 훑었으나 요청 기간의 시작점에 "
                 "도달하지 못했습니다. 기간을 좁혀 다시 조회하십시오. "
                 "(잘린 결과를 내보내지 않고 실패로 처리합니다)")

    json.dump(out, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
