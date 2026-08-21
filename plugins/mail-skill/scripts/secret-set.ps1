[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Name,
    [switch]$FromStdin
)

$ErrorActionPreference = 'Stop'
$configDir = if ($env:MAIL_SKILL_CONFIG_DIR) { $env:MAIL_SKILL_CONFIG_DIR } else { Join-Path $HOME '.config/mail-skill' }
$key = if ($env:MAIL_SKILL_AGE_KEY) { $env:MAIL_SKILL_AGE_KEY } else { Join-Path $configDir 'age-key.txt' }
$secrets = if ($env:MAIL_SKILL_SECRETS) { $env:MAIL_SKILL_SECRETS } else { Join-Path $configDir 'secrets.age' }
$recipients = Join-Path (Split-Path -Parent $secrets) 'recipients.txt'

if (-not (Test-Path -LiteralPath $key -PathType Leaf)) { throw "age key not found: $key" }
if (-not (Test-Path -LiteralPath $recipients -PathType Leaf)) { throw "recipients file not found: $recipients" }

$value = if ($FromStdin) {
    [Console]::In.ReadLine()
} else {
    $secure = Read-Host "value for $Name" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
if ([string]::IsNullOrEmpty($value)) { throw 'empty secret is not allowed' }

$plainPath = [IO.Path]::GetTempFileName()
$encryptedPath = Join-Path ([IO.Path]::GetTempPath()) ('mail-skill-' + [guid]::NewGuid().ToString('N') + '.age')
try {
    $lines = @()
    if (Test-Path -LiteralPath $secrets -PathType Leaf) {
        $lines = @(& age --decrypt --identity $key $secrets)
        if ($LASTEXITCODE -ne 0) { throw 'failed to decrypt existing secrets' }
    }
    $prefix = "$Name="
    $updated = @($lines | Where-Object { -not $_.StartsWith($prefix, [StringComparison]::Ordinal) }) + "$Name=$value"
    [IO.File]::WriteAllLines($plainPath, $updated, [Text.UTF8Encoding]::new($false))
    & age --recipients-file $recipients --output $encryptedPath $plainPath
    if ($LASTEXITCODE -ne 0) { throw 'failed to encrypt mail secrets' }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $secrets) | Out-Null
    Move-Item -Force -LiteralPath $encryptedPath -Destination $secrets
    Write-Host "set '$Name'"
} finally {
    $value = $null
    if (Test-Path -LiteralPath $plainPath) { Remove-Item -Force -LiteralPath $plainPath }
    if (Test-Path -LiteralPath $encryptedPath) { Remove-Item -Force -LiteralPath $encryptedPath }
}
