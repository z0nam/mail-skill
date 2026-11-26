# mailskill setup (Windows / PowerShell) — 회사메일(NAVER WORKS) 1회 설정. bash 판 scripts/mail-setup 과 같은 계약.
#   1) age 키 보장(없으면 생성) + recipients.txt 에 이 기계 공개키
#   2) 앱 비밀번호를 숨김 입력(SecureString) -> secret-set 으로 himalaya-<acct>-imap / -smtp 두 이름에 저장
#   3) 템플릿(config\works.template.toml, himalaya 2.x 형식)으로 이 PC 전용 himalaya config 생성
#      (기존 config 가 1.x 형식이면 .bak-v1-<시각> 으로 옮기고 새로 만든다)
#   4) hjson.py check(himalaya account check) 로 password.command -> age 복호 -> IMAP/SMTP 로그인 확인
#
#   mailskill setup [--email <주소>] [--login <아이디>] [--display-name <이름>]
#                   [--account <이름>] [--password-stdin] [--no-verify]
#
# 비밀번호는 인자로 받지 않는다. 화면·로그·평문 파일에 남기지 않는다(age 암호화 저장만).
# 런타임(himalaya 2.x·age·python)은 설치하지 않는다. 없으면 무엇이 없는지만 알린다(TS-RUNTIME-2).
# exit: 0 완료 · 1 환경 문제(런타임·키·설정) · 2 사용법 · 3 저장은 됐으나 로그인 확인 실패
#
# 화면 출력은 cp949 콘솔에서도 깨지지 않는 글자만 쓴다(TS-WIN-3: ✓ ✗ — 같은 기호 금지).
# himalaya 출력은 영문 키워드로만 판정한다(인코딩과 무관하게).
$ErrorActionPreference = 'Stop'
# PowerShell 7 창에서 부르면 PS7 의 PSModulePath 가 이 5.1 프로세스에 상속돼, 5.1 이 PS7 판
# Microsoft.PowerShell.Security·Utility 를 자동 로드하다 CouldNotAutoloadMatchingModule 로 깨진다
# (ConvertTo-SecureString·ConvertFrom-Json, jaix-kit#205). 5.1 에서는 경로 조각에 'PowerShell'
# 폴더가 든 항목(PS7 모듈 폴더, WindowsPowerShell 은 해당 없음)을 빼고 시작한다.
if ($PSVersionTable.PSVersion.Major -lt 6 -and $env:PSModulePath) {
    $env:PSModulePath = (($env:PSModulePath -split ';') | Where-Object { $_ -and (($_ -split '[\\/]') -notcontains 'PowerShell') }) -join ';'
}
$PSNativeCommandUseErrorActionPreference = $false

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = if ($env:MAIL_SKILL_REPO) { $env:MAIL_SKILL_REPO } else { (Resolve-Path (Join-Path $scriptDir '..')).Path }
$H = if ($env:HIMALAYA_BIN) { $env:HIMALAYA_BIN } else { 'himalaya' }
$howto = Join-Path $repo 'docs\naver-works-app-password.md'

