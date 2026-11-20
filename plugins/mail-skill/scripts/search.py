#!/usr/bin/env python3
"""mailskill search 의 본체 — himalaya 2.2.1 + 날짜 조건 클라이언트측 처리 (#30).

usage: search.py <acct> <folder|-> -- <DSL 토큰...>

맨 키워드를 DSL 로 감싸는 일은 어댑터(search_query / ConvertTo-SearchQuery)가 하고,
그 결과 토큰을 여기로 넘긴다. 출력은 1.x 계약 모양의 봉투 배열(hjson.envelopes).

날짜 조건을 왜 서버에 보내지 않나
--------------------------------
himalaya 는 날짜 절을 IMAP `SENTON`/`SENTSINCE`(= Date: 헤더 기준)로 보낸다. 일부 서버
(확인됨: 네이버웍스)는 이 검색어를 거부하지 않고 **항상 0건**을 답한다. 1.x 시절엔 0건일 때만
클라이언트측으로 재확인했는데(date-search.py), 2.x 에서는 `before` 절이 없어져 `not after` 로
써야 하고, 웍스에선 그게 NOT(0건) = **전체**가 되어 0건 재확인에도 안 걸리는 조용한 오답이 된다.
그래서 날짜 절은 처음부터 서버 질의에서 빼고, 나머지 조건으로 받은 봉투를 여기서 날짜로 거른다.

- 경계는 1.x 와 같다: `after`/`before` 는 배타적, `date` 는 일치(Date: 헤더의 날짜).
- 날짜 절은 **최상위 and** 로만 결합할 수 있다. or/not/괄호 안의 날짜 절은 exit 2.
  (의미를 바꾸지 않고 클라이언트로 옮길 수 없으므로 조용히 틀리느니 거절한다.)
- 결과가 잘렸을 수 있으면(5000통 포화) 실패한다. 잘린 결과를 완전한 답처럼 내지 않는다.
"""
import itertools
import os
import re
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hjson  # noqa: E402

PAGE_STEPS = (200, 1000, 5000)
MAX_COMBOS = 16  # body 분해 때 서버 질의 조합 수 상한(키워드 4개 = 2^4)
DATE_KW = ("after", "before", "date")
FIELD_KW = ("from", "to", "subject", "body", "flag")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DAY_RE = re.compile(r"(\d{4})-(\d{2})-(\d{2})")


class QueryError(Exception):
    pass


def tokenize(q):
    """himalaya 질의 문자열을 토큰으로. 원문 조각(역슬래시 이스케이프·따옴표 포함)을 보존한다."""
    toks, i, n = [], 0, len(q)
    while i < n:
        c = q[i]
        if c.isspace():
            i += 1
        elif c in "()":
            toks.append(c)
            i += 1
        elif c == '"':
            j = q.find('"', i + 1)
            if j < 0:
                raise QueryError("닫히지 않은 따옴표")
            toks.append(q[i:j + 1])
            i = j + 1
        else:
            j = i
            while j < n and not q[j].isspace() and q[j] not in "()":
                j += 2 if q[j] == "\\" and j + 1 < n else 1
            toks.append(q[i:j])
            i = j
    return toks


def render(toks):
    """토큰 → 질의 문자열. 괄호는 이웃 토큰에 붙인다(2.2.1 은 '( subject' 를 거부, 실측)."""
    out = ""
    for t in toks:
        if not out:
            out = t
        elif t == ")" or out.endswith("("):
            out += t
        else:
            out += " " + t
    return out


def value_mask(toks):
    """각 토큰이 필드 값(패턴·날짜) 자리인지. `subject and` 의 and 처럼 연산자 이름의 패턴을
    연산자로 오인하지 않으려고 쓴다(Codex 리뷰, #36)."""
    mask, expect_value = [], False
    for t in toks:
        if expect_value and t not in ("(", ")"):
            mask.append(True)
            expect_value = False
            continue
        mask.append(False)
        expect_value = t in FIELD_KW or t in DATE_KW
    return mask


