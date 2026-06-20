#!/usr/bin/env python3
# 어떤 Maildir 의 보낸메일(.Sent)을 작성 날짜/시각에 맞춰 Day One 저널에 넣는다.
# Day One CLI(번들 바이너리) 사용 — 창 없이 동작. Message-ID 중복제거 + done파일로 재실행 안전.
#
# 개인정보(저널명/경로)는 인자 또는 env 로 받는다(코드에 하드코딩 안 함):
#   --journal NAME        Day One 저널명 (필수)
#   --sent DIR            보낸메일 Maildir cur 폴더 (여러 번 가능, 필수)
#   --done FILE           완료기록 파일 (재실행 안전; 기본 ./_dayone_done.txt)
#   --tags T1,T2          태그 (기본: 없음)
#   --limit N / --dry
# 예: sent-to-dayone.py --journal MyJournal --sent /arch/a/.Sent/cur --sent /arch/b/.Sent/cur --tags mail
import os, sys, glob, subprocess
from email.parser import BytesParser
from email.header import decode_header, make_header
import email.utils

DAYONE = os.environ.get("DAYONE_BIN", "/Applications/Day One.app/Contents/MacOS/dayone")

def argval(flag, multi=False):
    a = sys.argv[1:]; out = []
    for i, x in enumerate(a):
        if x == flag and i + 1 < len(a): out.append(a[i+1])
    return out if multi else (out[0] if out else None)

journal = argval("--journal")
sent_dirs = argval("--sent", multi=True)
done_file = argval("--done") or os.path.join(os.getcwd(), "_dayone_done.txt")
tags = [t for t in (argval("--tags") or "").split(",") if t]
limit = int(argval("--limit")) if argval("--limit") else None
dry = "--dry" in sys.argv
if not journal or not sent_dirs:
    sys.exit("필수: --journal NAME --sent DIR [--sent DIR ...]  (도움말은 스크립트 상단 주석)")

def H(v):
    try: return str(make_header(decode_header(v))) if v else ""
    except Exception: return v or ""

def get_body(m):
    if m.is_multipart():
        for p in m.walk():
            if p.get_content_type() == "text/plain" and "attachment" not in str(p.get("Content-Disposition","")):
                try: return p.get_payload(decode=True).decode(p.get_content_charset() or "utf-8","replace")
                except Exception: pass
        import re, html
        for p in m.walk():
            if p.get_content_type() == "text/html":
                try:
                    t = p.get_payload(decode=True).decode(p.get_content_charset() or "utf-8","replace")
                    t = re.sub(r"(?is)<(script|style).*?</\1>", "", t)
                    t = re.sub(r"(?i)<br\s*/?>", "\n", t); t = re.sub(r"(?i)</p>", "\n", t)
                    return html.unescape(re.sub(r"<[^>]+>", "", t))
                except Exception: pass
        return ""
    pl = m.get_payload(decode=True)
    if pl:
        try: return pl.decode(m.get_content_charset() or "utf-8","replace")
        except Exception: return pl.decode("utf-8","replace")
    return ""

done = set(l.strip() for l in open(done_file)) if os.path.exists(done_file) else set()

items = {}
for d in sent_dirs:
    for f in glob.glob(d + "/*"):
        try: m = BytesParser().parsebytes(open(f, "rb").read())
        except Exception: continue
        mid = (m.get("Message-ID") or "").strip() or "file:" + os.path.basename(f)
        if mid in items: continue
        try: when = email.utils.parsedate_to_datetime(m.get("Date"))
        except Exception: when = None
        items[mid] = (when, m)

ordered = sorted(items.items(), key=lambda kv: (kv[1][0] is None, kv[1][0]))
todo = [(mid, v) for mid, v in ordered if mid not in done]
print(f"고유 {len(items)} / 완료 {len(done)} / 대상 {len(todo)}")
if limit: todo = todo[:limit]

ok = fail = 0
for mid, (when, m) in todo:
    subj = H(m.get("Subject")).strip() or "(제목 없음)"
    to = H(m.get("To")).strip(); frm = H(m.get("From")).strip()
    body = get_body(m).strip() or "(본문 없음)"
    text = f"# {subj}\n\n*{frm} → {to}*\n\n{body}\n\n---\n*보낸 메일: {frm} → {to}*"
    if when is None: print(f"  SKIP(날짜없음): {subj[:30]}"); continue
    iso = when.astimezone(email.utils.datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if dry: print(f"  [dry] {iso} | {subj[:40]}"); ok += 1; continue
    cmd = [DAYONE, "--journal", journal, "--isoDate", iso, "--time-zone", "Asia/Seoul"]
    if tags: cmd += ["--tags", *tags]
    cmd += ["--", "new"]
    try:
        r = subprocess.run(cmd, input=text.encode("utf-8"), capture_output=True, timeout=60)
        if r.returncode == 0:
            open(done_file, "a").write(mid + "\n"); ok += 1
            if ok % 25 == 0: print(f"  ... {ok}건")
        else:
            fail += 1; print(f"  FAIL: {subj[:30]} :: {r.stderr.decode('utf-8','replace')[:100]}")
    except Exception as e:
        fail += 1; print(f"  ERR: {subj[:30]} :: {e}")
print(f"완료: 성공 {ok} / 실패 {fail}")
