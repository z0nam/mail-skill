#!/usr/bin/env python3
"""새 메일이 도착할 때까지 폴링하다가 결과를 출력하고 종료한다.

  mailskill watch <계정> [--from a@x,b@y] [--subject 키워드] [옵션...]
  mail-watch      <계정> [--from a@x,b@y] [--subject 키워드] [옵션...]

왜 있나:
  상대방 회신을 기다릴 때 에이전트가 이 명령을 백그라운드로 띄워 두면
  (Claude Code 의 run_in_background 등), 메일이 도착해 명령이 끝나는 순간
  세션이 깨어나 출력된 ID·발신자·제목을 보고 바로 후속 처리를 이어갈 수 있다.
  폴링은 이 프로세스가 하므로 기다리는 동안 세션 토큰을 쓰지 않는다.

기준점(baseline):
  - `--after-id N` 과 `--since 시각` 을 모두 생략하면, 시작 시점의 폴더 최신 메일 ID 를
    자동으로 잡아 그 이후 도착분만 감시한다 (수동 ID 입력 실수 방지).
  - `--after-id N` 또는 `--since 시각` 을 명시하면 첫 폴링에서 이미 도착해 있는 메일도
    즉시 잡아 출력하고 종료한다.

종료 코드 (pr-watch 와 동일 체계):
  0 조건에 맞는 새 메일 도착 (ID·보낸사람·제목·시각 출력)
  2 대기 시간 만료 (--until 또는 --timeout 도달, 혹은 --once 에서 미도착)
  3 연속 백엔드 조회 실패 한도 초과 (네트워크·IMAP 장애 지속)
  1 초기 조회 실패(계정·인증 오류) 또는 기타 오류
"""
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
import unicodedata
from datetime import datetime

PAGE_STEPS = (50, 200, 1000, 5000)


def die(msg, code=1):
    print(f"mailskill watch: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


def norm(s):
    return unicodedata.normalize("NFC", s or "").casefold()


def parse_duration(s):
    m = re.fullmatch(r"(\d+)\s*([smh]?)", s.strip())
    if not m:
        raise argparse.ArgumentTypeError(f"기간 형식 오류: {s!r} (예: 300, 90s, 5m, 1h)")
    val = int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[m.group(2)]
    if val < 1:
        raise argparse.ArgumentTypeError(f"기간은 1초 이상이어야 합니다: {s!r}")
    return val


def local_now():
    return datetime.now().astimezone()


def parse_user_time(s, label="시각"):
    """사용자 입력 시각을 로컬 타임존 aware datetime 으로 변환한다.

    지원 형식:
      - HH:MM 또는 HH:MM:SS (오늘 날짜 기준)
      - YYYY-MM-DD (해당일 00:00:00)
      - YYYY-MM-DD HH:MM(:SS) 또는 ISO-8601 (타임존 없으면 로컬 타임존 부여)
    """
    raw = s.strip()
    now = local_now()
    tz = now.tzinfo

    m_hm = re.fullmatch(r"(\d{1,2}):(\d{2})(?::(\d{2}))?", raw)
    if m_hm:
        hh, mm, ss = int(m_hm.group(1)), int(m_hm.group(2)), int(m_hm.group(3) or 0)
        try:
            return now.replace(hour=hh, minute=mm, second=ss, microsecond=0)
        except ValueError as e:
            raise argparse.ArgumentTypeError(f"{label} 형식 오류 ({s!r}): {e}")

    m_date = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", raw)
    if m_date:
        try:
            return datetime(
                int(m_date.group(1)), int(m_date.group(2)), int(m_date.group(3)),
                0, 0, 0, tzinfo=tz,
            )
        except ValueError as e:
            raise argparse.ArgumentTypeError(f"{label} 날짜 오류 ({s!r}): {e}")

    iso = raw.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(iso)
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"{label} 형식 오류: {s!r} (예: 18:30, 2026-10-16 09:00, 2026-10-16T09:00+09:00)"
        )
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=tz)
    return dt


def parse_env_date(s):
    if not s:
        return None
    raw = s.strip().replace("Z", "+00:00")
    # himalaya 봉투 시각 예: "2026-10-16 08:55+09:00"
    try:
        dt = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=local_now().tzinfo)
    return dt