def split_query(tokens):
    """→ (서버에 보낼 필터 토큰, 정렬 꼬리 토큰, 날짜 조건 [(kw, 'YYYY-MM-DD')])."""
    toks = tokenize(" ".join(tokens))
    order = []
    mask = value_mask(toks)
    for i in range(len(toks) - 1):
        if toks[i] == "order" and toks[i + 1] == "by" and not mask[i]:
            toks, order, mask = toks[:i], toks[i:], mask[:i]
            break

    # 최상위(depth 0) 연산자 위치와 날짜 절 위치. 필드 값 자리의 토큰은 연산자·키워드로 보지 않는다.
    date_at, top_and, top_or = [], [], False
    depth = 0
    for i, t in enumerate(toks):
        if mask[i]:
            continue
        if t in DATE_KW and i + 1 < len(toks) and DATE_RE.match(toks[i + 1]):
            date_at.append((i, depth))
        if t == "(":
            depth += 1
        elif t == ")":
            depth -= 1
        elif depth == 0 and t == "and":
            top_and.append(i)
        elif depth == 0 and t == "or":
            top_or = True
    if not date_at:
        return toks, order, []

    # 최상위 and 로만 묶였는지: 최상위 or 가 없고, 각 날짜 절이 depth 0 이며 앞이 not 이 아님
    bad = top_or or any(d != 0 or (i and toks[i - 1] == "not" and not mask[i - 1]) for i, d in date_at)
    if bad:
        raise QueryError("날짜 조건(after/before/date)은 최상위 and 로만 결합할 수 있습니다 - "
                         "or/not/괄호 안의 날짜 조건은 지원하지 않습니다(조용한 오답 방지). "
                         "날짜로 검색한 뒤 나머지 조건은 결과 JSON 에서 거르십시오.")

    # 최상위 and 로 가른 조각(conjunct) 중 날짜 절 조각만 빼고 다시 and 로 잇는다.
    cuts = [-1] + top_and + [len(toks)]
    parts = [toks[cuts[k] + 1:cuts[k + 1]] for k in range(len(cuts) - 1)]
    dates, keep = [], []
    for part in parts:
        if len(part) == 2 and part[0] in DATE_KW and DATE_RE.match(part[1]):
            dates.append((part[0], part[1]))
        elif part:
            keep.append(part)
    if len(dates) != len(date_at):  # 날짜 절이 다른 조건과 한 조각에 섞임(예: 'not' 없이 붙은 이상한 꼴)
        raise QueryError("날짜 조건을 다른 조건과 분리할 수 없습니다 - 'and' 로 구분하십시오.")
    cleaned = []
    for part in keep:
        if cleaned:
            cleaned.append("and")
        cleaned.extend(part)
    return cleaned, order, dates


def day(s):
    m = DAY_RE.match(s or "")
    return tuple(int(g) for g in m.groups()) if m else None


def bound(v):
    return tuple(int(x) for x in v.split("-"))


def date_ok(d, dates):
    for kw, v in dates:
        b = bound(v)
        if kw == "after" and not d > b:
            return False
        if kw == "before" and not d < b:
            return False
        if kw == "date" and d != b:
            return False
    return True


def _conjuncts(toks):
    """최상위 and 로 가른 조각들. 최상위 or 가 있으면 질의 전체가 한 조각이다."""
    mask = value_mask(toks)
    parts, cur, depth = [], [], 0
    for i, t in enumerate(toks):
        if not mask[i]:
            if t == "(":
                depth += 1
            elif t == ")":
                depth -= 1
            elif depth == 0 and t == "or":
                return [toks]
            elif depth == 0 and t == "and":
                parts.append(cur)
                cur = []
                continue
        cur.append(t)
    parts.append(cur)
    return parts


def _flat_or(part):
    """`(f1 v1 or f2 v2 ...)` 또는 `f1 v1 or f2 v2` 꼴이면 [(필드, 값)...], 아니면 None."""
    if len(part) >= 2 and part[0] == "(" and part[-1] == ")":
        part = part[1:-1]
    if len(part) < 2 or len(part) % 3 != 2:
        return None
    out = []
    for k in range(0, len(part), 3):
        f, v = part[k], part[k + 1]
        if f not in FIELD_KW or v in ("(", ")") or (k + 2 < len(part) and part[k + 2] != "or"):
            return None
        out.append((f, v))
    return out


