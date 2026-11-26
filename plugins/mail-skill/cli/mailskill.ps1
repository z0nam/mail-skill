# mailskill (Windows / PowerShell) — 엔진 중립 어댑터. cli/mailskill(bash) 과 동일 계약.
#
#   mailskill accounts                     계정 목록 (JSON)
#   mailskill folders <acct>               폴더 목록 (JSON)
#   mailskill list    <acct> [-f <폴더>] [n]        최근 n통 (JSON, 기본 20)
#   mailskill search  <acct> [-f <폴더>] <query...> 검색 (JSON). himalaya 쿼리 DSL 또는 맨 키워드
#   mailskill search  gmail from koreanair.com and after 2026-11-01   예: DSL(첫 낱말이 not/date/before/after/from/to/subject/body/flag/order/괄호)은 그대로
#   mailskill search  gmail 대한항공 항공권   예: 맨 키워드 → (subject 대한항공 or body 대한항공) and (subject 항공권 or body 항공권)
#   mailskill search  gmail "hello world"     예: 따옴표로 묶은 한 인자는 구(phrase) 하나로 → subject hello\ world or body hello\ world
#   mailskill read    <acct> <id> [folder] 메시지 읽기 (JSON)
#   mailskill reply   <acct> <id>          회신(초안) — 발송 전 사용자 승인 필수
#   mailskill send    <acct> [옵션]        메일 발송/답장(첨부 가능) — 기본 미리보기, --send 로 실전송
#   mailskill attachment <acct> <id> [dir] 첨부파일 다운로드 (무결성 검증)
#   mailskill watch   <acct> [옵션]        새 메일 폴링 대기 (도착 exit 0, 시간초과 exit 2)
#   mailskill doctor  <acct>               백엔드/계정 상태 점검
#   mailskill setup   [옵션]               회사메일 1회 설정(앱비번 숨김입력·암호화저장·설정생성·로그인확인)
#
# stdout 계약: JSON 동사(accounts/folders/list/search/read)는 stdout 에 JSON 만 낸다.
# 진단·경고·에러는 전부 stderr. 백엔드 로그는 애초에 끈다.
#   디버깅: $env:MAILSKILL_LOG='debug'; mailskill list <acct>   (stderr 로만 나감)
$ErrorActionPreference = 'Stop'
# PowerShell 7 창에서 부르면 PS7 의 PSModulePath 가 이 5.1 프로세스에 상속돼, 5.1 이 PS7 판
# Microsoft.PowerShell.Security·Utility 를 자동 로드하다 CouldNotAutoloadMatchingModule 로 깨진다
# (ConvertTo-SecureString·ConvertFrom-Json, jaix-kit#205). 5.1 에서는 경로 조각에 'PowerShell'
# 폴더가 든 항목(PS7 모듈 폴더, WindowsPowerShell 은 해당 없음)을 빼고 시작한다.
if ($PSVersionTable.PSVersion.Major -lt 6 -and $env:PSModulePath) {
    $env:PSModulePath = (($env:PSModulePath -split ';') | Where-Object { $_ -and (($_ -split '[\\/]') -notcontains 'PowerShell') }) -join ';'
}
# PS 7.4+ 는 네이티브 명령의 비정상 종료를 예외로 승격한다(기본 $true). 우리는 himalaya 의
# exit code 를 직접 읽어 "0건(out of bounds)"과 "실패"를 구분하므로 이 승격을 끈다.
# (PS 5.1 엔 이 변수가 없어 그냥 일반 변수 대입이 되고 무해하다.)
$PSNativeCommandUseErrorActionPreference = $false
$H = if ($env:HIMALAYA_BIN) { $env:HIMALAYA_BIN } else { 'himalaya' }
$env:RUST_LOG = if ($env:MAILSKILL_LOG) { $env:MAILSKILL_LOG } else { 'off' }
# 색 끄기 요청. 백엔드 에러 원문의 ANSI 색·안내 꼬리는 hjson.py(실행 모드)가 걷어낸다.
$env:NO_COLOR = '1'

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

