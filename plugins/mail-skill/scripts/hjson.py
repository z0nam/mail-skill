#!/usr/bin/env python3
"""himalaya 2.x 출력을 mailskill 1.x 계약 모양으로 바꾸는 정규화 계층 (#30).

mailskill 의 JSON 동사(accounts/folders/list/search/read)는 에이전트와 맺은 계약이다
(SKILL.md "출력 계약"). himalaya 2.x 는 CLI·JSON 모양이 1.x 와 다르므로, 어댑터(bash·PS)와
python 헬퍼가 모두 이 모듈 하나를 거쳐 1.x 모양을 유지한다. 바꾸는 규칙을 한 곳에 두려는 것이다.

CLI (어댑터용)
--------------
실행 모드(권장. PS 는 이것만): python 이 himalaya 를 직접 실행해 바이트로 받는다.
  hjson.py accounts  -- account list
  hjson.py folders   -- mailbox list -a A
  hjson.py envelopes -- envelope list -a A [-m F] -s N
  hjson.py read      -- message read ID -a A [-m F]
  hjson.py raw --out FILE -- message read ID -a A [-m F]     (원문 바이트를 FILE 로)
`--json`·`--raw` 는 여기서 붙인다. 실행 파일은 HIMALAYA_BIN(기본 himalaya).

stdin 모드: `--` 없이 부르면 stdin 을 입력으로 받는다(accounts/folders/envelopes 는 2.x
--json 출력, read 는 --raw 원문 바이트). 에러·exit code 처리는 호출측 몫이다.

공통 판정(bash·PS 가 같은 문구를 쓰도록):
  hjson.py version                         stdout ok|old|missing, exit 0|3|127 (2.2.x 만 ok)
  hjson.py send --account A --file F       stdout sent|sent-save-failed|failed
  hjson.py check --account A [--doc PATH]  stdout 첫 줄 ok|auth|secret|config|network

실행 모드 에러 규칙: himalaya rc≠0 이면 에러 원문(2.x 는 stdout 으로 낸다)을 정리해
stderr 로 내고 stdout 은 비운 채 같은 rc 로 끝난다. rc=0 인데 출력을 못 읽으면 exit 1.
"""
import html
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from email import policy
from email.parser import BytesParser
from pathlib import Path

MIN_VERSION = (2, 2, 1)  # 지원 버전. Bcc 누출 수정(#747) 포함, 2.2.x 만 허용(version_status)
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
DEFAULT_DOC = "docs/naver-works-app-password.md"


class BackendError(Exception):
    """himalaya 실행 실패. rc 는 그대로 전달할 종료 코드, msg 는 정리된 에러 문장."""

    def __init__(self, rc, msg, cmd=None):
        super().__init__(msg)
        self.rc = rc
        self.msg = msg
        self.cmd = cmd or []


def himalaya_bin(override=None):
    """HIMALAYA_BIN(기본 himalaya)을 PATH 에서 찾는다. Windows 는 PATHEXT 로 .exe/.cmd 도 잡는다."""
    name = override or os.environ.get("HIMALAYA_BIN") or "himalaya"
    return shutil.which(name) or name


class ConfigPathError(Exception):
    """himalaya 에 config 경로를 넘길 수 없다(조용히 다른 파일을 읽는 대신 멈춘다). run() 이 낸다."""


def config_candidates():
    """himalaya 2.2.1 이 `-c` 없이 config 를 찾는 순서(src/config.rs): HIMALAYA_CONFIG 가 있으면 그것,
    없으면 OS 설정 폴더(Windows %APPDATA%, 맥 ~/Library/Application Support, 그 밖 XDG) →
    ~/.config/himalaya/config.toml → ~/.himalayarc. mailskill.ps1 의 Get-HimalayaConfigCandidates·
    cli/mailskill 의 CONFIG 결정과 같은 목록이다(한쪽만 고치지 말 것)."""
    env = os.environ.get("HIMALAYA_CONFIG")
    if env:
        return [Path(env)]
    home = Path.home()
    c = []
    if os.environ.get("APPDATA"):
        c.append(Path(os.environ["APPDATA"]) / "himalaya" / "config.toml")
    elif sys.platform == "darwin":
        c.append(home / "Library" / "Application Support" / "himalaya" / "config.toml")
    elif os.environ.get("XDG_CONFIG_HOME"):
        c.append(Path(os.environ["XDG_CONFIG_HOME"]) / "himalaya" / "config.toml")
    for p in (home / ".config" / "himalaya" / "config.toml", home / ".himalayarc"):
        if p not in c:
            c.append(p)
    return c


