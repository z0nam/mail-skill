#!/usr/bin/env python3
"""보낸편지함 중복 발송 가드 — `mailskill send` 직전 최근 N분 내 동일 수신자+제목 검사.

의도하지 않은 재시도로 인한 중복 메일 발송(이슈 #7)을 차단한다.
중복 감지 시 stderr 에 경고를 출력하고 exit 3 으로 종료한다.
정상 통과 시 exit 0.

usage:
  dup-guard.py --account <acct> --to <to> --subject <subj> [--window <minutes>]
               [--sent-folder <folder>] [--config <path>] [--himalaya-bin <bin>]
               [--mock-envelopes <file|->]
"""
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from email.utils import getaddresses, parsedate_to_datetime
from pathlib import Path


def parse_date(date_str):
    """다양한 형식의 날짜 문자열(ISO8601, RFC2822 등)을 timezone-aware datetime(UTC)으로 변환."""
    if not date_str:
        return None
    s = date_str.strip()
    # 1970년 등 비정상 값 필터링
    if s.startswith("1970-"):
        return None

    # 1) ISO 8601 형식 시도 (공백 구분자 허용)
    try:
        iso_s = s.replace(" ", "T")
        dt = datetime.fromisoformat(iso_s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except Exception:
        pass

    # 2) RFC 2822 시도
    try:
        dt = parsedate_to_datetime(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except Exception:
        pass

    # 3) 'YYYY-MM-DD HH:MM:SS' 또는 정규식 파싱
    m = re.match(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?([+-]\d{2}:?\d{2}|Z)?$', s)
    if m:
        try:
            year, month, day, hour, minute = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5))
            second = int(m.group(6)) if m.group(6) else 0
            tz_str = m.group(7)
            tz = timezone.utc
            if tz_str and tz_str != 'Z':
                tz_clean = tz_str.replace(":", "")
                sign = 1 if tz_clean[0] == '+' else -1
                tz_h = int(tz_clean[1:3])
                tz_m = int(tz_clean[3:5])
                from datetime import timedelta
                tz = timezone(sign * timedelta(hours=tz_h, minutes=tz_m))
            dt = datetime(year, month, day, hour, minute, second, tzinfo=tz)
            return dt.astimezone(timezone.utc)
        except Exception:
            pass

    return None


def extract_addrs(to_field):
    """문자열이나 딕셔너리에서 이메일 주소 목록(소문자)을 추출."""
    if not to_field:
        return set()
    if isinstance(to_field, dict):
        addr = to_field.get("addr") or ""
        return {addr.strip().lower()} if addr else set()
    if isinstance(to_field, list):
        res = set()
        for item in to_field:
            res.update(extract_addrs(item))
        return res
    if isinstance(to_field, str):
        pairs = getaddresses([to_field])
        res = {addr.strip().lower() for _, addr in pairs if addr}
        if not res:
            # 단순 regex fallback
            found = re.findall(r'[\w\.\-]+@[\w\.\-]+', to_field)
            res = {x.strip().lower() for x in found}
        return res
    return set()


def find_sent_folder(account, himalaya_bin, config_path=None):
    """himalaya folder list 로 보낸편지함 폴더명을 탐색."""
    cmd = [himalaya_bin, "folder", "list", "-a", account, "-o", "json"]
    if config_path and Path(config_path).is_file():
        cmd.extend(["-c", config_path])
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if res.returncode == 0:
            folders = json.loads(res.stdout)
            # 1) desc 에 \Sent 가 있는 폴더 우선
            for f in folders:
                desc = f.get("desc", "").lower()
                if "\\sent" in desc:
                    return f.get("name")
            # 2) 이름 매칭
            for f in folders:
                name = f.get("name", "")
                if name.lower() in ["sent messages", "sent", "sent mail", "보낸편지함", "[gmail]/sent mail"]:
                    return name
    except Exception:
        pass
    return "Sent Messages"


def get_sent_envelopes(account, folder, himalaya_bin, window_sec, config_path=None):
    """보낸편지함에서 최근 window 시간 내의 모든 envelope 목록을 가져온다 (가장 오래된 메일이 window 밖으로 나갈 때까지 페이지 확대)."""
    now_utc = datetime.now(timezone.utc)
    envelopes = []
    for psize in [20, 100, 500]:
        cmd = [himalaya_bin, "envelope", "list", "-a", account, "-f", folder, "--page-size", str(psize), "-o", "json"]
        if config_path and Path(config_path).is_file():
            cmd.extend(["-c", config_path])
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, check=False)
            if res.returncode != 0:
                break
            envelopes = json.loads(res.stdout)
            if not envelopes or not isinstance(envelopes, list):
                return []
            oldest_dt = None
            for env in reversed(envelopes):
                dt = parse_date(env.get("date"))
                if dt:
                    oldest_dt = dt
                    break
            if oldest_dt and (now_utc - oldest_dt).total_seconds() > window_sec:
                return envelopes
            if len(envelopes) < psize:
                return envelopes
        except Exception:
            break
    return envelopes


