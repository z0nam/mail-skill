# read-masked.sh — 비밀번호를 글자마다 '*' 로 보여주며 받는다(bash, source 해서 쓴다).
#   read_masked "<프롬프트>"   → 결과는 전역 MASKED 에. 화면에는 '*' 와 길이만 나간다.
# 값은 어디에도 출력하지 않는다. 다 쓰면 호출측이 MASKED="" 로 지운다.
# Enter=끝, Backspace/DEL=한 글자 지움(별표도), 그 밖의 제어문자는 무시. 붙여넣기도 한 글자씩 들어온다.
read_masked() {
  local c old="" intr=0
  MASKED=""
  # 에코는 루프 전체에서 꺼 둔다. `read -s` 만 쓰면 read 호출 사이의 틈에 들어온 글자
  # (붙여넣기처럼 빠른 입력)를 터미널이 평문으로 에코한다 — 테스트(pty)에서 실제로 새어 나왔다.
  # 프롬프트보다 먼저 끈다 — 프롬프트를 보자마자 붙여넣으면 그 사이 틈에서도 샌다.
  if [ -t 0 ]; then old="$(stty -g)"; stty -echo -icanon min 1 time 0; fi
  printf '%s' "$1" >&2
  # 한 글자는 bash `read -n1/-s` 대신 dd 로 읽는다. read 는 자기 나름으로 터미널 설정을
  # 저장·복원해서, Ctrl+C 로 끊기면 풀리면서 (에코·정규모드가 꺼진) 설정으로 되돌려 버린다
  # (Codex #17 지적, pty 로 재현). 터미널 설정은 위의 stty 한 곳만 만진다.
  # Ctrl+C 는 표시만 하고(dd 가 죽어 빈 값이 온다) 루프를 빠져나온 뒤 복원·종료한다.
  trap 'intr=1' INT
  while [ "$intr" = 0 ]; do
    c="$(dd bs=1 count=1 2>/dev/null)" || true
    [ "$intr" = 0 ] || break
    case "$c" in
      '') break ;;                                   # Enter(개행은 \$(…) 가 떼어 내 빈 값)
      $'\x7f'|$'\b')
        if [ -n "$MASKED" ]; then MASKED="${MASKED%?}"; printf '\b \b' >&2; fi ;;
      [[:cntrl:]]) ;;                                # Tab·ESC 등은 버린다
      *) MASKED="$MASKED$c"; printf '*' >&2 ;;
    esac
  done
  if [ -n "$old" ]; then stty "$old" 2>/dev/null || true; fi
  trap - INT
  if [ "$intr" = 1 ]; then MASKED=""; printf '\n' >&2; exit 130; fi
  printf '\n받음 %d자\n' "${#MASKED}" >&2
}