def implicit_config():
    """`-c` 없이 himalaya 가 실제로 읽을 파일(없으면 None)."""
    for p in config_candidates():
        try:
            if p.is_file():
                return p
        except OSError:
            pass
    return None


def config_args(config_path):
    """헬퍼가 himalaya 에 붙일 `-c` 인자.

    - config_path 가 himalaya 의 기본 탐색 결과와 같은 파일이면 `-c` 를 주지 않는다.
    - 다르면(앞 순위 파일에 가려졌거나 저장소 폴백 등) `-c` 로 명시한다 — 헬퍼가 From 등을 읽는 파일과
      himalaya 가 쓰는 파일이 같아야 하므로. ':' 가 든 경로(Windows 드라이브)는 run() 이 처리한다.
    """
    if not config_path or not Path(config_path).is_file():
        return []
    imp = implicit_config()
    try:
        if imp is not None and imp.resolve() == Path(config_path).resolve():
            return []
    except OSError:
        pass
    return ["-c", str(config_path)]


def _safe_config(args):
    """2.2.1 은 `-c` 값을 ':' 로 쪼개 여러 경로로 읽는다(src/cli.rs value_delimiter) — 'C:\\...' 드라이브
    경로는 "No configuration found" 가 된다(Windows 실측, 맥에서도 ':' 든 경로로 재현). 상대경로는 읽힌다.
    그래서 ':' 가 든 `-c` 값은 그 파일이 있는 폴더에서 himalaya 를 실행하고 파일 이름만 넘긴다(드라이브가
    달라도 된다). 파일 이름에까지 ':' 가 있으면 ConfigPathError 로 멈춘다. 반환: (args, cwd)."""
    args = list(args)
    for i, a in enumerate(args[:-1]):
        if a in ("-c", "--config") and ":" in args[i + 1]:
            d, b = os.path.split(os.path.abspath(args[i + 1]))
            if ":" in b:
                raise ConfigPathError(
                    f"config 경로 {args[i + 1]} 를 himalaya 2.2.x 에 넘길 수 없습니다('-c' 값이 ':' 로 쪼개집니다). "
                    "파일 이름에서 ':' 를 빼세요.")
            args[i + 1] = b
            return args, d
    return args, None


def config_shadow_warning(config_path):
    """config_path 가 앞 순위 파일에 가려져 있으면 경고 문장, 아니면 ""."""
    imp = implicit_config()
    if not config_path or imp is None or not Path(config_path).is_file():
        return ""
    try:
        if imp.resolve() == Path(config_path).resolve():
            return ""
    except OSError:
        return ""
    return (f"[주의] {imp} 가 있어서 himalaya 는 {config_path} 대신 그 파일을 먼저 읽습니다. "
            "하나만 남기세요.")


def _env():
    env = os.environ.copy()
    # 백엔드 로그 끄기(어댑터 계약: stdout 엔 JSON 만). MAILSKILL_LOG 로 켤 수 있다.
    env.setdefault("RUST_LOG", os.environ.get("MAILSKILL_LOG") or "off")
    env.setdefault("NO_COLOR", "1")
    return env


def clean_text(s):
    """에러 원문에서 ANSI 색, `Suggestions:` 블록, 1.x 의 `Note: Run with` 줄을 걷어낸다."""
    s = ANSI_RE.sub("", s or "")
    out = []
    skip = False
    for line in s.splitlines():
        t = line.strip()
        if t == "Suggestions:":
            skip = True
            continue
        if skip:
            if t.startswith("- ") or not t:
                continue
            skip = False
        if t.startswith("Note: Run with --"):
            continue
        out.append(line.rstrip())
    while out and not out[-1].strip():
        out.pop()
    return "\n".join(out).strip()