function Get-PythonCmd {
    # uv 및 uv 관리 Python 3.12 우선 실행:
    # --no-project: 현재/상위 디렉터리의 pyproject.toml 탐색 및 .venv 생성 방지
    # -q: stderr 로그 억제로 strict JSON 계약 보호
    # --no-python-downloads: 앱 내부 다운로드 차단(TS-RUNTIME-2 및 MSIX 가상화 보호)
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        $prevEap = $ErrorActionPreference
        try {
            # PS 5.1 은 네이티브 stderr 를 종료 에러(terminating error)로 승격할 수 있으므로
            # 3.12 미설치 프로브 실패 시 안전하게 폴백하기 위해 EAP 를 일시 완화한다.
            $ErrorActionPreference = 'Continue'
            $null = & uv python find 3.12 2>$null
            if ($LASTEXITCODE -eq 0) {
                return , @('uv', 'run', '--no-project', '-q', '--no-python-downloads', '--python', '3.12')
            }
        }
        finally {
            $ErrorActionPreference = $prevEap
        }
    }
    foreach ($p in @('python3', 'python')) {
        if (Get-Command $p -ErrorAction SilentlyContinue) {
            return , @($p)
        }
    }
    Fail 'mailskill: uv 또는 python(3)을 찾을 수 없습니다' 1
}

# python 헬퍼 실행. stderr 는 2>&1 로 합쳐 ErrorRecord 만 .Exception.Message(원문)로 [Console]::Error 에
# 다시 쓰고, 나머지(stdout)는 그대로 흘린다(#27 방식 D). 파일 EAP=Stop 에서 네이티브 stderr 가
# 리다이렉트되면 PS 5.1 이 "uv.exe : …" NativeCommandError 로 승격해 rc 를 읽기 전에 멈추므로
# (dup-guard 가 경고를 쓰고 exit 3 → 미리보기 대신 exit 1, #30 실기) 함수 안에서만 EAP=Continue.
# $quietErr 면 stderr 를 버린다(미리보기의 dup-guard — bash 판 >/dev/null 2>&1 과 같음).
function Invoke-PythonCore([bool]$quietErr, [object[]]$pyArgs) {
    $cmd = Get-PythonCmd
    $exe = $cmd[0]
    $prefix = Tail $cmd 1
    $allArgs = @($prefix) + @($pyArgs)
    # 한글 Windows 는 python 기본 인코딩이 cp949 라 himalaya 의 UTF-8 출력을 읽다 깨진다.
    # 자식 python 의 입출력·subprocess 기본을 UTF-8 로 고정하고, 그 UTF-8 stdout 을
    # PowerShell 이 cp949 로 잘못 읽지 않도록 호출 동안만 콘솔 출력 인코딩도 UTF-8 로 맞춘다.
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    $prevOutEnc = $null
    try { $prevOutEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { $prevOutEnc = $null }
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @allArgs 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                if (-not $quietErr) { [Console]::Error.WriteLine($_.Exception.Message) }
            } else { $_ }
        }
    }
    finally { if ($null -ne $prevOutEnc) { try { [Console]::OutputEncoding = $prevOutEnc } catch {} } }
}
function Invoke-Python { Invoke-PythonCore $false $args }
function Invoke-PythonQuiet { Invoke-PythonCore $true $args }

function Get-PythonExe {
    # 구버전 호환용 (단일 실행파일 이름 반환)
    foreach ($p in @('python3', 'python')) {
        if (Get-Command $p -ErrorAction SilentlyContinue) { return $p }
    }
    Fail 'mailskill: python 을 찾을 수 없습니다' 1
}

# search 인자를 himalaya 쿼리로 바꾼다(bash 판 search_query 와 같은 규칙 — 한쪽만 고치지 말 것).
# 첫 낱말(앞쪽 '(' 제외)이 himalaya DSL 키워드면 그대로(대소문자 무시 — 대문자 오타는
# himalaya 파스 에러가 그대로 보이게). 아니면 맨 키워드로 보고 인자마다 "subject <kw> or body <kw>"
# 로 감싸 and 로 잇는다(#25). 인자 안의 공백·괄호·역슬래시는 역슬래시로 이스케이프 — himalaya
# 패턴에서 따옴표는 글자 그대로라 구를 못 묶고, '\ ' 이스케이프는 받는다(실측). 인자를 감싼
# 바깥 큰따옴표 한 쌍은 벗긴다. body 가 든 OR 묶음의 분해·합집합은 search.py 몫(웍스 BODY 0건, #30).
function ConvertTo-SearchQuery([string[]]$q) {
    if ($null -eq $q -or $q.Count -eq 0) { return , @() }
    # 첫 인자의 첫 낱말로 판정한다 — "subject hello" 처럼 DSL 전체를 한 인자로 넘기는 호출도 있다.
    $first = (([string]$q[0]).TrimStart().TrimStart('(') -split '\s', 2)[0].ToLowerInvariant()
    if ($first -in @('', 'not', 'date', 'before', 'after', 'from', 'to', 'subject', 'body', 'flag', 'order')) {
        return , @($q)
    }
    $terms = @()
    foreach ($kw in $q) {
        $k = [string]$kw
        if ($k.Length -ge 2 -and $k.StartsWith('"') -and $k.EndsWith('"')) { $k = $k.Substring(1, $k.Length - 2) }
        if (-not $k.Trim()) { continue }
        $terms += ($k -replace '([\\ ()])', '\$1')
    }
    if ($terms.Count -eq 1) { return , @('subject', $terms[0], 'or', 'body', $terms[0]) }
    $out = @()
    foreach ($t in $terms) {
        if ($out.Count -gt 0) { $out += 'and' }
        $out += @('(subject', $t, 'or', 'body', "$t)")
    }
    return , $out
}

