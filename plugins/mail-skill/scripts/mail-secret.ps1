# mail-secret (Windows / PowerShell) — Himalaya 의 auth.cmd 가 호출하는 시크릿 리졸버.
# age 암호화 파일(secrets/secrets.age)에서 <name> 의 값을 꺼내 stdout 으로 출력(개행 없음).
# bash 판 scripts/mail-secret 과 동일 계약: 같은 env 오버라이드, 같은 exit code.
#   1 = 키/secrets 파일 없음,  3 = 시크릿 없음(또는 복호화 실패)
[CmdletBinding()]
param([Parameter(Mandatory = $true, Position = 0)][string]$Name)
$ErrorActionPreference = 'Stop'
# PS 7.4+ 의 네이티브 종료코드→예외 승격을 끈다(age 의 exit code 를 직접 본다). PS 5.1 엔 무해.
$PSNativeCommandUseErrorActionPreference = $false

# 이 스크립트의 실제 위치(심링크/복사 모두) → REPO 추정.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = if ($env:MAIL_SKILL_REPO) { $env:MAIL_SKILL_REPO }
        else { (Resolve-Path (Join-Path $scriptDir '..')).Path }
$key  = if ($env:MAIL_SKILL_AGE_KEY) { $env:MAIL_SKILL_AGE_KEY }
        else { Join-Path $env:USERPROFILE '.config\mail-skill\age-key.txt' }
$secrets = if ($env:MAIL_SKILL_SECRETS) { $env:MAIL_SKILL_SECRETS }
           elseif (Test-Path (Join-Path $repo 'secrets\secrets.age')) { Join-Path $repo 'secrets\secrets.age' }
           else { Join-Path $env:USERPROFILE '.config\mail-skill\secrets.age' }

if (-not (Test-Path -LiteralPath $key)) {
    [Console]::Error.WriteLine("mail-secret: age 키 없음: $key (bootstrap.ps1 실행)"); exit 1
}
if (-not (Test-Path -LiteralPath $secrets)) {
    [Console]::Error.WriteLine("mail-secret: secrets 없음: $secrets"); exit 1
}

# age 로 복호화. stderr 는 삼키고 stdout(평문 name=value 줄들)만 받는다.
$plain = & age -d -i $key $secrets 2>$null
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("mail-secret: 복호화 실패 (age exit $LASTEXITCODE)"); exit 3
}

# bash awk 와 동일: 줄이 "<name>=" 로 시작하면 그 뒤 전체를 값으로. 개행 없이 출력.
$prefix = "$Name="
foreach ($line in @($plain)) {
    if ($line.StartsWith($prefix)) {
        [Console]::Out.Write($line.Substring($prefix.Length))
        exit 0
    }
}
[Console]::Error.WriteLine("mail-secret: 시크릿 '$Name' 없음(또는 복호화 실패)")
exit 3