def extract_error(stdout_b, stderr_b):
    """2.x 의 에러 출력에서 사람이 읽을 문장을 꺼낸다.

    2.x 는 에러를 **stdout** 으로 낸다(`--json` 이면 {"error","sources"}, 아니면 `Error: ...`).
    1.x 는 stderr 였다. 둘 다 본다.
    """
    out = (stdout_b or b"").decode("utf-8", errors="replace")
    err = (stderr_b or b"").decode("utf-8", errors="replace")
    parts = []
    t = out.strip()
    if t.startswith("{"):
        try:
            obj = json.loads(t)
            if isinstance(obj, dict) and "error" in obj:
                msg = clean_text(str(obj.get("error") or ""))
                if msg.startswith("Error: "):
                    msg = msg[len("Error: "):]
                srcs = [clean_text(str(x)) for x in (obj.get("sources") or []) if x]
                parts.append(msg + ("" if not srcs else " - " + "; ".join(srcs)))
                t = ""
        except ValueError:
            pass
    if t:
        c = clean_text(t)
        parts.append(c[len("Error: "):] if c.startswith("Error: ") else c)
    if err.strip():
        parts.append(clean_text(err))
    return "\n".join(p for p in parts if p) or "(백엔드가 에러 문장을 내지 않음)"


def run(args, json_out=True, raw=False, hbin=None):
    """himalaya 를 실행해 stdout 바이트를 돌려준다. 실패면 BackendError.

    stdin 은 닫는다 - 설정을 못 찾았을 때 마법사가 stdin 을 기다리며 멈추지 않게.
    hbin 은 실행 파일 지정(헬퍼의 --himalaya-bin). 없으면 HIMALAYA_BIN.
    """
    args, cwd = _safe_config(args)
    exe = himalaya_bin(hbin)
    if cwd and (os.sep in exe or "/" in exe):
        exe = os.path.abspath(exe)   # cwd 를 바꾸므로 상대 경로 실행 파일은 절대경로로
    cmd = [exe] + (["--json"] if json_out else []) + list(args)
    if raw:
        cmd.append("--raw")
    try:
        p = subprocess.run(cmd, capture_output=True, stdin=subprocess.DEVNULL, env=_env(), cwd=cwd)
    except FileNotFoundError:
        raise BackendError(127, f"backend '{cmd[0]}' not found in PATH", cmd)
    if p.returncode != 0:
        raise BackendError(p.returncode, extract_error(p.stdout, p.stderr), cmd)
    if os.environ.get("MAILSKILL_LOG") and p.stderr:
        sys.stderr.write(p.stderr.decode("utf-8", errors="replace"))
    return p.stdout


def run_json(args, hbin=None):
    """--json 실행 결과를 파싱한다. 출력이 비었거나 UTF-8/JSON 이 아니면 BackendError(1)."""
    out = run(args, json_out=True, hbin=hbin)
    try:
        text = out.decode("utf-8")
    except UnicodeDecodeError as e:
        raise BackendError(1, f"백엔드 출력이 UTF-8 이 아님 ({e}) - 빈 결과로 처리하지 않고 실패합니다", args)
    if not text.strip():
        raise BackendError(1, "백엔드가 성공(exit 0)했지만 출력이 비어 있음 - 빈 결과로 처리하지 않고 실패합니다", args)
    try:
        return json.loads(text)
    except ValueError as e:
        raise BackendError(1, f"백엔드 출력이 JSON 이 아님 ({e}) - 빈 결과로 처리하지 않고 실패합니다", args)


# ── 정규화 ────────────────────────────────────────────────────────────────

def norm_addr(v):
    """2.x [{name,email}] (또는 1.x {name,addr}) → 1.x {name, addr} 하나."""
    if isinstance(v, list):
        v = v[0] if v else None
    if isinstance(v, dict):
        return {"name": v.get("name"), "addr": v.get("email") or v.get("addr") or ""}
    return {"name": None, "addr": ""}