function Say([string]$m) { [Console]::Error.WriteLine($m) }
function Fail([string]$m, [string]$fix = '', [int]$code = 1) {
    Say "[실패] $m"
    if ($fix) { Say "  -> $fix" }
    exit $code
}
function Show-Usage {
    $lines = Get-Content -LiteralPath $PSCommandPath -Encoding UTF8
    foreach ($l in $lines) {
        if ($l -notmatch '^#') { break }
        if ($l -match '^# 화면 출력') { break }
        [Console]::Out.WriteLine(($l -replace '^# ?', ''))
    }
}
# 네이티브 명령 실행. PS 5.1 은 EAP=Stop 에서 stderr 한 줄만 나와도 예외로 승격하므로
# 이 함수 안에서만 Continue 로 낮추고, 종료 코드는 $LASTEXITCODE 로 직접 본다.
# PS 5.1 은 네이티브 stderr 를 2>파일 로 받든 2>&1 로 받든 각 줄을 ErrorRecord 로 렌더해
# "himalaya.exe : Error:" + 위치/CategoryInfo(RemoteException)/NativeCommandError 노이즈를
# 원문 앞에 붙인다(Windows PS 5.1 실측 — 앞선 2>파일 수정으로는 이 노이즈가 안 걷혔다). 2>&1 로
# 합친 뒤 ErrorRecord 는 .Exception.Message(=stderr 원문)로, 나머지(=stdout)는 그대로 분리하면
# 공백 포함 인자(@argv)를 재조립 없이 안전하게 넘기면서도 둘 다 깨끗한 원문으로 얻는다.
function Invoke-Native([string]$exe, [string[]]$argv) {
    $ErrorActionPreference = 'Continue'
    $merged = & $exe @argv 2>&1
    $code = $LASTEXITCODE
    $out = @(); $err = @()
    foreach ($line in $merged) {
        if ($line -is [System.Management.Automation.ErrorRecord]) { $err += [string]$line.Exception.Message }
        else { $out += [string]$line }
    }
    $parts = @()
    if ($out.Count) { $parts += ($out -join "`n") }
    if ($err.Count) { $parts += ($err -join "`n") }
    return [pscustomobject]@{ Code = $code; Text = ($parts -join "`n") }
}
function Write-Utf8NoBom([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
# scripts\hjson.py 실행(버전 가드·로그인 판정, #30). mailskill.ps1 의 Get-PythonCmd 와 같은 우선순위:
# uv 관리 Python 3.12 → python3 → python. 없으면 $null. stdout 은 반환, stderr(안내 두 줄)는 그대로 흘린다.
function Get-SetupPython {
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        $ErrorActionPreference = 'Continue'
        $null = & uv python find 3.12 2>$null
        if ($LASTEXITCODE -eq 0) { return , @('uv', 'run', '--no-project', '-q', '--no-python-downloads', '--python', '3.12') }
    }
    foreach ($p in @('python3', 'python')) { if (Get-Command $p -ErrorAction SilentlyContinue) { return , @($p) } }
    return $null
}
function Invoke-Hjson([string[]]$argv) {
    # EAP=Stop 이면 PS 5.1 이 python 의 stderr(안내 두 줄)를 종료 에러로 승격할 수 있다 → 이 함수 안에서만 Continue.
    $ErrorActionPreference = 'Continue'
    $py = Get-SetupPython
    $exe = $py[0]; $pre = @(); if ($py.Count -gt 1) { $pre = $py[1..($py.Count - 1)] }
    $env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
    $prev = $null
    try { $prev = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { $prev = $null }
    try { $out = & $exe @pre (Join-Path $repo 'scripts\hjson.py') @argv; $code = $LASTEXITCODE }
    finally { if ($null -ne $prev) { try { [Console]::OutputEncoding = $prev } catch {} } }
    return [pscustomobject]@{ Code = $code; Out = (@($out) -join "`n") }
}

# ── 인자 ───────────────────────────────────────────────────────────────────
$acct = 'ji'; $email = ''; $login = ''; $dname = ''; $pwStdin = $false; $verify = $true
$i = 0
while ($i -lt $args.Count) {
    $a = [string]$args[$i]
    $v = if ($i + 1 -lt $args.Count) { [string]$args[$i + 1] } else { $null }
    switch ($a) {
        { $_ -in @('-h', '--help') } { Show-Usage; exit 0 }
        '--email'          { if ($null -eq $v) { Fail '--email 값이 없습니다' '' 2 }; $email = $v; $i += 2; continue }
        '--login'          { if ($null -eq $v) { Fail '--login 값이 없습니다' '' 2 }; $login = $v; $i += 2; continue }
        '--display-name'   { if ($null -eq $v) { Fail '--display-name 값이 없습니다' '' 2 }; $dname = $v; $i += 2; continue }
        '--account'        { if ($null -eq $v) { Fail '--account 값이 없습니다' '' 2 }; $acct = $v; $i += 2; continue }
        '--password-stdin' { $pwStdin = $true; $i += 1; continue }
        '--no-verify'      { $verify = $false; $i += 1; continue }
        default            { Say "mailskill setup: 알 수 없는 옵션 '$a'"; Show-Usage; exit 2 }
    }
}
if ($acct -cnotmatch '^[a-z0-9][a-z0-9-]*$') { Fail "계정 이름은 영문 소문자·숫자·- 만: '$acct'" '' 2 }

# ── 0) 런타임 탐지(설치는 하지 않음) ─────────────────────────────────────────
$missing = @($H, 'age', 'age-keygen') | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
if (-not (Get-SetupPython)) { $missing = @($missing) + 'python' }
if ($missing) {
    Fail "필요한 프로그램이 없습니다: $($missing -join ', ')" 'jaix setup 이 설치합니다. jaix setup 을 먼저 실행한 뒤 다시 하세요.'
}
# 버전 가드: himalaya 2.2.x 만(설정 형식이 1.x 와 다르고, 2.3 이후엔 BREAKING 예정). 안내문은 hjson.py 가 stderr 로 낸다.
$env:NO_COLOR = '1'; $env:RUST_LOG = 'off'
$v = Invoke-Hjson @('version')
if ($v.Code -ne 0) {
    # 원인 문구("지원하지 않는 himalaya 버전 ...")는 hjson.py 가 stderr 로 이미 냈다. 여기선 종료만.
    exit 1
}
# 비밀번호는 사람이 직접 연 창에서 넣는다. 에이전트 도구처럼 입력이 리다이렉트된 곳에서는
# 숨김 입력이 불가능하므로 시작 전에 멈춘다(--password-stdin 은 자동화·테스트용).
if (-not $pwStdin -and [Console]::IsInputRedirected) {
    Fail '이 명령은 직접 연 PowerShell 창에서 실행해야 합니다(비밀번호를 숨김 입력으로 받기 때문).' "PowerShell 창을 열고 'mailskill setup' 을 입력하세요." 2
}
if ($pwStdin -and -not $email) { Fail '--password-stdin 을 쓰면 --email 도 함께 주어야 합니다.' '' 2 }

# ── 경로(리졸버 mail-secret / secret-set 과 같은 규칙) ───────────────────────
$key = if ($env:MAIL_SKILL_AGE_KEY) { $env:MAIL_SKILL_AGE_KEY } else { Join-Path $env:USERPROFILE '.config\mail-skill\age-key.txt' }
$repoMode = $false
if ($env:MAIL_SKILL_SECRETS) { $secrets = $env:MAIL_SKILL_SECRETS }
elseif (Test-Path -LiteralPath (Join-Path $repo 'secrets\recipients.txt')) { $secrets = Join-Path $repo 'secrets\secrets.age'; $repoMode = $true }
else { $secrets = Join-Path $env:USERPROFILE '.config\mail-skill\secrets.age' }
$recip = Join-Path (Split-Path -Parent $secrets) 'recipients.txt'
$conf = if ($env:HIMALAYA_CONFIG) { $env:HIMALAYA_CONFIG } else { Join-Path $env:USERPROFILE '.config\himalaya\config.toml' }
$tpl = Join-Path $repo 'config\works.template.toml'
if (-not (Test-Path -LiteralPath $tpl)) { Fail "템플릿이 없습니다: $tpl" 'mail-skill 을 다시 설치하세요(jaix setup).' }

# ── 1) 이메일·로그인 ─────────────────────────────────────────────────────────
if (-not $email) { $email = Read-Host '회사 메일 주소' }
$email = ($email -replace '\s', '')
if ($email -notmatch '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {
    Fail "메일 주소 형식이 아닙니다: '$email'" '예: hong@example.com 처럼 전체 주소를 넣으세요.' 2
}
if (-not $login) { $login = $email }
if ($login -notmatch '^[A-Za-z0-9._%+@-]+$') { Fail "로그인 아이디에 쓸 수 없는 문자가 있습니다: '$login'" '' 2 }
if (-not $dname) { $dname = $email }
$dname = $dname.Replace('"', '').Replace('\', '')   # TOML 문자열을 깨는 문자 제거

# ── 2) age 키 + recipients ──────────────────────────────────────────────────
foreach ($d in @((Split-Path -Parent $key), (Split-Path -Parent $secrets))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$newKey = $false
if (-not (Test-Path -LiteralPath $key)) {
    $r = Invoke-Native 'age-keygen' @('-o', $key)
    if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $key)) { Fail "age 키를 만들지 못했습니다: $key" '폴더 쓰기 권한을 확인하세요.' }
    $newKey = $true; Say "[완료] 이 PC 전용 암호화 키를 만들었습니다: $key"
}
$r = Invoke-Native 'age-keygen' @('-y', $key)
$pub = ($r.Text -split "`n" | Where-Object { $_ -match '^age1' } | Select-Object -First 1)
if ($r.Code -ne 0 -or -not $pub) { Fail "age 키를 읽지 못했습니다: $key" '파일이 손상됐다면 지우고 다시 실행하세요.' }
$pub = $pub.Trim()

function Test-Recipient { (Test-Path -LiteralPath $recip) -and (@(Get-Content -LiteralPath $recip | ForEach-Object { $_.Trim() }) -contains $pub) }
if ($repoMode) {
    # 개발용 저장소 모드: recipients 는 여러 기계가 공유하므로 건드리지 않는다.
    if (-not (Test-Recipient)) { Fail "이 기계 공개키가 $recip 에 없습니다." '등록된 기계에서 공개키를 추가·재암호화(secret-edit)한 뒤 다시 실행하세요.' }
}
else {
    # 1인 1기계: 이 기계 키로 열 수 없는 기존 secrets.age 는 쓸모가 없다 -> 치워 두고 새로 시작.
    if (Test-Path -LiteralPath $secrets) {
        $canOpen = $false
        if (-not $newKey) { $canOpen = ((Invoke-Native 'age' @('-d', '-i', $key, '-o', 'NUL', $secrets)).Code -eq 0) }
        if (-not $canOpen) {
            $bak = "$secrets.bak-$(Get-Date -Format yyyyMMddHHmmss)"
            Move-Item -LiteralPath $secrets -Destination $bak
            Say "[안내] 이 키로 열 수 없는 기존 비밀 파일을 옮겨 두었습니다: $bak"
        }
    }
    # 비밀 파일이 아직 없으면(처음 설정) recipient 는 이 기계 하나뿐이다.
    if (-not (Test-Path -LiteralPath $secrets)) { Write-Utf8NoBom $recip "$pub`n" }
    elseif (-not (Test-Recipient)) { [System.IO.File]::AppendAllText($recip, "$pub`n", (New-Object System.Text.UTF8Encoding($false))) }
}

# ── 3) 앱 비밀번호(숨김 입력) -> age 암호화 저장 ────────────────────────────
if ($pwStdin) {
    $plain = [Console]::In.ReadLine()
}
else {
    . (Join-Path $scriptDir 'read-masked.ps1')
    $sec = Read-MaskedSecure 'NAVER WORKS 앱 비밀번호(글자마다 * 로 표시됩니다)'
    $plain = (New-Object System.Net.NetworkCredential('', $sec)).Password
}
if ($null -eq $plain) { $plain = '' }
$plain = $plain.Trim()
if (-not $plain) { Fail '비밀번호가 비어 있습니다.' "발급 방법: $howto" 2 }
$secure = ConvertTo-SecureString $plain -AsPlainText -Force
$plain = $null

$env:MAIL_SKILL_AGE_KEY = $key
$env:MAIL_SKILL_SECRETS = $secrets
$secretSet = Join-Path $repo 'scripts\secret-set.ps1'
foreach ($kind in @('imap', 'smtp')) {
    $name = "himalaya-$acct-$kind"
    try { & $secretSet -Name $name -SecureValue $secure; $rc = $LASTEXITCODE }
    catch { Say "  $($_.Exception.Message)"; $rc = 1 }
    if ($rc -ne 0) { Fail "비밀번호 저장에 실패했습니다($name)." 'age 가 동작하는지 확인하고 다시 실행하세요.' }
}
$secure.Dispose()
Say "[완료] 앱 비밀번호를 암호화해 저장했습니다: $secrets"

# ── 4) 이 PC 전용 himalaya 설정 ─────────────────────────────────────────────
function Get-Rendered {
    $t = [System.IO.File]::ReadAllText($tpl, [System.Text.Encoding]::UTF8)
    $t = $t.Replace('__ACCOUNT__', $acct).Replace('__EMAIL__', $email).Replace('__LOGIN__', $login).Replace('__DISPLAY_NAME__', $dname)
    $t = $t.Replace("`r`n", "`n")
    # 템플릿 머리 주석은 버리고(자리표시 설명이라) 이 파일의 출처만 한 줄 남긴다.
    $t = $t.Substring($t.IndexOf('[accounts.'))
    return "# mailskill setup 이 만든 이 PC 전용 설정($(Get-Date -Format yyyy-MM-dd)) - 공유·커밋하지 마세요.`n" + $t
}
$confDir = Split-Path -Parent $conf
if (-not (Test-Path -LiteralPath $confDir)) { New-Item -ItemType Directory -Path $confDir -Force | Out-Null }
$hasAcct = { param($p) [regex]::IsMatch([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8), "(?m)^\[accounts\.$([regex]::Escape($acct))\]") }
# himalaya 1.x 형식(bash 판 is_v1 과 같은 규칙) — 2.x 는 이 키를 무시하고 실행 시 실패한다. 셋 중 하나라도 있으면 1.x:
#   ① 점 키 backend.(type|host|port|login|auth|encryption) (앞에 send.·message.send. 포함)
#   ② 표 머리 [accounts.X.backend]·[accounts.X.message.send.backend] (하위 표 .auth 등 포함)  ③ 인라인 표 backend = { … }
$isV1 = { param($p) [regex]::IsMatch([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8), '(?m)^[ \t]*((message\.)?send\.)?backend\.(type|host|port|login|auth|encryption)|^[ \t]*\[accounts\.[^\]]*\.backend(\.[^\]]*)?\]|^[ \t]*((message\.)?send\.)?backend[ \t]*=[ \t]*\{') }
$item = Get-Item -LiteralPath $conf -Force -ErrorAction SilentlyContinue
if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    # 링크는 대개 저장소의 공용 설정을 가리킨다. 남의 파일을 고치지 않는다.
    if ((Test-Path -LiteralPath $conf) -and (& $isV1 $conf)) {
        Fail "$conf 가 가리키는 설정이 himalaya 1.x 형식이라 2.x 에서 읽히지 않습니다(링크라 고치지 않았습니다)." "링크 대상 파일을 2.x 형식으로 옮기거나 링크를 지운 뒤 다시 실행하세요."
    }
    if ((Test-Path -LiteralPath $conf) -and (& $hasAcct $conf)) { Say "[완료] 기존 설정을 그대로 씁니다: $conf" }
    else { Fail "$conf 가 다른 파일을 가리키는 링크라 고치지 않았습니다." "그 파일에 [accounts.$acct] 블록을 직접 넣거나 링크를 지운 뒤 다시 실행하세요." }
}
elseif ($item -and (& $isV1 $conf)) {
    # 1.x 설정은 계정 블록 단위로 섞어 쓸 수 없다(파일 전체가 2.x 로 읽힌다) → 통째로 백업하고 새로 만든다.
    $bak = "$conf.bak-v1-$(Get-Date -Format yyyyMMddHHmmss)"
    Move-Item -LiteralPath $conf -Destination $bak
    Write-Utf8NoBom $conf (Get-Rendered)
    Say "[완료] 예전(himalaya 1.x) 설정을 옮겨 두고 새로 만들었습니다: $conf (예전 것: $bak)"
    # 최상위 [accounts.X] 만 계정으로 센다(점이 든 하위 표 [accounts.X.backend] 등은 계정이 아님).
    $others = @([regex]::Matches([System.IO.File]::ReadAllText($bak, [System.Text.Encoding]::UTF8), '(?m)^\[accounts\.[^\].]+\]') |
        ForEach-Object { $_.Value } | Where-Object { $_ -ne "[accounts.$acct]" })
    if ($others.Count) { Say "  그 파일의 다른 계정($($others -join ' '))은 옮기지 않았습니다 - 필요하면 2.x 형식으로 직접 옮기세요." }
}
elseif (-not $item) {
    Write-Utf8NoBom $conf (Get-Rendered)
    Say "[완료] 메일 설정을 만들었습니다: $conf"
}
elseif (& $hasAcct $conf) {
    Say "[완료] 기존 설정에 '$acct' 계정이 있어 그대로 씁니다: $conf"
}
else {
    Copy-Item -LiteralPath $conf -Destination "$conf.bak-$(Get-Date -Format yyyyMMddHHmmss)"
    $block = ((Get-Rendered) -split "`n" | Where-Object { $_ -ne 'default = true' }) -join "`n"
    [System.IO.File]::AppendAllText($conf, "`n$block", (New-Object System.Text.UTF8Encoding($false)))
    Say "[완료] 기존 설정 끝에 '$acct' 계정을 덧붙였습니다(백업 .bak-*): $conf"
}

# himalaya 2.x 는 %APPDATA%\himalaya\config.toml 을 ~\.config 보다 먼저 읽는다. 그 파일이 있으면 방금 만든
# 설정이 조용히 가려진다(Windows 에선 -c 절대경로를 못 써서 경로로 우회할 수도 없다, #30).
$appConf = if ($env:APPDATA) { Join-Path $env:APPDATA 'himalaya\config.toml' } else { $null }
if (-not $env:HIMALAYA_CONFIG -and $appConf -and (Test-Path -LiteralPath $appConf) -and ((Resolve-Path -LiteralPath $appConf).Path -ne (Resolve-Path -LiteralPath $conf).Path)) {
    Say "[주의] $appConf 가 있어서 메일 프로그램은 그 파일을 먼저 읽습니다. 방금 만든 $conf 는 쓰이지 않습니다."
    Say "  -> $appConf 를 다른 이름으로 바꾸거나 지운 뒤 'mailskill doctor $acct' 로 확인하세요."
}

# ── 5) 확인: password.command -> age 복호 -> IMAP/SMTP 로그인 ─────────────────
if (-not $verify) { Say "[안내] 로그인 확인은 건너뛰었습니다(--no-verify). 나중에: mailskill doctor $acct"; exit 0 }
if (-not (Get-Command 'mail-secret' -ErrorAction SilentlyContinue)) {
    Fail 'mail-secret 명령을 찾을 수 없어 메일 프로그램이 비밀번호를 못 읽습니다.' "jaix setup 을 다시 실행해 PATH 를 잡은 뒤 'mailskill doctor $acct' 로 확인하세요." 3
}
# 판정은 hjson.py check 가 한다(bash 판과 공통): 2.x account check 는 백엔드가 FAIL 이어도 exit 0 이라
# 출력으로 가려야 한다. stdout 첫 줄 ok|auth|secret|config|network + 백엔드별 보고, 실패면 exit 3 과
# stderr 에 "문장 / -> 고치는 법" 두 줄(문구 정본은 hjson.py).
$r = Invoke-Hjson @('check', '--account', $acct, '--doc', $howto)
$lines = @($r.Out -split "`n" | Where-Object { $_.Trim() })
$verdict = if ($lines.Count) { $lines[0].Trim() } else { '' }
foreach ($l in ($lines | Select-Object -Skip 1)) { Say "    $l" }
if ($r.Code -eq 0 -and $verdict -eq 'ok') {
    Say "[완료] 로그인 확인 완료. 이제 '$acct' 계정으로 메일을 읽고 보낼 수 있습니다."
    exit 0
}
if ($r.Code -eq 3) { exit 3 }   # 원인·고치는 법은 hjson.py 가 이미 stderr 로 냈다
Fail "로그인 확인을 끝내지 못했습니다(판정 도구 exit $($r.Code))." "'mailskill doctor $acct' 로 다시 확인하고, 계속되면 관리자에게 위 내용을 보내세요." 3
