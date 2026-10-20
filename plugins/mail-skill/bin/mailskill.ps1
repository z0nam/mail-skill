# mailskill (Windows / PowerShell) — 엔진 중립 어댑터. bin/mailskill(bash) 과 동일 계약.
#
#   mailskill accounts                     계정 목록 (JSON)
#   mailskill folders <acct>               폴더 목록 (JSON)
#   mailskill list    <acct> [-f <폴더>] [n]        최근 n통 (JSON, 기본 20)
#   mailskill search  <acct> [-f <폴더>] <query...> IMAP 쿼리 검색 (JSON)
#   mailskill read    <acct> <id> [folder] 메시지 읽기 (JSON)
#   mailskill reply   <acct> <id>          회신(초안) — 발송 전 사용자 승인 필수
#   mailskill watch   <acct> [옵션]        새 메일 폴링 대기 (도착 exit 0, 시간초과 exit 2)
#   mailskill doctor  <acct>               백엔드/계정 상태 점검
#
# stdout 계약: JSON 동사(accounts/folders/list/search/read)는 stdout 에 JSON 만 낸다.
# 진단·경고·에러는 전부 stderr. 백엔드 로그는 애초에 끈다.
#   디버깅: $env:MAILSKILL_LOG='debug'; mailskill list <acct>   (stderr 로만 나감)
$ErrorActionPreference = 'Stop'
# PS 7.4+ 는 네이티브 명령의 비정상 종료를 예외로 승격한다(기본 $true). 우리는 himalaya 의
# exit code 를 직접 읽어 "0건(out of bounds)"과 "실패"를 구분하므로 이 승격을 끈다.
# (PS 5.1 엔 이 변수가 없어 그냥 일반 변수 대입이 되고 무해하다.)
$PSNativeCommandUseErrorActionPreference = $false
$H = if ($env:HIMALAYA_BIN) { $env:HIMALAYA_BIN } else { 'himalaya' }
$env:RUST_LOG = if ($env:MAILSKILL_LOG) { $env:MAILSKILL_LOG } else { 'off' }

# 이 스크립트의 실제 위치(심링크/복사 모두) → REPO(scripts/ 를 찾기 위함).
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO = (Resolve-Path (Join-Path $scriptDir '..')).Path

function Fail([string]$msg, [int]$code = 1) { [Console]::Error.WriteLine($msg); exit $code }
function Req($v, [string]$label) { if ($null -eq $v -or $v -eq '') { Fail "mailskill: <$label> required" 2 }; return $v }
function Emit([string]$text) { [Console]::Out.WriteLine($text) }   # printf '%s\n' 등가

# $a 의 $start 이후를 배열로(빈 경우 @()). 역방향 슬라이스 함정을 피한다.
# 반환은 반드시 콤마 연산자로 감싼다 — 안 그러면 PowerShell 이 1개짜리 배열을
# 스칼라로 언롤해서, 호출측의 $x[0] 가 '문자열의 첫 글자'를 집어버린다
# (예: `mailskill list work` → acct='w', 페이지크기 '20' → '2').
function Tail([string[]]$a, [int]$start) {
    if ($null -eq $a -or $a.Count -le $start) { return , @() }
    return , @($a[$start..($a.Count - 1)])
}

function Get-PythonExe {
    foreach ($p in @('python3', 'python')) {
        if (Get-Command $p -ErrorAction SilentlyContinue) { return $p }
    }
    Fail 'mailskill: python 을 찾을 수 없습니다 (date-search 폴백 불가)' 1
}