def norm_flags(v):
    out = []
    for f in v or []:
        if isinstance(f, dict):
            iana = f.get("iana")
            out.append(iana.capitalize() if iana else str(f.get("raw") or ""))
        else:
            out.append(str(f))
    return [f for f in out if f]


def norm_date(s):
    """RFC3339 → 1.x 표기 'YYYY-MM-DD HH:MM+09:00'. 못 읽으면 원문을 그대로 둔다."""
    if not s:
        return s
    try:
        dt = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return s
    if dt.tzinfo is None:
        return dt.strftime("%Y-%m-%d %H:%M")
    off = dt.strftime("%z")  # +0900
    return dt.strftime("%Y-%m-%d %H:%M") + off[:3] + ":" + off[3:]


def _unwrap(obj, key):
    if isinstance(obj, dict):
        obj = obj.get(key)
    if obj is None:
        return []
    if not isinstance(obj, list):
        raise BackendError(1, f"백엔드 출력에 '{key}' 배열이 없음: {type(obj).__name__}")
    return obj


def envelope(e):
    if not isinstance(e, dict):
        return e
    if "has_attachment" in e and "has-attachment" not in e:
        return e  # 이미 1.x 모양
    return {
        "id": str(e.get("id", "")),
        "flags": norm_flags(e.get("flags")),
        "subject": e.get("subject") or "",
        "from": norm_addr(e.get("from")),
        "to": norm_addr(e.get("to")),
        "date": norm_date(e.get("date")),
        # IMAP 은 --has-attachment 를 주지 않으면 null 이다(웍스 실측). 모르면 모른다고(null) 둔다.
        "has_attachment": e.get("has-attachment"),
        "message_id": e.get("message-id"),
        "in_reply_to": e.get("in-reply-to") or [],
    }


def envelopes(obj):
    return [envelope(e) for e in _unwrap(obj, "envelopes")]


ATT = "--has-attachment"
ATT_NOTE = ("mailskill: [참고] 서버가 일부 메일의 첨부 정보를 돌려주지 않아, 그 메일은 첨부 여부 없이"
            "(has_attachment=null) 냅니다.\n")
_att_noted = False  # 한 번 실행에 안내는 한 번만(search 는 여러 번 묻는다)


def fetch_envelopes(args, hbin=None):
    """envelope list/search 를 돌려 1.x 모양 봉투 목록으로. `--has-attachment` 로 빠진 메일을 되살린다(#41).

    himalaya 2.2.1 은 --has-attachment 를 붙이면 BODYSTRUCTURE 를 따로 받는데, 일부 IMAP 서버
    (실측: 한 연구기관 메일 서버)의 응답을 해석하지 못하면 그 메일을 경고 없이 결과에서 뺀다("skipping undecodable
    untagged response"). 옵션 없는 조회는 멀쩡하다. 그래서 결과가 페이지(-s)를 다 채우지 못했으면
    옵션 없이 한 번 더 받아 비교하고, 그쪽이 더 많으면 그것을 쓴다. 첨부 여부는 첫 조회에 있던
    메일만 채우고 나머지는 모른다(null). 페이지를 다 채웠으면 빠진 것이 없으므로 추가 조회는 없다.
    """
    envs = envelopes(run_json(args, hbin=hbin))
    head = args[:args.index("--")] if "--" in args else args
    if ATT not in head:
        return envs
    try:
        size = int(head[head.index("-s") + 1]) if "-s" in head else None
    except (ValueError, IndexError):
        size = None
    if size is not None and len(envs) >= size:
        return envs
    i = args.index(ATT)
    plain = envelopes(run_json(args[:i] + args[i + 1:], hbin=hbin))
    if len(plain) <= len(envs):
        return envs
    known = {e["id"]: e.get("has_attachment") for e in envs if isinstance(e, dict)}
    for e in plain:
        if isinstance(e, dict):
            e["has_attachment"] = known.get(e["id"])
    global _att_noted
    if not _att_noted:
        sys.stderr.write(ATT_NOTE)
        _att_noted = True
    return plain