def main():
    ap = argparse.ArgumentParser(prog="dup-guard.py")
    ap.add_argument("--account", required=True, help="계정명")
    ap.add_argument("--to", required=True, help="수신자 주소")
    ap.add_argument("--subject", required=True, help="메일 제목")
    ap.add_argument("--window", type=int, default=10, help="중복 판정 시간(분, 기본 10)")
    ap.add_argument("--sent-folder", help="보낸편지함 폴더명 수동 지정")
    ap.add_argument("--config", help="himalaya config 경로")
    ap.add_argument("--himalaya-bin", default=None, help="himalaya 바이너리 경로")
    ap.add_argument("--mock-envelopes", help="테스트용 mock envelope JSON 파일 경로('-'=stdin)")

    a = ap.parse_args()
    h_bin = a.himalaya_bin or os.environ.get("HIMALAYA_BIN", "himalaya")

    target_addrs = extract_addrs(a.to)
    target_subject = a.subject.strip()
    window_sec = a.window * 60

    if a.mock_envelopes:
        if a.mock_envelopes == "-":
            raw = sys.stdin.read()
        else:
            raw = Path(a.mock_envelopes).read_text(encoding="utf-8")
        try:
            envelopes = json.loads(raw)
        except Exception as e:
            sys.exit(f"dup-guard: mock JSON 파싱 오류: {e}")
    else:
        sent_folder = a.sent_folder or find_sent_folder(a.account, h_bin, a.config)
        envelopes = get_sent_envelopes(a.account, sent_folder, h_bin, window_sec, a.config)

    if not isinstance(envelopes, list) or not envelopes:
        # 보낸편지함 조회 실패 또는 비어있음 -> 정상 통과 (발송 차단 안 함)
        sys.exit(0)

    now_utc = datetime.now(timezone.utc)

    for env in envelopes:
        if not isinstance(env, dict):
            continue

        env_subject = str(env.get("subject") or "").strip()
        if env_subject != target_subject:
            continue

        env_addrs = extract_addrs(env.get("to"))
        # 수신자 집합이 겹치는지 확인
        if target_addrs and env_addrs and not (target_addrs & env_addrs):
            continue

        env_date_str = env.get("date")
        env_dt = parse_date(env_date_str)
        if env_dt is None:
            # 날짜 파싱이 불가하거나 1970년 등인 경우:
            # 만약 아주 최근 envelope(예: 바로 첫 번째 또는 두 번째)이고 ID가 최신이면
            # 동일 제목+동일 수신자 조합일 때 주의해야 할 수 있으나 오탐 방지를 위해
            # 날짜 차이를 계산할 수 없으면 안전하게 스킵
            continue

        diff_sec = (now_utc - env_dt).total_seconds()
        # 최근 N분 이내인지 판정 (클럭 오차 고려해 -60초까지 허용)
        if -60 <= diff_sec <= window_sec:
            env_id = env.get("id", "unknown")
            to_repr = ", ".join(env_addrs) if env_addrs else str(env.get("to"))
            print(
                f"mailskill: 중복 발송 감지 — 최근 {a.window}분 내 동일 수신자 및 제목으로 발송된 메일이 있습니다.\n"
                f"  기존 메일 ID : {env_id}\n"
                f"  기존 발송 시각: {env_date_str} (약 {int(diff_sec // 60)}분 전)\n"
                f"  받는 사람    : {to_repr}\n"
                f"  제목        : {env_subject}\n"
                f"의도적 재발송인 경우 동일 명령에 --force 옵션을 추가하십시오.",
                file=sys.stderr,
            )
            sys.exit(3)

    sys.exit(0)


if __name__ == "__main__":
    main()
