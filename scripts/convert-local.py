#!/usr/bin/env python3
# Apple Mail.app 로컬 저장소(V10/<UUID>)의 .emlx 를 계정별 Maildir 로 일괄 변환(읽기/검색용).
# IMAP/앱비번 불필요. Message-ID 중복제거, From=owner 는 .Sent 로 분리.
#
# 개인정보(계정 UUID/이메일/경로)는 코드가 아니라 설정 파일에서 읽는다:
#   기본 경로: ./accounts.local.json  (또는 env MAIL_SKILL_ACCOUNTS / 첫 인자)
#   형식:
#   {
#     "mail_v10": "~/Library/Mail/V10",
#     "dest": "/path/to/mail-archive",
#     "targets": [ {"name":"acct1","uuid":"XXXX-...","owner":"me@example.com"}, ... ]
#   }
import os, sys, json, hashlib
from email.parser import BytesParser

def load_conf():
    p = os.environ.get("MAIL_SKILL_ACCOUNTS")
    jsons = [a for a in sys.argv[1:] if a.endswith(".json")]
    if jsons: p = jsons[0]
    p = p or os.path.join(os.getcwd(), "accounts.local.json")
    if not os.path.isfile(p):
        sys.exit(f"설정 파일 없음: {p}  (accounts.local.json 만들거나 MAIL_SKILL_ACCOUNTS 지정)")
    c = json.load(open(p))
    c["mail_v10"] = os.path.expanduser(c.get("mail_v10", "~/Library/Mail/V10"))
    return c

def read_emlx(p):
    with open(p, "rb") as f:
        first = f.readline()
        try: n = int(first.strip()); return f.read(n)
        except ValueError:
            data = first + f.read(); i = data.rfind(b"<?xml"); return data[:i] if i > 0 else data

def mk(folder):
    for d in ("cur", "new", "tmp"): os.makedirs(os.path.join(folder, d), exist_ok=True)
    return folder

def main():
    conf = load_conf()
    only = [a for a in sys.argv[1:] if not a.startswith("--") and not a.endswith(".json")]
    print(f"{'account':14} {'total':>6} {'sent':>6} {'oldest':10} {'newest':10}")
    for t in conf["targets"]:
        name, uuid, owner = t["name"], t["uuid"], t["owner"]
        if only and name not in only: continue
        src = os.path.join(conf["mail_v10"], uuid)
        if not os.path.isdir(src): print(f"{name:14}  (UUID 폴더 없음)"); continue
        root = os.path.join(conf["dest"], name, "Maildir")
        if os.path.isdir(root):
            import shutil; shutil.rmtree(root)
        inbox = mk(root); sent = mk(os.path.join(root, ".Sent"))
        seen = {}; nin = nse = err = 0; dates = []
        for dp, _, fs in os.walk(src):
            for fn in fs:
                if not fn.endswith(".emlx"): continue
                try:
                    raw = read_emlx(os.path.join(dp, fn))
                    if not raw or not raw.strip(): err += 1; continue
                    m = BytesParser().parsebytes(raw)
                    mid = (m.get("Message-ID") or "").strip() or "sha:" + hashlib.sha1(raw).hexdigest()
                    if mid in seen: continue
                    seen[mid] = 1
                    is_sent = owner.lower() in (m.get("From") or "").lower()
                    open(os.path.join((sent if is_sent else inbox), "cur", f"{4000000+len(seen)}.locconv:2,S"), "wb").write(raw)
                    nin += (not is_sent); nse += is_sent
                    d = m.get("Date")
                    if d:
                        try:
                            import email.utils; dates.append(email.utils.parsedate_to_datetime(d).date())
                        except Exception: pass
                except Exception: err += 1
        rng = (str(min(dates)), str(max(dates))) if dates else ("?", "?")
        print(f"{name:14} {len(seen):>6} {nse:>6} {rng[0]:10} {rng[1]:10}  (err {err})")

if __name__ == "__main__":
    main()