def folders(obj):
    out = []
    for m in _unwrap(obj, "mailboxes"):
        if not isinstance(m, dict):
            continue
        role = m.get("role") or ""
        out.append({"name": m.get("name") or "", "desc": m.get("desc") or role, "role": role or None})
    return out


def accounts(obj):
    out = []
    for a in _unwrap(obj, "accounts"):
        if not isinstance(a, dict):
            continue
        b = a.get("backends")
        backend = ", ".join(b) if isinstance(b, list) else (a.get("backend") or "")
        out.append({"name": a.get("name") or "", "backend": backend, "default": bool(a.get("default"))})
    return out


def _decode_part(part):
    try:
        return part.get_content()
    except (LookupError, UnicodeDecodeError, AssertionError):
        payload = part.get_payload(decode=True) or b""
        cs = part.get_content_charset() or "utf-8"
        for enc in (cs, "cp949", "utf-8"):
            try:
                return payload.decode(enc)
            except (LookupError, UnicodeDecodeError):
                continue
        return payload.decode("utf-8", errors="replace")


def _html_to_text(s):
    s = re.sub(r"(?is)<(script|style).*?</\1>", "", s)
    s = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</tr>", "\n", s)
    s = re.sub(r"<[^>]+>", "", s)
    s = html.unescape(s)
    return re.sub(r"\n{3,}", "\n\n", s).strip() + "\n"


def _body_parts(part):
    """본문 후보 잎 파트만. 첨부(disposition=attachment)와 첨부된 메일(message/rfc822)은 하위 트리째
    건너뛴다 - msg.walk() 는 건너뛴 컨테이너 안으로도 내려가 첨부 메일의 본문을 섞는다(Codex 리뷰, #36)."""
    if part.get_content_disposition() == "attachment" or part.get_content_type() == "message/rfc822":
        return
    if part.is_multipart():
        for sub in part.iter_parts():
            yield from _body_parts(sub)
    else:
        yield part


def read_text(raw):
    """원문 RFC 5322 바이트 → 1.x `message read -o json` 과 같은 문자열.

    'From: ..\\nTo: ..\\n[Cc: ..\\n]Subject: ..\\n\\n<본문>'. 본문은 text/plain 파트(첨부 제외),
    없으면 text/html 을 태그 제거한 텍스트.
    """
    msg = BytesParser(policy=policy.default).parsebytes(raw)
    lines = []
    for h in ("From", "To", "Cc", "Subject"):
        v = msg.get(h)
        if v is not None and (h != "Cc" or str(v).strip()):
            lines.append(f"{h}: {str(v)}")
    plain, htmls = [], []
    for part in _body_parts(msg):
        ctype = part.get_content_type()
        if ctype == "text/plain":
            plain.append(_decode_part(part))
        elif ctype == "text/html":
            htmls.append(_decode_part(part))
    body = "\n".join(plain) if plain else "\n".join(_html_to_text(h) for h in htmls)
    return "\n".join(lines) + "\n\n" + body


# ── 판정 ──────────────────────────────────────────────────────────────────

def parse_version(text):
    m = re.search(r"v?(\d+)\.(\d+)(?:\.(\d+))?", text or "")
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))


def version_status():
    """('ok'|'old'|'missing', (maj,min,patch)|None)."""
    try:
        p = subprocess.run([himalaya_bin(), "--version"], capture_output=True,
                           stdin=subprocess.DEVNULL, env=_env())
    except FileNotFoundError:
        return "missing", None
    v = parse_version(p.stdout.decode("utf-8", errors="replace"))
    if p.returncode != 0 or v is None:
        return "old", None
    # 2.2.x 만 허용한다. upstream [Unreleased] 에 JSON 구조·exit code·에러 객체를 바꾸는
    # BREAKING 이 여럿 있어, 다음 판(2.3 이상)은 이 정규화가 맞는다는 보장이 없다.
    if MIN_VERSION <= v < (MIN_VERSION[0], MIN_VERSION[1] + 1, 0):
        return "ok", v
    return "old", v


