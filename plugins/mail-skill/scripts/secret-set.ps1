# secret-set (Windows / PowerShell) — 시크릿 1개 추가/갱신 후 recipients.txt 전원 공개키로 재암호화.
# bash 판 scripts/secret-set 과 동일. 값은 인자로 받지 않는다(히스토리/노출 방지).
#   secret-set <name>           # 숨김 프롬프트로 입력
#   secret-set <name> --stdin   # stdin 에서 값 1줄 읽음 (파이프용)
#   & secret-set.ps1 -Name <name> -SecureValue <SecureString>   # 같은 프로세스에서(mail-setup.ps1)
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Name,
    [Parameter(Position = 1)][string]$Mode = 'prompt',
    [System.Security.SecureString]$SecureValue
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = if ($env:MAIL_SKILL_REPO) { $env:MAIL_SKILL_REPO }
        else { (Resolve-Path (Join-Path $scriptDir '..')).Path }
$key  = if ($env:MAIL_SKILL_AGE_KEY) { $env:MAIL_SKILL_AGE_KEY }
        else { Join-Path $env:USERPROFILE '.config\mail-skill\age-key.txt' }
$secrets = if ($env:MAIL_SKILL_SECRETS) { $env:MAIL_SKILL_SECRETS }
           elseif (Test-Path (Join-Path $repo 'secrets\recipients.txt')) { Join-Path $repo 'secrets\secrets.age' }
           else { Join-Path $env:USERPROFILE '.config\mail-skill\secrets.age' }
$recip = Join-Path (Split-Path -Parent $secrets) 'recipients.txt'

if (-not (Test-Path -LiteralPath $recip) -or ((Get-Item -LiteralPath $recip).Length -eq 0)) {
    [Console]::Error.WriteLine('recipients.txt 비어있음 — 공개키 등록 먼저(bootstrap.ps1)'); exit 1
}

# 값 입력: -SecureValue 가 오면 그것, --stdin 이면 한 줄, 아니면 숨김 프롬프트.
# -SecureValue 는 평문을 파이프·인자로 넘기지 않으려고 둔다(호출측이 같은 프로세스).
if ($SecureValue) {
    $val = (New-Object System.Net.NetworkCredential('', $SecureValue)).Password
}
elseif ($Mode -eq '--stdin') {
    $val = [Console]::In.ReadLine()
}
else {
    . (Join-Path $scriptDir 'read-masked.ps1')
    $sec = Read-MaskedSecure "value for ${Name}"
    $val = (New-Object System.Net.NetworkCredential('', $sec)).Password
}
if (-not $val) { [Console]::Error.WriteLine('빈 값 거부'); exit 1 }

# 기존 복호화 → 같은 name 줄 제거 → 새 줄 추가 → recipients 전원 공개키로 재암호화.
$lines = @()
if (Test-Path -LiteralPath $secrets) {
    $plain = & age -d -i $key $secrets
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('기존 secrets 복호화 실패'); exit 1 }
    $lines = @($plain) | Where-Object { -not $_.StartsWith("$Name=") }
}
$lines = @($lines) + "$Name=$val"

$tmp = [System.IO.Path]::GetTempFileName()
try {
    # LF 로, BOM 없이 쓴다(mail-secret 의 접두 파싱과 일관 · age 는 바이트 보존).
    $content = (@($lines) -join "`n") + "`n"
    [System.IO.File]::WriteAllText($tmp, $content, (New-Object System.Text.UTF8Encoding($false)))
    & age -R $recip -o $secrets $tmp
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('재암호화 실패'); exit 1 }
    $count = (@(Get-Content -LiteralPath $recip | Where-Object { $_ -notmatch '^#' -and $_.Trim() })).Count
    [Console]::Error.WriteLine("set '$Name' -> recipient ${count}개")
}
finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