# json_verb 등가 — JSON 동사 공통 래퍼.
# 백엔드 stdout 이 JSON 으로 확인된 경우에만 통과. 실패는 stderr + 비정상 종료.
# himalaya 가 0건에서 "page out of bounds" 로 죽는 케이스는 빈 결과([])로 승격.
function Invoke-Json([string[]]$BackendArgs) {
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $out = & $H @BackendArgs 2>$errFile
        $rc = $LASTEXITCODE
        $errText = Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue
        if ($rc -ne 0) {
            if ($errText -match 'out of bounds') { return '[]' }
            if ($errText) { [Console]::Error.Write($errText) }
            Fail "mailskill: backend failed (exit $rc): $($BackendArgs -join ' ')" $rc
        }
        if ($env:MAILSKILL_LOG -and $errText) { [Console]::Error.Write($errText) }
        $text = (@($out) -join "`n")
        $trimmed = $text.TrimStart()
        # 첫 글자가 '[' '{' '"' 중 하나여야 JSON. '"' 를 받는 이유: himalaya v1.2.0 의
        # `message read -o json` 은 메시지 전체를 JSON 문자열 스칼라 하나로 낸다.
        # 배열·객체만 허용하면 이 멀쩡한 출력이 반려돼 read 가 구조적으로 늘 실패한다.
        if (-not $trimmed -or ($trimmed[0] -ne '[' -and $trimmed[0] -ne '{' -and $trimmed[0] -ne '"')) {
            Fail "mailskill: backend produced non-JSON stdout (see stderr above): $($BackendArgs -join ' ')" 1
        }
        return $text
    }
    finally { Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue }
}

# 사용법은 이 파일 맨 위 계약 주석에서 뽑는다 — 두 군데에 적어두면 갈라진다.
# -ToErr: 사용법을 stderr 로(무동사=사용법 에러 경로용, bash 판과 동일).
function Show-Usage([switch]$ToErr) {
    $lines = @('usage: mailskill {accounts|folders|list|search|read|reply|watch|doctor} ...', '')
    $lines += Get-Content -LiteralPath $PSCommandPath |
        Where-Object { $_ -match '^#   mailskill ' } |
        ForEach-Object { $_ -replace '^#   ', '  ' }
    foreach ($l in $lines) {
        if ($ToErr) { [Console]::Error.WriteLine($l) } else { [Console]::Out.WriteLine($l) }
    }
}

$cmd = if ($args.Count -ge 1) { $args[0] } else { '' }
$rest = Tail $args 1
if ($cmd -eq 'watch') {
    $py = Get-PythonExe
    & $py (Join-Path $REPO 'scripts\mail-watch.py') @rest
    exit $LASTEXITCODE
}
# 명시적 help(동사 -h/--help/help, 또는 <동사> -h/--help) → 사용법 후 exit 0.
if ($cmd -in @('-h', '--help', 'help') -or ($rest.Count -ge 1 -and $rest[0] -in @('-h', '--help'))) {
    Show-Usage; exit 0
}
# 무동사 → 사용법(에러) 후 exit 2. CI 계약: no-args → 2.
if ($cmd -eq '') { Show-Usage -ToErr; exit 2 }

