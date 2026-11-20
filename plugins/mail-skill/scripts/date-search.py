#!/usr/bin/env python3
"""날짜 범위 검색 — 호환 껍데기 (#30 에서 search.py 로 흡수).

usage: date-search.py <acct> <folder|-> [after=YYYY-MM-DD] [before=YYYY-MM-DD] [date=YYYY-MM-DD]

himalaya 1.x 시절, 서버측 날짜 검색이 0건일 때 클라이언트측으로 재확인하던 도구다
(네이버웍스는 SENTSINCE/SENTBEFORE 에 늘 0건을 답한다 — 배경은 search.py 머리말).
2.x 이식 뒤로는 search.py 가 날짜 절을 처음부터 클라이언트에서 거르므로, 이 파일은
예전 인자 형식을 search.py 질의로 바꿔 넘기기만 한다. 출력·실패 규칙은 search.py 와 같다.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hjson  # noqa: E402
import search  # noqa: E402

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def main(argv):
    if len(argv) < 2:
        sys.exit("usage: date-search.py <acct> <folder|-> [after=YYYY-MM-DD] "
                 "[before=YYYY-MM-DD] [date=YYYY-MM-DD]")
    tokens = []
    for arg in argv[2:]:
        k, _, v = arg.partition("=")
        if k not in ("after", "before", "date"):
            sys.exit(f"date-search: 알 수 없는 인자 {arg!r}")
        if not DATE_RE.match(v.strip()):
            sys.exit(f"date-search: 날짜 형식이 아님: {v!r} (YYYY-MM-DD)")
        tokens += (["and"] if tokens else []) + [k, v.strip()]
    if not tokens:
        sys.exit("date-search: 날짜 조건이 하나도 없음")
    return search.main([argv[0], argv[1], "--"] + tokens)


if __name__ == "__main__":
    hjson.reconfigure_utf8()
    sys.exit(main(sys.argv[1:]))