def parse_int_id(v):
    try:
        return int(str(v).strip())
    except (ValueError, TypeError):
        return None


def extract_sender(env):
    f = env.get("from")
    if isinstance(f, dict):
        name = (f.get("name") or "").strip().strip('"').strip("'")
        addr = (f.get("addr") or "").strip()
        return name, addr
    if isinstance(f, list) and f:
        first = f[0]
        if isinstance(first, dict):
            name = (first.get("name") or "").strip().strip('"').strip("'")
            addr = (first.get("addr") or "").strip()
            return name, addr
        return "", str(first).strip()
    if isinstance(f, str):
        return "", f.strip()
    return "", ""


def format_sender(env):
    name, addr = extract_sender(env)
    if name and addr and name != addr:
        return f"{name} <{addr}>"
    return addr or name or "(발신자 미상)"


def fetch_page(acct, folder, size):
    hbin = os.environ.get("HIMALAYA_BIN", "himalaya")
    env = os.environ.copy()
    env.setdefault("RUST_LOG", os.environ.get("MAILSKILL_LOG", "off"))
    cmd = [hbin, "envelope", "list", "-a", acct]
    if folder:
        cmd += ["-f", folder]
    cmd += ["--page-size", str(size), "-o", "json"]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, env=env)
    except FileNotFoundError:
        raise RuntimeError(f"백엔드 '{hbin}' 를 PATH 에서 찾을 수 없습니다")
    if p.returncode != 0:
        err = (p.stderr or "").strip()
        if "out of bounds" in err:
            return []
        raise RuntimeError(f"봉투 조회 실패 (exit {p.returncode}): {err or 'stderr 없음'}")
    out = (p.stdout or "").strip()
    if not out:
        return []
    try:
        data = json.loads(out)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"백엔드 JSON 파싱 실패: {e}")
    return data if isinstance(data, list) else []


def fetch_candidates(acct, folder, after_id, since_floor):
    """기준점(after_id 또는 since_floor)에 닿을 때까지 페이지 크기를 키워 봉투를 가져온다."""
    envelopes = []
    for size in PAGE_STEPS:
        envelopes = fetch_page(acct, folder, size)
        if len(envelopes) < size or not envelopes:
            return envelopes
        oldest = envelopes[-1]
        reached = False
        if after_id is not None:
            oid = parse_int_id(oldest.get("id"))
            if oid is not None and oid <= after_id:
                reached = True
        if since_floor is not None:
            odt = parse_env_date(oldest.get("date"))
            if odt is not None and odt < since_floor:
                reached = True
        if reached:
            return envelopes

    if after_id is not None or since_floor is not None:
        raise RuntimeError(
            f"검색 결과가 {PAGE_STEPS[-1]}건을 넘거나 기준점에 도달하지 못했습니다 — "
            "잘린 결과를 내보내지 않고 실패로 처리합니다. 기준 기간·ID를 좁히십시오."
        )
    return envelopes


def filter_matches(envelopes, after_id, seen_ids, since_floor, from_pats, subj_pats):
    matched = []
    for e in envelopes:
        raw_id = str(e.get("id", "")).strip()
        if raw_id in seen_ids:
            continue
        num_id = parse_int_id(raw_id)
        if after_id is not None and num_id is not None and num_id <= after_id:
            continue
        if since_floor is not None:
            dt = parse_env_date(e.get("date"))
            if dt is None or dt < since_floor:
                continue
        if from_pats:
            name, addr = extract_sender(e)
            hay = norm(f"{name} {addr}")
            if not any(p in hay for p in from_pats):
                continue
        if subj_pats:
            subj = norm(e.get("subject") or "")
            if not any(p in subj for p in subj_pats):
                continue
        matched.append(e)

    # 오래된 순 → 최신 순 정렬 (ID 숫자 기준, 없으면 원래 역순)
    matched.reverse()
    matched.sort(key=lambda x: (parse_int_id(x.get("id")) is not None, parse_int_id(x.get("id")) or 0))
    return matched


