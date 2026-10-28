#!/usr/bin/env python3
"""raw EML 메시지에서 첨부파일을 추출하고 무결성을 검증하는 헬퍼.

himalaya attachment download 가 비표준 MIME 헤더(접힌 Content-Type, 따옴표 안 RFC 2047)를
텍스트로 오인해 바이너리(xlsx 등)를 손상시키는 업스트림 버그(이슈 #9)를 안전하게 우회한다.

email.policy.default 를 사용해 비표준 헤더를 복원하고,
저장 후 zip 계열(xlsx/docx/hwpx/pptx)은 zipfile.testzip(), 그 외는 크기 대조로 무결성을 확인한다.
암호화된 OOXML(OLE CFB) 및 암호화된 ZIP 아카이브를 정상 보존하며,
중첩 multipart, multipart/related 인라인 파일, message/rfc822 첨부를 지원한다.
검증 실패 파일은 즉시 삭제하여 손상된 파일이 저장되지 않도록 방지한다.
bash(bin/mailskill)와 PowerShell(bin/mailskill.ps1) 양쪽 어댑터가 공통 호출한다.
"""
import argparse
import email
import email.policy
import json
import mimetypes
import os
import re
import sys
import zipfile
from pathlib import Path

WINDOWS_RESERVED_NAMES = {
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
}

ZIP_EXTENSIONS = {
    ".xlsx", ".xlsm", ".xltx", ".xltm",
    ".docx", ".docm", ".dotx", ".dotm",
    ".pptx", ".pptm", ".potx", ".potm",
    ".hwpx", ".zip",
}

# Microsoft Office 비밀번호 암호화 OLE Compound File Binary 시그니처
OLE_SIGNATURE = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"


def sanitize_filename(raw_name: str) -> str:
    """Windows 파일명 금칙문자 및 디렉토리 탈출(..) 경로를 안전하게 치환."""
    if not raw_name:
        return "attachment"

    # 1. 디렉토리 구분자 및 상위 경로 탈출 방지
    name = os.path.basename(raw_name.replace("\\", "/"))

    # 2. 제어 문자 및 널 바이트 제거
    name = re.sub(r"[\x00-\x1f\x7f]", "", name)

    # 3. Windows 금칙 문자 치환 (\ / : * ? " < > |)
    name = re.sub(r'[\\/:*?"<>|]', "_", name)

    # 4. 파일명 stem 과 확장자 분리
    p = Path(name)
    stem = p.stem.rstrip(". ")
    suffix = p.suffix.rstrip(". ")

    if not stem:
        stem = "attachment"

    # 5. Windows 예약어 충돌 회피 (CON, PRN, AUX, NUL, COM1-9, LPT1-9 등)
    if stem.upper() in WINDOWS_RESERVED_NAMES:
        stem = f"_{stem}"

    safe_name = f"{stem}{suffix}" if suffix else stem
    return safe_name


def get_unique_path(target_dir: Path, filename: str, used_paths: set) -> Path:
    """대상 디렉토리 내 기존 파일 및 동일 실행 내 중복 파일명과 충돌하지 않는 고유 경로 반환."""
    candidate = target_dir / filename
    if not candidate.exists() and candidate not in used_paths:
        used_paths.add(candidate)
        return candidate

    p = Path(filename)
    stem = p.stem
    suffix = p.suffix
    counter = 1
    while True:
        candidate = target_dir / f"{stem}_{counter}{suffix}"
        if not candidate.exists() and candidate not in used_paths:
            used_paths.add(candidate)
            return candidate
        counter += 1


def verify_file_integrity(filepath: Path, expected_size: int) -> tuple[bool, str]:
    """저장된 첨부파일의 무결성을 검증한다.

    - zip 계열(xlsx/docx/hwpx/pptx/zip):
      * 암호화된 OOXML(OLE 시그니처)인 경우 건너뛰고 정상 인정
      * 비밀번호 보호된 ZIP 아카이브인 경우 정상 인정 및 보존
      * 그 외 zipfile.testzip() 수행
    - 그 외: 파일 크기 대조
    """
    actual_size = filepath.stat().st_size
    if actual_size != expected_size:
        return False, f"크기 불일치: 기대 {expected_size}바이트, 실제 {actual_size}바이트"

    ext = filepath.suffix.lower()
    if ext in ZIP_EXTENSIONS:
        # 1. 암호화된 Office 문서(OLE CFB) 여부 확인
        try:
            with open(filepath, "rb") as f:
                header = f.read(8)
            if header == OLE_SIGNATURE:
                return True, "password-protected OLE document OK"
        except Exception as e:
            return False, f"파일 헤더 확인 실패: {e}"

        # 2. ZIP 아카이브 구조 검증
        if not zipfile.is_zipfile(filepath):
            return False, "올바른 ZIP 아카이브 구조가 아닙니다 (BadZipFile)"

        try:
            with zipfile.ZipFile(filepath, "r") as zf:
                # 암호화된 엔트리가 존재하는지 확인
                has_encrypted_entry = any(bool(zinfo.flag_bits & 0x1) for zinfo in zf.filelist)
                bad_file = zf.testzip()
                if bad_file is not None:
                    return False, f"ZIP 내부 압축/CRC 손상 감지: {bad_file}"
                if has_encrypted_entry:
                    return True, "password-protected zip archive OK"
        except (RuntimeError, NotImplementedError) as e:
            err_msg = str(e).lower()
            if "password" in err_msg or "encrypted" in err_msg or "encryption" in err_msg:
                return True, "password-protected zip archive OK"
            return False, f"ZIP 검증 중 오류 발생: {e}"
        except Exception as e:
            return False, f"ZIP 검증 중 오류 발생: {e}"

        return True, "testzip OK"

    return True, f"size OK ({actual_size} bytes)"