# himalaya 2.x 호출은 전부 scripts\hjson.py 를 거친다(#30). python 이 himalaya 를 직접 실행해
# 출력을 바이트로 받으므로 PS 5.1 파이프의 바이트·cp949 왜곡이 끼지 않는다. 2.x 는 에러를 stdout 으로
# 내는데, hjson 이 그걸 꺼내 stderr 로 옮기고 stdout 을 비운 채 같은 rc 로 끝낸다 — 그래서 여기서는
# stderr 를 가로채지 않고 그대로 흘린다(2>파일 로 받지 않는다. PS 5.1 ErrorRecord 노이즈, #27).
# 반환: stdout 텍스트. 실패(rc≠0)면 버전 안내(Show-VersionHint)를 한 번 낸 뒤 그 rc 로 바로 끝낸다.
function Invoke-Hjson([string]$kind, [string[]]$BackendArgs) {
    $hjson = Join-Path $REPO 'scripts\hjson.py'
    $out = Invoke-Python $hjson $kind '--' @BackendArgs
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { if ($rc -ne 127) { Show-VersionHint }; exit $rc }
    return (@($out) -join "`n")
}

# 백엔드 호출이 실패했을 때만(실행 파일 없음 127 제외) 버전 가드를 한 번 돌린다(bash 판 version_hint 와 같음).
# 1.x 가 깔려 있으면 2.x 전용 플래그(--json 등)에서 사용법 에러로 깨지는데, 그 원문만으로는 원인을 알기 어렵다.
# 성공 경로에는 비용이 없다. 안내 문구는 hjson.py version 이 stderr 로 낸다(stdout 판정 한 단어는 버린다).
function Show-VersionHint {
    $null = Invoke-Python (Join-Path $REPO 'scripts\hjson.py') version
}

# 사용자 인자 -f <폴더> → himalaya 2.x 의 -m <폴더>. 사용자 계약(-f)은 1.x 와 같게 둔다.
function ConvertTo-MailboxArgs([string]$folder) {
    if ($folder) { return , @('-m', $folder) }
    return , @()
}

# himalaya 2.x 가 실제로 읽는 config 경로(기본 탐색 순서). Windows 에서는 -c / HIMALAYA_CONFIG 에
# 절대경로를 주지 않는다 — clap 이 ':' 로 쪼개 'C' 와 '\Users\...' 둘로 갈라진다(#30). 그래서
# 어댑터는 경로를 넘기지 않고 이 순서를 흉내 내 "어느 파일이 읽히는지"만 안다(compose-mime 의 From).
#   1) %APPDATA%\himalaya\config.toml   2) ~\.config\himalaya\config.toml   3) ~\.himalayarc
function Get-HimalayaConfigCandidates {
    $c = @()
    if ($env:APPDATA) { $c += (Join-Path $env:APPDATA 'himalaya\config.toml') }
    $c += (Join-Path $HOME '.config\himalaya\config.toml')
    $c += (Join-Path $HOME '.himalayarc')
    return , $c
}
function Resolve-HimalayaConfig {
    if ($env:HIMALAYA_CONFIG) { return $env:HIMALAYA_CONFIG }
    foreach ($p in (Get-HimalayaConfigCandidates)) { if (Test-Path -LiteralPath $p) { return $p } }
    return (Join-Path $REPO 'config\config.toml')
}
# %APPDATA% 쪽 파일이 있으면 setup 이 쓰는 ~\.config 쪽은 읽히지 않는다(조용히 가려짐). 경고만 한다.
function Write-ConfigShadowWarning {
    $c = Get-HimalayaConfigCandidates
    if ($env:APPDATA -and (Test-Path -LiteralPath $c[0]) -and (Test-Path -LiteralPath $c[1])) {
        [Console]::Error.WriteLine("mailskill: [주의] $($c[0]) 가 있어서 $($c[1]) 는 읽히지 않습니다(himalaya 2.x 는 %APPDATA% 쪽을 먼저 씁니다). 하나만 남기세요.")
    }
}