SEND_SAVE_FAILED = "Message sent, but saving a copy"

CHECK_KEYWORDS = [  # 판정 순서: config → secret → auth → network
    ("config", ["v1 `backend` table is ignored", "parse toml config error", "no configuration found",
                "get account", "configures no supported backend"]),
    ("secret", ["secret command error", "mail-secret"]),
    # 웍스 실측(#30): imap "Authentication failed. (Please check your username, password)",
    #                 smtp "535 5.7.1 Username and Password not accepted"
    ("auth", ["authentication failed", "authenticationfailed", "invalid credentials", "535",
              "username and password not accepted"]),
]


def classify_check(texts):
    low = "\n".join(texts).lower()
    for kind, words in CHECK_KEYWORDS:
        if any(w.lower() in low for w in words):
            return kind
    return "network"


def check_message(kind, acct, doc):
    return {
        "auth": ("[실패] 로그인 실패 - 아이디 또는 앱 비밀번호가 틀렸습니다.",
                 f"  -> 앱 비밀번호를 새로 발급해 'mailskill setup' 을 다시 실행하세요({doc})."),
        "secret": ("[실패] 메일 프로그램이 저장된 비밀번호를 읽지 못했습니다.",
                   f"  -> 'mailskill doctor {acct}' 로 다시 확인하고, 계속되면 관리자에게 위 내용을 보내세요."),
        "config": (f"[실패] 메일 설정 파일을 himalaya 2.x 가 읽지 못합니다(1.x 형식이거나 계정 '{acct}' 가 없음).",
                   "  -> 'mailskill setup' 을 다시 실행해 2.x 형식으로 만드세요."),
        "network": ("[실패] 메일 서버에 접속하지 못했습니다(네트워크 또는 IMAP/SMTP 사용 허용 여부).",
                    "  -> 회사망·인터넷 연결을 확인하고, 계속되면 웍스 관리자에게 IMAP/SMTP 허용을 요청하세요."),
    }[kind]


# ── CLI ───────────────────────────────────────────────────────────────────

