#!/usr/bin/env python3
"""raw MIME 빌더 — `mailskill send` 가 `himalaya message send` 로 파이프할 메시지를 만든다.

MIME 조립(멀티파트·base64·인코딩)을 한 곳(파이썬 stdlib)에 두어 bash·ps1 어댑터가 공유한다.
stdout 으로 RFC822 raw 메시지(헤더+본문, 첨부 있으면 multipart/mixed)를 낸다.

usage:
  compose-mime.py (--from <addr> | --from-account <acct>) [--config <path>]
                  [--to <a,b>] [--cc ..] [--bcc ..] [--subject <s>]
                  [--reply-to-id <id>] [--reply-folder <folder>]
                  [--in-reply-to <msgid>] [--references <refs>]
                  (--body <text> | --body-file <path|->) [--attach <file> ...]
                  [--preview | --dump-meta]
"""
import argparse
import email.utils
import json
import mimetypes
import os
import re
import subprocess
import sys
import unicodedata
from email.encoders import encode_base64
from email.header import Header
from email.mime.base import MIMEBase
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path


def rfc2047_param(name):
    """첨부 파일명을 Content-Disposition/Content-Type 파라미터 값으로 만든다.

    - NFC 정규화(macOS 파일명은 NFD 자모분리일 수 있음) 후,
    - ASCII 이면 그대로(plain), 비ASCII 면 RFC 2047 인코디드워드(=?utf-8?b?...?=)로.

    RFC 2231 `filename*` 분할형(퍼센트 인코딩)은 쓰지 않는다 — 행정망 등
    RFC 2231 미해석 수신자에서 파일명이 깨지기 때문(#22). 네이버웍스 웹메일과 같은
    방식이다. compat32(레거시 MIME*) 직렬화에서는 이미 ASCII 인 인코디드워드 문자열이
    EmailPolicy 처럼 다시 RFC 2231 로 재인코딩되지 않아 이 형태가 보존된다.
    """
    nfc = unicodedata.normalize("NFC", name)
    try:
        nfc.encode("ascii")
        return nfc
    except UnicodeEncodeError:
        # maxlinelen 을 크게 줘서 인코디드워드가 접히지(folding) 않고 한 덩어리로 남게 한다.
        return str(Header(nfc, "utf-8").encode(maxlinelen=998))


def _quote_param(value):
    """헤더 파라미터 quoted-string 값용 이스케이프(헤더 인젝션/따옴표 깨짐 방지)."""
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "").replace("\n", "")


def encode_address_header(value):
    """From/To/Cc/Bcc 헤더 값. 표시이름(display name)에 비ASCII 가 있으면 그 부분만
    RFC 2047 로 인코딩하고 주소(<a@b>)는 그대로 둔다(주소 파싱 가능하게 유지).
    compat32 Generator 는 비ASCII str 를 자동 인코딩하지 않으므로 직접 처리한다."""
    out = []
    for disp, addr in email.utils.getaddresses([value]):
        if disp:
            try:
                disp.encode("ascii")
            except UnicodeEncodeError:
                disp = str(Header(disp, "utf-8").encode(maxlinelen=998))
        out.append(email.utils.formataddr((disp, addr)))
    return ", ".join(out)


def encode_text_header(value):
    """Subject 등 자유 텍스트 헤더. ASCII 면 그대로, 비ASCII 면 RFC 2047 로."""
    try:
        value.encode("ascii")
        return value
    except UnicodeEncodeError:
        return str(Header(value, "utf-8").encode())


def himalaya_config_args(config_path):
    """himalaya 에 넘길 `-c` 인자. 기본 탐색으로 같은 파일을 찾으면 `-c` 를 아예 주지 않는다.

    himalaya 1.2.0 Windows 는 config 를 **절대경로로** 받으면(-c 든 HIMALAYA_CONFIG 든)
    auth.cmd 단계에서 멈춘다(실측). 기본 탐색(~/.config/himalaya/config.toml)은 정상이고,
    셋업은 늘 그 위치에 쓰므로 그 경우엔 `-c` 를 빼서 어댑터의 다른 동사와 같은 경로를 탄다.
    기본 위치가 아닌 config(저장소 폴백 등)만 예전처럼 `-c` 로 명시한다.
    """
    if not config_path or not Path(config_path).is_file():
        return []
    target = Path(config_path).resolve()
    defaults = [Path.home() / ".config" / "himalaya" / "config.toml"]
    if os.environ.get("HIMALAYA_CONFIG"):
        defaults.append(Path(os.environ["HIMALAYA_CONFIG"]))  # himalaya 가 env 로 스스로 읽는다
    for d in defaults:
        try:
            if d.is_file() and d.resolve() == target:
                return []
        except OSError:
            pass
    return ["-c", config_path]


