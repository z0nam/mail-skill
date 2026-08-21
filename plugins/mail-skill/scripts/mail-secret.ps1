[CmdletBinding()]
param([Parameter(Mandatory = $true, Position = 0)][string]$Name)

$ErrorActionPreference = 'Stop'
$configDir = if ($env:MAIL_SKILL_CONFIG_DIR) { $env:MAIL_SKILL_CONFIG_DIR } else { Join-Path $HOME '.config/mail-skill' }
$key = if ($env:MAIL_SKILL_AGE_KEY) { $env:MAIL_SKILL_AGE_KEY } else { Join-Path $configDir 'age-key.txt' }
$secrets = if ($env:MAIL_SKILL_SECRETS) { $env:MAIL_SKILL_SECRETS } else { Join-Path $configDir 'secrets.age' }

if (-not (Test-Path -LiteralPath $key -PathType Leaf)) { throw "age key not found: $key" }
if (-not (Test-Path -LiteralPath $secrets -PathType Leaf)) { throw "secrets file not found: $secrets" }

$plain = (& age --decrypt --identity $key $secrets 2>$null) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'failed to decrypt mail secrets' }
$prefix = "$Name="
$line = $plain -split "`r?`n" | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } | Select-Object -First 1
if ($null -eq $line) { throw "secret not found: $Name" }
[Console]::Out.Write($line.Substring($prefix.Length))