def body_split(flt):
    """본문(body) 절이 든 OR 묶음을 서버 질의 여러 개로 쪼갤 계획. 해당 없으면 None.

    웍스는 BODY 가 든 IMAP 검색에 늘 0건을 답한다 — `subject X or body X` 처럼 OR 로 묶어도
    0건이라 맨 키워드 검색이 통째로 [] 가 됐다(#30 실기). 그래서 최상위 and 의 각 조각 중
    body 가 든 평평한 OR 묶음은 disjunct 마다 따로 서버에 묻고 id 합집합을 내고, 조각끼리는
    교집합을 낸다(실제로는 조합마다 나머지 조건을 실어 묻는다 — search 참고). 정상 서버에선 결과가 같고, 웍스에선 제목 일치만 남는다(본문 일치는 못 잡음).
    → (나머지 조각 토큰[], [[(f, v)...] per OR 묶음])
    """
    parts = _conjuncts(flt) if flt else None
    if not parts:
        return None
    rest, groups = [], []
    for part in parts:
        g = _flat_or(part)
        if g and any(f == "body" for f, _ in g):
            groups.append(g)
        else:
            if rest:
                rest.append("and")
            rest.extend(part)
    return (rest, groups) if groups else None


def past_floor(oldest, dates):
    """최신순으로 받다가 이 날짜(oldest)까지 왔으면 더 오래된 메일은 어느 것도 날짜 조건을 못 맞추는가.

    경계는 date_ok 와 같다: `after` 는 배타적(d > b)이라 oldest <= b 면 끝, `date` 는 포함(d == b)이라
    oldest < b 일 때만 끝이다 — `<=` 로 멈추면 그날 메일이 한 페이지를 넘을 때 나머지를 놓친다(Codex P2, #39).
    `before` 는 하한이 아니라 무관. 날짜 절은 and 로만 묶이므로 하나라도 끝났으면 전체가 끝이다.
    """
    for kw, v in dates:
        b = bound(v)
        if (kw == "after" and oldest <= b) or (kw == "date" and oldest < b):
            return True
    return False


def fetch(sub, base, query, dates, newest_first):
    """한 서버 질의를 잘리지 않게(200→1000→5000) 받는다."""
    for size in PAGE_STEPS:
        # 조건 검색(envelope search)은 결과가 걸러진 소수라 첨부 여부(IMAP 은 envelope 마다 조회 1회)를
        # 채운다. 날짜만인 질의는 폴더를 훑는 list 라 비용이 커서 채우지 않는다(has_attachment=null).
        att = ["--has-attachment"] if query else []
        args = sub + base + ["-s", str(size)] + att + (["--", render(query)] if query else [])
        envs = hjson.envelopes(hjson.run_json(args))
        if len(envs) < size:
            return envs
        if dates and newest_first:
            oldest = day(envs[-1].get("date"))
            if oldest is not None and past_floor(oldest, dates):
                return envs
    raise hjson.BackendError(1, f"검색 결과가 {PAGE_STEPS[-1]}건을 넘습니다 - 잘린 결과를 내보내지 않고 "
                                "실패로 처리합니다. 기간·조건을 좁히십시오.")


BODY_NOTE = ("mailskill search: [참고] 본문(body) 조건으로는 한 통도 찾지 못했습니다. 웍스처럼 본문 검색을 "
             "지원하지 않는 서버에서는 제목 등 다른 조건의 일치만 나옵니다.\n")