def resolve_from(account, config_path):
    """himalaya config(TOML)에서 [accounts.<account>] 의 email 을 뽑는다.
    toml 라이브러리 없이 섹션 단순 스캔(어댑터가 bash/ps1 양쪽에서 파싱 안 하도록 여기 둔다)."""
    p = Path(config_path)
    if not p.is_file():
        sys.exit(f"compose-mime: config 없음: {config_path}")
    want = f"[accounts.{account}]"
    in_sec = False
    for line in p.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            in_sec = (s == want)
            continue
        if in_sec:
            m = re.match(r'email\s*=\s*"?([^"]+)"?\s*$', s)
            if m:
                return m.group(1).strip()
    sys.exit(f"compose-mime: config 에서 계정 '{account}' 의 email 을 못 찾음")


def check_himalaya_bcc_safe(himalaya_bin=None):
    """Himalaya < 2.2.1 환경에서 Bcc 헤더가 SMTP DATA 로 누출되는 취약점(#747) 방지.
    안전한 버전(>= 2.2.1)임이 명확히 확인되지 않으면 fail-closed 로 거부한다."""
    h_bin = himalaya_bin or os.environ.get("HIMALAYA_BIN", "himalaya")
    try:
        res = subprocess.run([h_bin, "--version"], capture_output=True, text=True, encoding="utf-8", errors="replace", check=False)
        if res.returncode == 0:
            m = re.search(r'(?:himalaya\s+)?v?(\d+)\.(\d+)(?:\.(\d+))?', res.stdout)
            if m:
                major = int(m.group(1))
                minor = int(m.group(2))
                patch = int(m.group(3)) if m.group(3) else 0
                if (major, minor, patch) >= (2, 2, 1):
                    return  # 안전 확인됨
                sys.exit(
                    f"compose-mime: 현재 백엔드({h_bin} v{major}.{minor}.{patch})는 "
                    "Bcc 헤더를 SMTP 전송 시 제거하지 않고 모든 수신자에게 노출하는 업스트림 버그(#747)가 있습니다. "
                    "himalaya 2.2.1 이상으로 업그레이드하거나 Bcc 대신 개별 발송을 사용하십시오."
                )
    except Exception:
        pass

    # 버전을 알 수 없거나 검증할 수 없는 경우 안전을 위해 거부 (fail-closed)
    sys.exit(
        f"compose-mime: 백엔드({h_bin})의 버전을 검증할 수 없어 Bcc 누출 방지(#747)가 확인되지 않았습니다. "
        "Bcc 대신 개별 발송을 사용하거나 himalaya 2.2.1 이상을 설치하십시오."
    )


def fetch_reply_headers(account, message_id, folder=None, config_path=None, himalaya_bin=None):
    """himalaya message read 로 원본 메일의 주요 헤더(Message-ID, Subject, From, Reply-To, References 등)를 조회한다."""
    h_bin = himalaya_bin or os.environ.get("HIMALAYA_BIN", "himalaya")
    cmd = [
        h_bin, "message", "read", str(message_id),
        "-a", account, "-p",
        "-H", "Reply-To", "-H", "From", "-H", "To", "-H", "Subject",
        "-H", "Message-ID", "-H", "References", "-H", "In-Reply-To"
    ]
    if folder:
        cmd.extend(["-f", folder])
    cmd.extend(himalaya_config_args(config_path))

    try:
        res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", check=False)
    except FileNotFoundError:
        sys.exit(f"compose-mime: himalaya 실행 파일('{h_bin}')을 찾을 수 없음")

    if res.returncode != 0:
        err = res.stderr.strip() or f"exit code {res.returncode}"
        sys.exit(f"compose-mime: 원 메일({message_id}) 조회 실패: {err}")

    headers = {}
    last_key = None
    for line in res.stdout.splitlines():
        if line == "":
            break  # 헤더 끝
        if line.startswith((" ", "\t")) and last_key:
            headers[last_key] += " " + line.strip()
            continue
        m = re.match(r'^([\w\-]+):\s*(.*)$', line)
        if m:
            last_key = m.group(1)
            headers[last_key] = m.group(2).strip()

    return headers


