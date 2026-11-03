# mailskill setup (Windows / PowerShell) — 회사메일(NAVER WORKS) 1회 설정. bash 판 scripts/mail-setup 과 같은 계약.
#   1) age 키 보장(없으면 생성) + recipients.txt 에 이 기계 공개키
#   2) 앱 비밀번호를 숨김 입력(SecureString) -> secret-set 으로 himalaya-<acct>-imap / -smtp 두 이름에 저장
#   3) 템플릿(config\works.template.toml)으로 이 PC 전용 himalaya config 생성
#   4) himalaya account doctor 로 auth.cmd -> age 복호 -> IMAP/SMTP 로그인 확인
#
#   mailskill setup [--email <주소>] [--login <아이디>] [--display-name <이름>]
#                   [--account <이름>] [--password-stdin] [--no-verify]
#
# 비밀번호는 인자로 받지 않는다. 화면·로그·평문 파일에 남기지 않는다(age 암호화 저장만).
# 런타임(himalaya·age)은 설치하지 않는다. 없으면 무엇이 없는지만 알린다(TS-RUNTIME-2).
# exit: 0 완료 · 1 환경 문제(런타임·키·설정) · 2 사용법 · 3 저장은 됐으나 로그인 확인 실패
#
# 화면 출력은 cp949 콘솔에서도 깨지지 않는 글자만 쓴다(TS-WIN-3: ✓ ✗ — 같은 기호 금지).
# himalaya 출력은 영문 키워드로만 판정한다(인코딩과 무관하게).
$ErrorActionPreference = 'Stop'
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
function Invoke-Native([string]$exe, [string[]]$argv) {
    $ErrorActionPreference = 'Continue'
    $out = & $exe @argv 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n") }
}
function Write-Utf8NoBom([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
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
if ($missing) {
    Fail "필요한 프로그램이 없습니다: $($missing -join ', ')" 'jaix setup 이 설치합니다. jaix setup 을 먼저 실행한 뒤 다시 하세요.'
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
$item = Get-Item -LiteralPath $conf -Force -ErrorAction SilentlyContinue
if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    # 링크는 대개 저장소의 공용 설정을 가리킨다. 남의 파일을 고치지 않는다.
    if ((Test-Path -LiteralPath $conf) -and (& $hasAcct $conf)) { Say "[완료] 기존 설정을 그대로 씁니다: $conf" }
    else { Fail "$conf 가 다른 파일을 가리키는 링크라 고치지 않았습니다." "그 파일에 [accounts.$acct] 블록을 직접 넣거나 링크를 지운 뒤 다시 실행하세요." }
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

# ── 5) 확인: auth.cmd -> age 복호 -> IMAP/SMTP 로그인 ───────────────────────
if (-not $verify) { Say "[안내] 로그인 확인은 건너뛰었습니다(--no-verify). 나중에: mailskill doctor $acct"; exit 0 }
if (-not (Get-Command 'mail-secret' -ErrorAction SilentlyContinue)) {
    Fail 'mail-secret 명령을 찾을 수 없어 메일 프로그램이 비밀번호를 못 읽습니다.' "jaix setup 을 다시 실행해 PATH 를 잡은 뒤 'mailskill doctor $acct' 로 확인하세요." 3
}
$env:NO_COLOR = '1'; $env:RUST_LOG = 'off'
$r = Invoke-Native $H @('account', 'doctor', $acct)
if ($r.Code -eq 0) {
    Say "[완료] 로그인 확인 완료. 이제 '$acct' 계정으로 메일을 읽고 보낼 수 있습니다."
    exit 0
}
$tail = @($r.Text -split "`n" | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' } | Where-Object { $_.Trim() -and $_ -notmatch '^\s*Note' }) | Select-Object -Last 4
foreach ($l in $tail) { Say "    $l" }
if ($r.Text -match '(?i)authentication failed') {
    Fail '로그인 실패: 아이디 또는 앱 비밀번호가 틀렸습니다.' "앱 비밀번호를 새로 발급해 'mailskill setup' 을 다시 실행하세요($howto)." 3
}
elseif ($r.Text -match '(?i)mail-secret|cannot (run|execute)|not recognized|password') {
    Fail '메일 프로그램이 저장된 비밀번호를 읽지 못했습니다.' "'mailskill doctor $acct' 로 다시 확인하고, 계속되면 관리자에게 위 내용을 보내세요." 3
}
else {
    Fail '메일 서버에 접속하지 못했습니다(네트워크 또는 IMAP/SMTP 사용 허용 여부).' '회사망·인터넷 연결을 확인하고, 계속되면 웍스 관리자에게 IMAP/SMTP 허용을 요청하세요.' 3
}