def search(acct, folder, tokens):
    flt, order, dates = split_query(tokens)
    base = ["-a", acct] + (["-m", folder] if folder else [])

    plan = body_split(flt)
    if plan:
        rest, groups = plan
        # 하위 질의는 정렬 없이(최신순) 받고, 합친 뒤 정렬은 클라이언트에서 한다.
        by_id, body_hits = {}, 0
        q = lambda toks: fetch(["envelope", "search"], base, toks, dates, True)  # noqa: E731
        combos = 1
        for g in groups:
            combos *= len(g)
        if combos <= MAX_COMBOS:
            # 분배법칙: rest ∧ ∧_i(∨_j d_ij) = ∨_(조합) (rest ∧ d_1 ∧ … ∧ d_k). 조합마다 나머지 조건을 모두
            # 실어 묻는다 — 흔한 조건 하나만 따로 묻다 5000건 상한에 걸리는 일이 없다(Codex P2, #38).
            keep = set()
            for combo in itertools.product(*groups):
                toks = list(rest)
                for f, v in combo:
                    toks += (["and"] if toks else []) + [f, v]
                envs = q(toks)
                by_id.update((e["id"], e) for e in envs)
                keep |= {e["id"] for e in envs}
                if any(f == "body" for f, _ in combo):
                    body_hits += len(envs)
        else:
            # 조합이 너무 많으면(키워드 5개 이상) 조각별로 묻고 교집합 — 흔한 조각은 상한에 걸릴 수 있다.
            sets = []
            if rest:
                envs = q(rest)
                by_id.update((e["id"], e) for e in envs)
                sets.append({e["id"] for e in envs})
            for g in groups:
                ids = set()
                for f, v in g:
                    envs = q([f, v])
                    by_id.update((e["id"], e) for e in envs)
                    ids |= {e["id"] for e in envs}
                    if f == "body":
                        body_hits += len(envs)
                sets.append(ids)
            keep = set.intersection(*sets)
        envs = [by_id[i] for i in keep]
        if dates:
            envs = [e for e in envs if (d := day(e.get("date"))) is not None and date_ok(d, dates)]
        envs = sort_envelopes(envs, order or ["order", "by", "date", "desc"])
        if body_hits == 0:
            sys.stderr.write(BODY_NOTE)
        return envs

    # 날짜만 있는 질의의 정렬은 클라이언트에서 한다 — 서버엔 최신순으로 받아야 하한에서 일찍 멈출 수 있다.
    client_order = order if (dates and not flt) else []
    if client_order:
        order = []
    query = flt + order
    sub = ["envelope", "search"] if query else ["envelope", "list"]
    # 최신순일 때만 하한 날짜를 지나면 일찍 멈출 수 있다.
    newest_first = not order or (len(order) >= 3 and order[2] == "date" and (len(order) < 4 or order[3] == "desc"))
    envs = fetch(sub, base, query, dates, newest_first)
    if dates:
        envs = [e for e in envs if (d := day(e.get("date"))) is not None and date_ok(d, dates)]
    if client_order:
        envs = sort_envelopes(envs, client_order)
    return envs


def _date_key(e):
    """시간대가 섞여도 바르게 비교되도록 UTC 타임스탬프로. 못 읽으면 맨 끝(가장 오래된 쪽)."""
    try:
        return datetime.fromisoformat((e.get("date") or "").replace(" ", "T")).timestamp()
    except ValueError:
        return float("-inf")


def sort_envelopes(envs, order):
    """`order by <date|from|to|subject> [asc|desc]` 를 클라이언트에서. 기본 desc(himalaya 와 같음)."""
    field = order[2] if len(order) > 2 else "date"
    desc = not (len(order) > 3 and order[3] == "asc")
    key = {
        "date": _date_key,
        "subject": lambda e: (e.get("subject") or "").lower(),
        "from": lambda e: ((e.get("from") or {}).get("addr") or "").lower(),
        "to": lambda e: ((e.get("to") or {}).get("addr") or "").lower(),
    }.get(field)
    if key is None:
        raise QueryError(f"정렬 기준을 알 수 없음: {field}")
    return sorted(envs, key=key, reverse=desc)


def main(argv):
    if len(argv) < 2 or (len(argv) > 2 and argv[2] != "--"):
        sys.stderr.write("usage: search.py <acct> <folder|-> -- <query...>\n")
        return 2
    acct, folder = argv[0], (None if argv[1] == "-" else argv[1])
    tokens = argv[3:]
    try:
        out = search(acct, folder, tokens)
    except QueryError as e:
        sys.stderr.write(f"mailskill search: {e}\n")
        return 2
    except hjson.BackendError as e:
        return hjson._fail(e)
    hjson._emit_json(out)
    return 0


if __name__ == "__main__":
    hjson.reconfigure_utf8()
    sys.exit(main(sys.argv[1:]))