def main():
    ap = argparse.ArgumentParser(prog="compose-mime.py")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--from", dest="from_", help="발신자 주소(직접 지정)")
    src.add_argument("--from-account", dest="from_account", help="himalaya 계정명 → config 에서 email 해석")
    ap.add_argument("--config", help="himalaya config 경로(--from-account 와 함께 필요)")
    ap.add_argument("--himalaya-bin", default=None, help="himalaya 바이너리 경로")

    # 수신자 및 메타데이터
    ap.add_argument("--to", help="수신자(콤마 구분)")
    ap.add_argument("--cc")
    ap.add_argument("--bcc")
    ap.add_argument("--subject")

    # 답장(reply) 옵션
    ap.add_argument("--reply-to-id", help="원 메일 id (himalaya message read 로 원본 헤더 조회)")
    ap.add_argument("--reply-folder", help="원 메일 폴더 (기본 INBOX)")
    ap.add_argument("--in-reply-to", help="In-Reply-To 헤더 (수동 지정 시)")
    ap.add_argument("--references", help="References 헤더 (수동 지정 시)")

    # 본문
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--body", help="본문 텍스트")
    g.add_argument("--body-file", dest="body_file", help="본문 파일 경로('-'=stdin)")

    # 첨부 및 출력 모드
    ap.add_argument("--attach", action="append", default=[], help="첨부 파일(반복 가능)")
    ap.add_argument("--output", "-o", help="MIME 메시지를 바이너리로 저장할 파일 경로(지정 시 stdout 대신 파일에 기록)")
    ap.add_argument("--dump-meta", action="store_true", help="계산된 메타데이터 JSON 출력")
    ap.add_argument("--preview", action="store_true", help="미리보기 텍스트 터미널 출력")

    a = ap.parse_args()

    if a.from_account:
        if not a.config:
            sys.exit("compose-mime: --from-account 에는 --config 가 필요")
        from_addr = resolve_from(a.from_account, a.config)
    else:
        from_addr = a.from_

    to_addr = a.to
    subj = a.subject
    in_reply_to = a.in_reply_to
    references = a.references

    if a.reply_to_id:
        if not a.from_account:
            sys.exit("compose-mime: --reply-to-id 에는 --from-account 가 필요")
        orig_hdrs = fetch_reply_headers(
            a.from_account,
            a.reply_to_id,
            folder=a.reply_folder,
            config_path=a.config,
            himalaya_bin=a.himalaya_bin,
        )
        orig_msg_id = orig_hdrs.get("Message-ID", "")
        if not orig_msg_id:
            orig_msg_id = f"<{a.reply_to_id}@{a.from_account}>"

        if not in_reply_to:
            in_reply_to = orig_msg_id

        if not references:
            orig_refs = orig_hdrs.get("References", "")
            if orig_refs:
                references = f"{orig_refs.strip()} {orig_msg_id}"
            else:
                references = orig_msg_id

        if not subj:
            orig_subj = orig_hdrs.get("Subject", "")
            if re.match(r'^(re|fw|fwd)[:\s]', orig_subj, re.IGNORECASE):
                subj = orig_subj
            else:
                subj = f"Re: {orig_subj}".strip()

        if not to_addr:
            to_addr = orig_hdrs.get("Reply-To") or orig_hdrs.get("From", "")

    if a.bcc:
        check_himalaya_bcc_safe(a.himalaya_bin)

    if not to_addr:
        sys.exit("compose-mime: --to 필요 (또는 --reply-to-id 로 원발신자 해석 실패)")
    if not subj:
        sys.exit("compose-mime: --subject 필요 (또는 --reply-to-id 로 원제목 해석 실패)")

    if a.body is not None:
        body = a.body
    elif a.body_file == "-":
        body = sys.stdin.read()
    else:
        p = Path(a.body_file)
        if not p.is_file():
            sys.exit(f"compose-mime: 본문 파일 없음: {a.body_file}")
        body = p.read_text(encoding="utf-8-sig")

    for item in a.attach:
        path = Path(item)
        if not path.is_file():
            sys.exit(f"compose-mime: 첨부 파일 없음: {item}")

    # 메타데이터 덤프 모드 (대용량 본문으로 인한 파이프/argv 오버헤드 방지를 위해 body 제외)
    if a.dump_meta:
        meta = {
            "from": from_addr,
            "to": to_addr,
            "cc": a.cc or "",
            "bcc": a.bcc or "",
            "subject": subj,
            "in_reply_to": in_reply_to or "",
            "references": references or "",
            "attach": a.attach,
        }
        print(json.dumps(meta, ensure_ascii=False))
        return

    # 미리보기 모드
    if a.preview:
        print("── mailskill send 미리보기 (실전송하려면 동일 명령에 --send 추가) ──")
        print(f"계정(From) : {a.from_account or from_addr} <{from_addr}>")
        print(f"받는사람   : {to_addr}")
        if a.cc:
            print(f"참조       : {a.cc}")
        if a.bcc:
            print(f"숨은참조   : {a.bcc}")
        print(f"제목       : {subj}")
        if in_reply_to:
            print(f"In-Reply-To: {in_reply_to}")
        if references:
            print(f"References : {references}")
        if a.attach:
            print(f"첨부       : {' '.join(a.attach)}")
        print("본문:")
        for line in body.splitlines()[:60]:
            print(f"  {line}")
        return

    # MIME 객체 생성.
    #
    # 레거시 compat32 API(MIMEMultipart/MIMEText/MIMEBase)로 조립한다. 모던
    # EmailMessage(EmailPolicy)는 비ASCII 첨부 파일명을 최종 직렬화 단계에서 반드시
    # RFC 2231 `filename*` 분할형으로 재인코딩하는데(set_param/replace_header/legacy
    # part 혼입으로도 우회 불가, 실측), 행정망 등 RFC 2231 미해석 수신자에서 파일명이
    # 깨진다(#22). compat32 는 이미 ASCII 인 인코디드워드 파라미터 문자열을 그대로 두므로
    # 네이버웍스 웹메일과 같은 RFC 2047 형태(filename/name 둘 다)가 보존된다.
    body_part = MIMEText(body, "plain", "utf-8")

    if a.attach:
        msg = MIMEMultipart()
        msg.attach(body_part)
        for item in a.attach:
            path = Path(item)
            ctype, encoding = mimetypes.guess_type(str(path))
            if ctype is None or encoding is not None:
                ctype = "application/octet-stream"
            maintype, subtype = ctype.split("/", 1)
            part = MIMEBase(maintype, subtype)
            part.set_payload(path.read_bytes())
            encode_base64(part)
            fn = _quote_param(rfc2047_param(path.name))
            part["Content-Disposition"] = 'attachment; filename="%s"' % fn
            part.replace_header("Content-Type", '%s/%s; name="%s"' % (maintype, subtype, fn))
            msg.attach(part)
    else:
        msg = body_part

    # 헤더 설정. 비ASCII(한글 표시이름·제목)는 compat32 에서 자동 인코딩되지 않으므로
    # RFC 2047 로 직접 인코딩해 넣는다(안 그러면 Generator 가 깨뜨리거나 예외).
    msg["From"] = encode_address_header(from_addr)
    msg["To"] = encode_address_header(to_addr)
    if a.cc:
        msg["Cc"] = encode_address_header(a.cc)
    if a.bcc:
        msg["Bcc"] = encode_address_header(a.bcc)
    msg["Subject"] = encode_text_header(subj)

    # 표준 날짜 및 메시지 ID 보장 (1970년 날짜 및 스레딩 누락 방지)
    msg["Date"] = email.utils.formatdate(localtime=True)
    msg["Message-ID"] = email.utils.make_msgid()

    if in_reply_to:
        msg["In-Reply-To"] = in_reply_to
    if references:
        msg["References"] = references

    raw_bytes = msg.as_bytes()
    if a.output:
        Path(a.output).write_bytes(raw_bytes)
    else:
        sys.stdout.buffer.write(raw_bytes)


if __name__ == "__main__":
    # 출력도 UTF-8 로 고정한다. 한글 Windows 에서 PYTHONUTF8/PYTHONIOENCODING 없이 실행되면
    # stdout/stderr 가 cp949·cp1252 라 한글을 쓰다 UnicodeEncodeError 가 난다(어댑터 env 와 이중 안전장치).
    for _s in (sys.stdout, sys.stderr):
        if hasattr(_s, "reconfigure"):
            try:
                _s.reconfigure(encoding="utf-8", errors="backslashreplace")
            except Exception:
                pass
    main()