switch ($cmd) {
    'accounts' {
        if (-not (Get-Command $H -ErrorAction SilentlyContinue)) {
            [Console]::Error.WriteLine("mailskill: backend '$H' not found in PATH — returning []")
            Emit '[]'; exit 0
        }
        $out = & $H account list -o json 2>$null
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("mailskill: '$H account list' failed — returning []")
            Emit '[]'; exit 0
        }
        $text = (@($out) -join "`n").Trim()
        if (-not $text -or $text -eq 'null') { Emit '[]' } else { Emit $text }
        exit 0
    }
    'folders' {
        $acct = Req $rest[0] 'account'
        Emit (Invoke-Json @('folder', 'list', '-a', $acct, '-o', 'json')); exit 0
    }
    'list' {
        $acct = Req $rest[0] 'account'
        $q = Tail $rest 1
        $foldArgs = @()
        if ($q.Count -ge 1 -and $q[0] -eq '-f') { $foldArgs = @('-f', (Req $q[1] 'folder')); $q = Tail $q 2 }
        $n = if ($q.Count -ge 1) { $q[0] } else { '20' }
        Emit (Invoke-Json (@('envelope', 'list', '-a', $acct) + $foldArgs + @('--page-size', $n, '-o', 'json'))); exit 0
    }
    'search' {
        $acct = Req $rest[0] 'account'
        $q = Tail $rest 1
        $foldArgs = @(); $foldName = '-'
        if ($q.Count -ge 1 -and $q[0] -eq '-f') { $foldArgs = @('-f', (Req $q[1] 'folder')); $foldName = $q[1]; $q = Tail $q 2 }
        $query = $q

        # himalaya 기본 페이지 크기(10)에 조용히 잘리지 않도록 포화될 때까지 키운다.
        $out = ''
        foreach ($psize in 200, 1000, 5000) {
            $out = Invoke-Json (@('envelope', 'list', '-a', $acct) + $foldArgs + @('--page-size', "$psize", '-o', 'json', '--') + $query)
            $idCount = ([regex]::Matches($out, '"id"')).Count
            if ($idCount -lt $psize) { break }
            if ($psize -eq 5000) {
                Fail 'mailskill: 검색 결과가 5000건을 넘습니다 — 잘린 결과를 내보내지 않고 실패로 처리합니다. 기간·조건을 좁히십시오.' 1
            }
        }

        # 서버측 날짜 검색이 0건이면 클라이언트측으로 재확인(네이버웍스 등 SENTSINCE 오답 대응).
        # 단, 질의가 '날짜 조건만'(and 결합, order-by 꼬리 허용)일 때만. from/subject 혼합·or/not 은 안 함.
        if ($out -eq '[]') {
            $toks = @($query)
            # 정렬 꼬리(order by ...) 제거.
            for ($i = 0; $i -lt $toks.Count; $i++) {
                if ($toks[$i] -eq 'order' -and ($i + 1) -lt $toks.Count -and $toks[$i + 1] -eq 'by') {
                    $toks = Tail $toks 0 | Select-Object -First $i
                    $toks = @($toks); break
                }
            }
            $pure = $true; $dargs = @(); $prev = ''
            foreach ($tok in $toks) {
                if ($tok -notmatch '^(after|before|date|and)$' -and $tok -notmatch '^\d{4}-\d{2}-\d{2}$') { $pure = $false }
                if ($prev -in @('after', 'before', 'date')) { $dargs += "$prev=$tok" }
                $prev = $tok
            }
            if ($pure -and $dargs.Count -gt 0) {
                if ($env:MAILSKILL_LOG) { [Console]::Error.WriteLine('mailskill: 서버측 날짜 검색 0건 → 클라이언트측 재확인') }
                $py = Get-PythonExe
                $fb = & $py (Join-Path $REPO 'scripts\date-search.py') $acct $foldName @dargs
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                Emit (@($fb) -join "`n"); exit 0
            }
        }
        Emit $out; exit 0
    }
    'read' {
        $acct = Req $rest[0] 'account'
        $id = Req $rest[1] 'id'
        $folder = if ($rest.Count -ge 3) { $rest[2] } else { $null }
        $fArgs = if ($folder) { @('-f', $folder) } else { @() }
        Emit (Invoke-Json (@('message', 'read', $id, '-a', $acct) + $fArgs + @('-o', 'json'))); exit 0
    }
    'reply' {
        $acct = Req $rest[0] 'account'; $id = Req $rest[1] 'id'
        & $H message reply $id -a $acct
        exit $LASTEXITCODE
    }
    'doctor' {
        $acct = Req $rest[0] 'account'
        & $H account doctor $acct
        exit $LASTEXITCODE
    }
    default {
        [Console]::Error.WriteLine("mailskill: 알 수 없는 동사 '$cmd'")
        Show-Usage | ForEach-Object { [Console]::Error.WriteLine($_) }
        exit 2
    }
}