def report(acct, folder, matched, as_json=False):
    if as_json:
        json.dump(matched, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        sys.stdout.flush()
        return

    flabel = folder or "INBOX"
    print(f"계정: {acct} ({flabel})")
    print(f"결과: NEW_MAIL {len(matched)}건")
    for i, e in enumerate(matched, 1):
        mid = e.get("id", "?")
        date = e.get("date") or "(시각 미상)"
        sender = format_sender(e)
        subj = (e.get("subject") or "(제목 없음)").strip()
        att = " [첨부]" if e.get("has_attachment") else ""
        print(f"\n[{i}] id={mid}  {date}{att}")
        print(f"    보낸사람: {sender}")
        print(f"    제목: {subj}")

    last_id = matched[-1].get("id", "<id>")
    farg = f" {json.dumps(folder, ensure_ascii=False)}" if folder and folder != "INBOX" else ""
    print("\n다음 단계:")
    print(f"  본문 읽기: mailskill read {acct} {last_id}{farg}")
    print(f"  회신 초안: mailskill reply {acct} {last_id}")
    sys.stdout.flush()


def build_parser():
    ap = argparse.ArgumentParser(
        prog="mailskill watch",
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""예시:
  mailskill watch ji --from a@example.com,b@example.com --until 18:30
  mailskill watch ji --subject "입지 검토" --interval 180
  mailskill watch ji --from example.com --after-id 11090 --once

종료 코드:
  0  새 메일 도착
  2  대기 시간 종료 (--until / --timeout 만료, 또는 --once 미도착)
  3  연속 백엔드 조회 실패 한도 초과
  1  초기 조회 실패 또는 사용법/기타 오류""",
    )
    ap.add_argument("account", help="감시할 메일 계정명 (mailskill accounts 참조)")
    ap.add_argument("-f", "--folder", default=None, help="감시할 폴더 (기본: INBOX)")
    ap.add_argument(
        "--from", dest="from_list", action="append", default=[],
        metavar="ADDR[,ADDR...]",
        help="발신자 주소 또는 이름 부분 일치 필터 (콤마 구분 또는 반복 가능)",
    )
    ap.add_argument(
        "--subject", dest="subj_list", action="append", default=[],
        metavar="KEYWORD",
        help="제목 키워드 부분 일치 필터 (반복 시 OR 매칭)",
    )
    ap.add_argument("--after-id", type=int, default=None, metavar="N",
                    help="이 ID 보다 큰 메일만 새 메일로 판정 (미지정 시 시작 시점 최신 ID 자동 감지)")
    ap.add_argument("--since", type=lambda s: parse_user_time(s, "--since"), default=None,
                    metavar="TIME", help="이 시각 이후 메일만 새 메일로 판정 (예: 09:00, '2026-10-16 09:00')")
    ap.add_argument("--until", type=lambda s: parse_user_time(s, "--until"), default=None,
                    metavar="TIME", help="대기 종료 시각 (예: 18:30, '2026-10-16 18:30')")
    ap.add_argument("--timeout", type=parse_duration, default=None, metavar="DUR",
                    help="최대 대기 시간 (예: 30m, 2h, 1800s)")
    ap.add_argument("--interval", type=parse_duration, default=300, metavar="DUR",
                    help="폴링 간격 (기본: 300 = 5분, 예: 60, 90s, 5m)")
    ap.add_argument("--max-errors", type=int, default=5, metavar="N",
                    help="연속 백엔드 오류 허용 횟수 (기본: 5)")
    ap.add_argument("--once", action="store_true", help="기다리지 않고 현재 상태만 1회 확인")
    ap.add_argument("--json", action="store_true", help="도착 시 매칭된 봉투 목록을 JSON 으로만 출력")
    return ap


def main():
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

    ap = build_parser()
    a = ap.parse_args()

    from_pats = []
    for item in a.from_list:
        for part in item.split(","):
            p = norm(part.strip())
            if p:
                from_pats.append(p)
    subj_pats = [norm(s.strip()) for s in a.subj_list if s.strip()]

    # himalaya 봉투 시각은 분 단위(초=00)이므로 --since 는 분 단위로 내림해 비교한다.
    since_floor = a.since.replace(second=0, microsecond=0) if a.since else None
    after_id = a.after_id
    seen_ids = set()

    flabel = a.folder or "INBOX"

    # 1) 기준점이 없으면 시작 시점 최신 ID 를 자동으로 잡는다.
    auto_baseline = (after_id is None and since_floor is None)
    if auto_baseline:
        if a.once:
            die("--once 는 비교 기준(--after-id 또는 --since)과 함께 써야 합니다", code=1)
        try:
            init_envs = fetch_page(a.account, a.folder, PAGE_STEPS[0])
        except RuntimeError as e:
            die(str(e), code=1)
        num_ids = [parse_int_id(e.get("id")) for e in init_envs]
        num_ids = [i for i in num_ids if i is not None]
        after_id = max(num_ids) if num_ids else 0
        seen_ids = {str(e.get("id", "")).strip() for e in init_envs if e.get("id") is not None}
        base_desc = f"after-id={after_id} (자동)"
    else:
        parts = []
        if after_id is not None:
            parts.append(f"after-id={after_id}")
        if since_floor is not None:
            parts.append(f"since={since_floor.strftime('%Y-%m-%d %H:%M')}")
        base_desc = ", ".join(parts)

    start_mono = time.monotonic()

    cond_parts = [f"기준 {base_desc}"]
    if from_pats:
        cond_parts.append(f"from={','.join(from_pats)}")
    if subj_pats:
        cond_parts.append(f"subject={','.join(subj_pats)}")
    cond_parts.append(f"간격 {a.interval}s")
    if a.until:
        cond_parts.append(f"종료시각 {a.until.strftime('%Y-%m-%d %H:%M')}")
    if a.timeout:
        cond_parts.append(f"최대대기 {a.timeout}s")

    print(
        f"mailskill watch: {a.account} ({flabel}) 대기 시작 — " + " · ".join(cond_parts),
        file=sys.stderr,
        flush=True,
    )

    err_count = 0
    first_iter = True

    while True:
        # 자동 기준점 모드에서는 시작 직후 이미 최신 ID 를 읽었으므로 첫 루프는 대기 후 조회한다.
        # 반면 --after-id / --since 를 명시한 경우에는 이미 도착해 있을 수 있으므로 즉시 1회 조회한다.
        if not (auto_baseline and first_iter):
            try:
                envs = fetch_candidates(a.account, a.folder, after_id, since_floor)
                err_count = 0
                matched = filter_matches(envs, after_id, seen_ids, since_floor, from_pats, subj_pats)
                if matched:
                    report(a.account, a.folder, matched, as_json=a.json)
                    sys.exit(0)
            except RuntimeError as e:
                err_count += 1
                if first_iter and not auto_baseline:
                    die(str(e), code=1)
                print(
                    f"mailskill watch: 일시적 조회 오류 ({err_count}/{a.max_errors}) — {e}",
                    file=sys.stderr,
                    flush=True,
                )
                if err_count >= a.max_errors:
                    print(
                        f"계정 {a.account} ({flabel}): 연속 조회 실패 {err_count}회 — 감시 중단 ({e})"
                    )
                    sys.exit(3)

        first_iter = False

        if a.once:
            if not a.json:
                print(f"계정 {a.account} ({flabel}): 조건에 맞는 새 메일 없음 ({base_desc})")
            else:
                print("[]")
            sys.exit(2)

        now = local_now()
        elapsed = time.monotonic() - start_mono
        remaining = None

        if a.until is not None:
            rem_until = (a.until - now).total_seconds()
            if rem_until <= 0:
                if not a.json:
                    print(
                        f"계정 {a.account} ({flabel}): 종료 시각({a.until.strftime('%H:%M')}) 도달 "
                        f"({int(elapsed)}s 경과) — 조건에 맞는 새 메일 없음 ({base_desc})"
                    )
                else:
                    print("[]")
                sys.exit(2)
            remaining = rem_until if remaining is None else min(remaining, rem_until)

        if a.timeout is not None:
            rem_timeout = a.timeout - elapsed
            if rem_timeout <= 0:
                if not a.json:
                    print(
                        f"계정 {a.account} ({flabel}): 최대 대기 시간({a.timeout}s) 만료 "
                        f"— 조건에 맞는 새 메일 없음 ({base_desc})"
                    )
                else:
                    print("[]")
                sys.exit(2)
            remaining = rem_timeout if remaining is None else min(remaining, rem_timeout)

        sleep_sec = a.interval if remaining is None else max(1.0, min(float(a.interval), remaining))
        time.sleep(sleep_sec)


if __name__ == "__main__":
    main()