def _emit_json(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")


def _fail(e):
    if e.cmd:
        sys.stderr.write(f"mailskill: backend failed (exit {e.rc}): {' '.join(e.cmd[1:])}\n")
    sys.stderr.write(e.msg.rstrip() + "\n")
    return e.rc or 1


def _stdin_json():
    data = sys.stdin.buffer.read()
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        raise BackendError(1, f"입력이 2.x JSON 이 아님 ({e})")


def cmd_kind(kind, rest):
    out_file = None
    if kind == "raw":
        if len(rest) >= 2 and rest[0] == "--out":
            out_file, rest = rest[1], rest[2:]
        else:
            sys.stderr.write("usage: hjson.py raw --out FILE -- <himalaya args...>\n")
            return 2
    if rest and rest[0] == "--":
        args = rest[1:]
        if not args:
            sys.stderr.write(f"usage: hjson.py {kind} -- <himalaya args...>\n")
            return 2
        if kind in ("read", "raw"):
            data = run(args, json_out=False, raw=True)
        elif kind == "envelopes":
            obj = fetch_envelopes(args)  # 이미 1.x 모양 — envelope() 는 그대로 통과시킨다
        else:
            obj = run_json(args)
    elif rest:
        sys.stderr.write(f"hjson.py {kind}: 알 수 없는 인자 {rest[0]!r} (himalaya 인자는 -- 뒤에)\n")
        return 2
    else:
        if kind in ("read", "raw"):
            data = sys.stdin.buffer.read()
        else:
            obj = _stdin_json()

    if kind == "accounts":
        _emit_json(accounts(obj))
    elif kind == "folders":
        _emit_json(folders(obj))
    elif kind == "envelopes":
        _emit_json(envelopes(obj))
    elif kind == "read":
        if not data.strip():
            raise BackendError(1, "메시지를 찾을 수 없습니다(백엔드가 빈 원문을 냄)")
        _emit_json(read_text(data))
    elif kind == "raw":
        with open(out_file, "wb") as f:
            f.write(data)
    return 0


def cmd_version():
    status, v = version_status()
    print(status)
    if status == "missing":
        sys.stderr.write(f"mailskill: 백엔드 '{himalaya_bin()}' 를 찾을 수 없습니다 - himalaya 2.2.1(지원 버전)을 설치하세요.\n")
        return 127
    if status == "old":
        cur = "v%d.%d.%d" % v if v else "알 수 없음"
        sys.stderr.write(f"mailskill: 지원하지 않는 himalaya 버전({cur}) - 지원 버전 2.2.1. jaix setup 으로 다시 설치하세요.\n")
        return 3
    return 0


def _opt(rest, name, default=None):
    if name in rest:
        i = rest.index(name)
        if i + 1 < len(rest):
            return rest[i + 1]
    return default


def cmd_send(rest):
    acct, path = _opt(rest, "--account"), _opt(rest, "--file")
    if not acct or not path:
        sys.stderr.write("usage: hjson.py send --account A --file F\n")
        return 2
    try:
        run(["message", "send", "-a", acct, "--", path])
    except BackendError as e:
        if SEND_SAVE_FAILED in e.msg:
            print("sent-save-failed")
            sys.stderr.write("mailskill send: 발송 완료, 보낸함 저장 실패 - 재시도 금지\n"
                             "메일은 정상 발송되었습니다. 수신자에게 이미 전달되었으므로 절대 재시도하지 마십시오.\n"
                             f"  (백엔드: {e.msg.splitlines()[0]})\n")
            return 0
        print("failed")
        return _fail(e)
    print("sent")
    return 0


def cmd_check(rest):
    acct = _opt(rest, "--account")
    doc = _opt(rest, "--doc", DEFAULT_DOC)
    if not acct:
        sys.stderr.write("usage: hjson.py check --account A [--doc PATH]\n")
        return 2
    report, failures = [], []
    try:
        obj = run_json(["account", "check", "-a", acct])
        for b in (obj.get("backends") or []) if isinstance(obj, dict) else []:
            name = b.get("backend", "?")
            if b.get("ok"):
                report.append(f"  {name}: OK")
            else:
                err = clean_text(str(b.get("error") or ""))
                report.append(f"  {name}: FAIL ({err})")
                failures.append(err)
        if not report:
            failures.append("account check 결과에 백엔드가 없음 (configures no supported backend)")
    except BackendError as e:
        failures.append(e.msg)
        report.append(f"  error: {e.msg}")
    kind = classify_check(failures) if failures else "ok"
    print(kind)
    for line in report:
        print(line)
    if kind == "ok":
        return 0
    l1, l2 = check_message(kind, acct, doc)
    sys.stderr.write(l1 + "\n" + l2 + "\n")
    return 3


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0 if argv else 2
    kind, rest = argv[0], argv[1:]
    try:
        if kind in ("accounts", "folders", "envelopes", "read", "raw"):
            return cmd_kind(kind, rest)
        if kind == "version":
            return cmd_version()
        if kind == "send":
            return cmd_send(rest)
        if kind == "check":
            return cmd_check(rest)
    except BackendError as e:
        return _fail(e)
    sys.stderr.write(f"hjson.py: 알 수 없는 명령 {kind!r}\n")
    return 2


def reconfigure_utf8():
    """한글 Windows 에서 PYTHONUTF8 없이 실행돼도 stdout/stderr 를 UTF-8 로, 줄끝은 LF 로.

    Windows 텍스트 모드는 print 의 \n 을 \r\n 으로 바꾼다. 판정어(ok/sent/...)를 읽는 어댑터가
    플랫폼마다 다른 값을 받지 않도록 bash·PS 모두 LF 로 통일한다.
    """
    for s in (sys.stdout, sys.stderr):
        if hasattr(s, "reconfigure"):
            try:
                s.reconfigure(encoding="utf-8", errors="backslashreplace", newline="\n")
            except Exception:
                pass


if __name__ == "__main__":
    reconfigure_utf8()
    sys.exit(main(sys.argv[1:]))