def collect_attachment_parts(msg) -> list:
    """메시지 내 모든 실제 첨부 파트를 수집한다 (중첩 multipart 재귀 탐색, message/rfc822 및 인라인 파일 포함)."""
    parts = []
    seen_ids = set()

    def _add_part(p):
        pid = id(p)
        if pid not in seen_ids:
            seen_ids.add(pid)
            parts.append(p)

    def _walk_containers(container):
        if hasattr(container, "iter_attachments"):
            candidates = list(container.iter_attachments())
        elif isinstance(container.get_payload(), list):
            candidates = container.get_payload()
        else:
            candidates = [container]

        for p in candidates:
            ctype = p.get_content_type().lower()
            if ctype == "message/rfc822":
                _add_part(p)
            elif p.is_multipart():
                _walk_containers(p)
            else:
                _add_part(p)

    _walk_containers(msg)

    # 2단계: multipart/related 본문 컨테이너 내 이름 있는 인라인 파일이나
    # iter_attachments() 가 건너뛴 파트 탐색 (단, message/rfc822 내부는 제외)
    def _scan_omitted(part):
        ctype = part.get_content_type().lower()
        if ctype == "message/rfc822":
            if part.get_filename() or part.is_attachment():
                _add_part(part)
            return

        if part.is_multipart():
            payload = part.get_payload()
            if isinstance(payload, list):
                for subpart in payload:
                    _scan_omitted(subpart)
            return

        has_name = bool(part.get_filename() or part.get_param("name"))
        if has_name or part.is_attachment():
            _add_part(part)

    _scan_omitted(msg)

    return parts


def export_attachments(eml_path: Path, out_dir: Path) -> list[dict]:
    """raw EML 파일을 파싱하여 모든 첨부파일을 추출하고 저장 및 검증한다."""
    if not eml_path.is_file():
        raise FileNotFoundError(f"EML 파일을 찾을 수 없습니다: {eml_path}")

    out_dir.mkdir(parents=True, exist_ok=True)

    with open(eml_path, "rb") as f:
        msg = email.message_from_binary_file(f, policy=email.policy.default)

    attachments = collect_attachment_parts(msg)

    results = []
    used_paths = set()

    for idx, part in enumerate(attachments, start=1):
        raw_filename = part.get_filename()
        if not raw_filename:
            raw_filename = part.get_param("name")
        if not raw_filename:
            content_type = part.get_content_type().lower()
            if content_type == "message/rfc822":
                raw_filename = f"message_{idx}.eml"
            else:
                ext = mimetypes.guess_extension(content_type) or ".bin"
                raw_filename = f"attachment_{idx}{ext}"

        safe_filename = sanitize_filename(raw_filename)
        dest_path = get_unique_path(out_dir, safe_filename, used_paths)

        # 페이로드 추출
        if part.get_content_type().lower() == "message/rfc822":
            payload_obj = part.get_payload()
            if isinstance(payload_obj, list) and len(payload_obj) > 0 and hasattr(payload_obj[0], "as_bytes"):
                payload = payload_obj[0].as_bytes()
            elif hasattr(payload_obj, "as_bytes"):
                payload = payload_obj.as_bytes()
            elif isinstance(payload_obj, bytes):
                payload = payload_obj
            elif isinstance(payload_obj, str):
                payload = payload_obj.encode("utf-8")
            else:
                payload = part.as_bytes()
        else:
            payload = part.get_payload(decode=True)

        if payload is None:
            results.append({
                "filename": safe_filename,
                "original_filename": raw_filename,
                "path": str(dest_path),
                "size": 0,
                "verified": False,
                "message": "페이로드 디코딩 실패 (payload is None)",
            })
            continue

        with open(dest_path, "wb") as f_out:
            f_out.write(payload)

        ok, msg_text = verify_file_integrity(dest_path, len(payload))
        if not ok:
            # 무결성 검증 실패 시 손상된 파일이 저장되지 않도록 디스크에서 즉시 삭제
            try:
                dest_path.unlink()
            except OSError:
                pass

        results.append({
            "filename": safe_filename,
            "original_filename": raw_filename,
            "path": str(dest_path),
            "size": len(payload),
            "verified": ok,
            "message": msg_text,
        })

    return results


def main():
    # Windows 파이프 캡처 시 UnicodeEncodeError 방지 (utf-8 강제)
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
        except Exception:
            pass
    if hasattr(sys.stderr, "reconfigure"):
        try:
            sys.stderr.reconfigure(encoding="utf-8", errors="backslashreplace")
        except Exception:
            pass

    parser = argparse.ArgumentParser(description="raw EML 첨부파일 추출 및 무결성 검증 헬퍼")
    parser.add_argument("--eml", required=True, help="입력 raw .eml 파일 경로")
    parser.add_argument("--dir", default=".", help="첨부파일을 저장할 대상 디렉토리 (기본: .)")
    parser.add_argument("--json", action="store_true", help="결과를 JSON 형식으로 출력")

    args = parser.parse_args()

    eml_path = Path(args.eml)
    out_dir = Path(args.dir)

    try:
        results = export_attachments(eml_path, out_dir)
    except Exception as e:
        sys.stderr.write(f"mailskill attachment: 오류: {e}\n")
        sys.exit(1)

    has_failure = any(not r["verified"] for r in results)

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    else:
        if not results:
            print("mailskill attachment: 첨부파일이 없습니다.")
            sys.exit(0)

        for r in results:
            if r["verified"]:
                print(f"저장 완료: {r['path']} ({r['size']:,} 바이트, 무결성 확인: {r['message']})")
            else:
                sys.stderr.write(f"mailskill attachment: 무결성 검증 실패: {r['path']} ({r['message']})\n")

    if has_failure:
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