# 사용법은 이 파일 맨 위 계약 주석에서 뽑는다 — 두 군데에 적어두면 갈라진다.
# -ToErr: 사용법을 stderr 로(무동사=사용법 에러 경로용, bash 판과 동일).
function Show-Usage([switch]$ToErr) {
    $lines = @('usage: mailskill {accounts|folders|list|search|read|reply|send|attachment|watch|doctor|setup} ...', '')
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
    Invoke-Python (Join-Path $REPO 'scripts\mail-watch.py') @rest
    exit $LASTEXITCODE
}
# setup 은 자기 --help 를 가진다. 같은 프로세스에서 불러야 Read-Host 숨김 입력이 이 콘솔을 쓴다.
if ($cmd -eq 'setup') {
    & (Join-Path $REPO 'scripts\mail-setup.ps1') @rest
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
        # 계정 목록은 "조회 실패여도 [] + exit 0" 계약이라 Invoke-Hjson(실패=즉시 종료)을 쓰지 않는다.
        $out = Invoke-Python (Join-Path $REPO 'scripts\hjson.py') accounts '--' account list
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
        Emit (Invoke-Hjson 'folders' @('mailbox', 'list', '-a', $acct)); exit 0
    }
    'list' {
        $acct = Req $rest[0] 'account'
        $q = Tail $rest 1
        $foldArgs = @()
        if ($q.Count -ge 1 -and $q[0] -eq '-f') { $foldArgs = ConvertTo-MailboxArgs (Req $q[1] 'folder'); $q = Tail $q 2 }
        $n = if ($q.Count -ge 1) { $q[0] } else { '20' }
        Emit (Invoke-Hjson 'envelopes' (@('envelope', 'list', '-a', $acct) + $foldArgs + @('-s', $n, '--has-attachment'))); exit 0
    }
    'search' {
        $acct = Req $rest[0] 'account'
        $q = Tail $rest 1
        $foldName = '-'
        if ($q.Count -ge 1 -and $q[0] -eq '-f') { $foldName = (Req $q[1] 'folder'); $q = Tail $q 2 }
        # 맨 키워드면 subject/body DSL 로 감싼다(#25). DSL 이면 그대로.
        $backendQuery = ConvertTo-SearchQuery $q
        # 나머지는 search.py 가 한다(#30): 날짜 절(after/before/date)은 서버에 보내지 않고 클라이언트에서
        # 거른다(웍스 SENTSINCE 0건·2.x 에서 before 삭제 대응), 페이지 크기 200→1000→5000 포화 검사,
        # envelope search/list 선택, 1.x 봉투 모양 정규화. 예전의 "0건이면 date-search 재확인"은 흡수됐다.
        $out = Invoke-Python (Join-Path $REPO 'scripts\search.py') $acct $foldName '--' @backendQuery
        $rc = $LASTEXITCODE
        if ($rc -ne 0) { if ($rc -ne 2 -and $rc -ne 127) { Show-VersionHint }; exit $rc }
        Emit (@($out) -join "`n"); exit 0
    }
    'read' {
        $acct = Req $rest[0] 'account'
        $id = Req $rest[1] 'id'
        $folder = if ($rest.Count -ge 3) { $rest[2] } else { $null }
        $fArgs = ConvertTo-MailboxArgs $folder
        # hjson read 가 --raw 원문을 1.x 와 같은 JSON 문자열 스칼라("From: ..\n\n본문")로 바꾼다.
        # 2.x 는 기본으로 \Seen 을 찍지 않는다(1.x 는 찍었다).
        $out = Invoke-Hjson 'read' (@('message', 'read', $id, '-a', $acct) + $fArgs)
        # 방어: 빈 JSON 문자열("")이면 "메시지 없음"으로 본다(1.2.0 IMAP 의 없는 id 동작, #29).
        if (($out -replace '\s', '') -eq '""') {
            $where = if ($folder) { ", 폴더 '$folder'" } else { '' }
            Fail "mailskill read: 메시지를 찾을 수 없습니다 — 계정 '$acct', id '$id'$where. id 와 폴더(-f 기본 INBOX)를 확인하십시오." 1
        }
        Emit $out; exit 0
    }
    'reply' {
        # himalaya 2.x 의 message reply 는 비대화형·플래그 기반으로 바뀌었다(#30). 미리보기 게이트를
        # 유지하려고 send --reply-to <id> 로 넘긴다(bash 판과 같음). 나머지 옵션은 그대로 전달.
        $acct = Req $rest[0] 'account'; $id = Req $rest[1] 'id'
        $fwd = @('send', $acct, '--reply-to', $id) + (Tail $rest 2)
        & $PSCommandPath @fwd
        exit $LASTEXITCODE
    }
    'send' {
        $acct = Req $rest[0] 'account'
        $opts = Tail $rest 1
        $to = $null; $cc = $null; $bcc = $null; $subj = $null
        $replyto = $null; $replyfold = $null
        $body = $null; $bodyfile = $null; $attach = @()
        $dosend = $false; $force = $false; $dupwindow = 10; $hasbody = $false

        $i = 0
        while ($i -lt $opts.Count) {
            $opt = $opts[$i]
            switch ($opt) {
                '--to'           { $to = Req $opts[$i + 1] 'to'; $i += 2 }
                '--cc'           { $cc = Req $opts[$i + 1] 'cc'; $i += 2 }
                '--bcc'          { $bcc = Req $opts[$i + 1] 'bcc'; $i += 2 }
                '--subject'      { $subj = Req $opts[$i + 1] 'subject'; $i += 2 }
                '--reply-to'     { $replyto = Req $opts[$i + 1] 'reply-to'; $i += 2 }
                '--reply-folder' { $replyfold = Req $opts[$i + 1] 'reply-folder'; $i += 2 }
                '--body'         { $body = Req $opts[$i + 1] 'body'; $hasbody = $true; $i += 2 }
                '--body-file'    { $bodyfile = Req $opts[$i + 1] 'body-file'; $hasbody = $true; $i += 2 }
                '--attach'       { $attach += (Req $opts[$i + 1] 'attach'); $i += 2 }
                '--force'        { $force = $true; $i += 1 }
                '--dup-window'   { $dupwindow = [int](Req $opts[$i + 1] 'dup-window'); $i += 2 }
                '--send'         { $dosend = $true; $i += 1 }
                default {
                    Fail "mailskill send: 알 수 없는 옵션 '$opt'" 2
                }
            }
        }

        if (-not $to -and -not $replyto) {
            Fail "mailskill send: --to 또는 --reply-to 필요" 2
        }
        if (-not $subj -and -not $replyto) {
            Fail "mailskill send: --subject 또는 --reply-to 필요" 2
        }
        if (-not $hasbody) {
            Fail "mailskill send: --body 또는 --body-file 필요" 2
        }

        # stdin 본문이면 임시 파일에 먼저 보존(BOM 없는 UTF-8 인스턴스로 저장하여 U+FEFF 누출 방지)
        $stdinTmp = $null
        if ($bodyfile -eq "-") {
            $stdinTmp = [System.IO.Path]::GetTempFileName()
            $stdinContent = [Console]::In.ReadToEnd()
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($stdinTmp, $stdinContent, $utf8NoBom)
            $bodyfile = $stdinTmp
        }

        try {
            # compose-mime(From 해석)·dup-guard 가 읽을 config. himalaya 2.x 기본 탐색 순서를 따른다.
            $config = Resolve-HimalayaConfig

            $composePy = Join-Path $REPO 'scripts\compose-mime.py'
            $dupGuardPy = Join-Path $REPO 'scripts\dup-guard.py'

            $cargs = @($composePy, '--from-account', $acct, '--config', $config, '--himalaya-bin', $H)
            if ($to) { $cargs += @('--to', $to) }
            if ($cc) { $cargs += @('--cc', $cc) }
            if ($bcc) { $cargs += @('--bcc', $bcc) }
            if ($subj) { $cargs += @('--subject', $subj) }
            if ($replyto) { $cargs += @('--reply-to-id', $replyto) }
            if ($replyfold) { $cargs += @('--reply-folder', $replyfold) }
            if ($null -ne $body) { $cargs += @('--body', $body) }
            if ($bodyfile) { $cargs += @('--body-file', $bodyfile) }
            foreach ($att in $attach) { $cargs += @('--attach', $att) }

            # 1. 메타데이터 조회
            $metaJson = Invoke-Python @cargs @('--dump-meta')
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            $metaText = (@($metaJson) -join "`n")
            $meta = $metaText | ConvertFrom-Json
            $metaTo = $meta.to
            $metaSubj = $meta.subject
            $inReplyTo = $meta.in_reply_to
            $references = $meta.references
            # 첨부 한도 가드(#24). 문구는 compose-mime.py 가 만든다(bash 어댑터와 공유).
            $attachOver = [bool]$meta.attach_over_limit
            $attachSummary = $meta.attach_summary
            $attachGuardMsg = $meta.attach_guard_message

            # 2. 미리보기
            if (-not $dosend) {
                $dupWarn = 0
                if (-not $force) {
                    $null = Invoke-PythonQuiet $dupGuardPy --account $acct --to $metaTo --subject $metaSubj --window $dupwindow --config $config --himalaya-bin $H
                    $dupWarn = $LASTEXITCODE
                }
                Emit '── mailskill send 미리보기 (실전송하려면 동일 명령에 --send 추가) ──'
                Emit "계정(From): $acct"
                Emit "받는사람  : $metaTo"
                if ($cc) { Emit "참조      : $cc" }
                if ($bcc) { Emit "숨은참조  : $bcc" }
                Emit "제목      : $metaSubj"
                if ($inReplyTo) { Emit "In-Reply-To: $inReplyTo" }
                if ($references) { Emit "References : $references" }
                if ($attach.Count -gt 0) {
                    Emit "첨부      : $($attach -join ' ')"
                    Emit "첨부 합계 : $attachSummary"
                }
                Emit '본문:'
                if ($null -ne $body) {
                    foreach ($l in $body.Split("`n")) { Emit "  $l" }
                } elseif ($bodyfile -eq '-') {
                    Emit '  (stdin)'
                } else {
                    # -Encoding UTF8: 본문 파일은 보통 BOM 없는 UTF-8 이라, 지정이 없으면
                    # 한글 Windows 콘솔 기본 인코딩(cp949)으로 읽혀 미리보기가 깨진다.
                    # (실전송은 compose-mime.py 가 utf-8-sig 로 읽어 정상 — 미리보기 전용 버그.)
                    $bLines = Get-Content -LiteralPath $bodyfile -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -First 60
                    foreach ($l in $bLines) { Emit "  $l" }
                }
                if ($dupWarn -eq 3) {
                    Emit ''
                    Emit "⚠️  주의: 최근 ${dupwindow}분 내 동일 수신자+제목 발송 이력이 있습니다. 실전송 시 --force 옵션이 필요합니다."
                }
                if ($attachOver) {
                    Emit ''
                    foreach ($l in ("⛔ $attachGuardMsg").Split("`n")) { Emit $l }
                    Emit '   (이 상태로는 --send 해도 발송되지 않습니다.)'
                }
                exit 0
            }

            # 3. 실전송
            # 첨부 한도 가드(#24): 중복 가드·MIME 조립보다 먼저 막는다. --force 로도 넘을 수 없다.
            if ($attachOver) {
                Fail "mailskill send: $attachGuardMsg" 4
            }
            # 중복 발송 가드: --force 가 아닐 때 보낸편지함 검사
            if (-not $force) {
                Invoke-Python $dupGuardPy --account $acct --to $metaTo --subject $metaSubj --window $dupwindow --config $config --himalaya-bin $H
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            }

            # 발송은 hjson.py send 가 한다(#30): python 이 `message send -a A -- <파일>` 을 직접 실행하므로
            # cmd /c "... < 파일" 리다이렉트가 필요 없다. "Message sent, but saving a copy ... failed"
            # (SMTP 발송 성공 + 보낸함 저장 실패)는 hjson 이 재시도 금지 안내와 함께 exit 0 으로 낸다 —
            # 1.x 의 APPEND-UID 분기를 대체(중복 발송 방지). 분류 한 단어(sent|sent-save-failed|failed)는 stdout.
            # compose-mime.py 의 -o 로 MIME 을 바이너리 파일에 직접 써서 파이프 인코딩 왜곡을 피한다.
            $tmpMime = [System.IO.Path]::GetTempFileName()
            try {
                Invoke-Python @cargs @('-o', $tmpMime)
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                $res = Invoke-Python (Join-Path $REPO 'scripts\hjson.py') send --account $acct --file $tmpMime
                $rc = $LASTEXITCODE
                $kind = (@($res) -join "`n").Trim()
                if ($rc -ne 0) { if ($rc -ne 127) { Show-VersionHint }; Fail "mailskill send: 발송 실패 (exit $rc)" $rc }
                if ($kind -eq 'sent-save-failed') { [Console]::Error.WriteLine('mailskill send: 발송 완료(보낸함 사본 저장만 실패) - 재시도 금지') }
                else { [Console]::Error.WriteLine('mailskill send: 발송 완료') }
                exit 0
            }
            finally {
                Remove-Item -LiteralPath $tmpMime -ErrorAction SilentlyContinue
            }
        }
        finally {
            if ($stdinTmp) { Remove-Item -LiteralPath $stdinTmp -ErrorAction SilentlyContinue }
        }
    }
    'attachment' {
        $acct = Req $rest[0] 'account'
        $id = Req $rest[1] 'id'
        $q = Tail $rest 2
        $foldArgs = @()
        $outDir = '.'
        $i = 0
        while ($i -lt $q.Count) {
            if ($q[$i] -eq '-f') {
                $foldArgs = ConvertTo-MailboxArgs (Req $q[$i + 1] 'folder')
                $i += 2
            } else {
                $outDir = $q[$i]
                $i += 1
            }
        }

        $tmpDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString())
        [System.IO.Directory]::CreateDirectory($tmpDir) | Out-Null
        $tmpEml = [System.IO.Path]::Combine($tmpDir, 'raw.eml')

        try {
            # 2.x 에는 message export 가 없다 → message read --raw 원문을 파일로. hjson raw 가 바이트 그대로
            # 쓰므로 PS 5.1 파이프(문자열 변환)나 cmd /c "... > 파일" 이 필요 없다(#30).
            $null = Invoke-Python (Join-Path $REPO 'scripts\hjson.py') raw '--out' $tmpEml '--' message read $id -a $acct @foldArgs
            $rc = $LASTEXITCODE
            if ($rc -ne 0) { if ($rc -ne 127) { Show-VersionHint }; Fail "mailskill attachment: raw eml 내보내기 실패 (exit $rc)" $rc }

            $env:PYTHONIOENCODING = 'utf-8'
            $exportPy = Join-Path $REPO 'scripts\attachment-export.py'
            Invoke-Python $exportPy '--eml' $tmpEml '--dir' $outDir
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            exit 0
        }
        finally {
            Remove-Item -Recurse -Force -LiteralPath $tmpDir -ErrorAction SilentlyContinue
        }
    }
    'doctor' {
        # 2.x: account doctor → account check. check 는 백엔드가 FAIL 이어도 exit 0 이라, 판정은
        # hjson.py check 가 한다(stdout 첫 줄 ok|auth|secret|config|network + 백엔드별 보고, 실패면 exit 3 +
        # stderr 에 "문장 / -> 고치는 법" 두 줄). bash 판과 같이 doctor 는 실패면 exit 1.
        # 버전 가드를 먼저 — 1.x 가 깔려 있으면 check 가 CLI 파싱에서 깨져 엉뚱한 원인으로 보이기 때문.
        $acct = Req $rest[0] 'account'
        $hjson = Join-Path $REPO 'scripts\hjson.py'
        $null = Invoke-Python $hjson version
        if ($LASTEXITCODE -ne 0) { exit 1 }   # bash 판과 같이 doctor 실패는 모두 exit 1
        Write-ConfigShadowWarning
        $res = Invoke-Python $hjson check --account $acct
        $rc = $LASTEXITCODE
        foreach ($l in @($res)) { Emit ([string]$l) }
        $verdict = (@($res) | Select-Object -First 1)
        if ($rc -ne 0 -or $verdict -ne 'ok') { exit 1 }
        exit 0
    }
    default {
        [Console]::Error.WriteLine("mailskill: 알 수 없는 동사 '$cmd'")
        Show-Usage | ForEach-Object { [Console]::Error.WriteLine($_) }
        exit 2
    }
}
