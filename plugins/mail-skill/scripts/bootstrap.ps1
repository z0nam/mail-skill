[CmdletBinding()]
param([switch]$AddToUserPath)

$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'check-deps.ps1')

$configDir = if ($env:MAIL_SKILL_CONFIG_DIR) { $env:MAIL_SKILL_CONFIG_DIR } else { Join-Path $HOME '.config/mail-skill' }
$himalayaDir = if ($env:MAIL_SKILL_HIMALAYA_CONFIG_DIR) { $env:MAIL_SKILL_HIMALAYA_CONFIG_DIR } else { Join-Path $HOME '.config/himalaya' }
$binDir = Join-Path $configDir 'bin'
New-Item -ItemType Directory -Force -Path $configDir, $himalayaDir, $binDir | Out-Null

$key = Join-Path $configDir 'age-key.txt'
$recipients = Join-Path $configDir 'recipients.txt'
if (-not (Test-Path -LiteralPath $key -PathType Leaf)) { & age-keygen -o $key }
$publicKey = (& age-keygen -y $key).Trim()
$existingRecipients = if (Test-Path -LiteralPath $recipients) { @(Get-Content -LiteralPath $recipients) } else { @() }
if ($publicKey -notin $existingRecipients) { Add-Content -LiteralPath $recipients -Value $publicKey -Encoding utf8 }

$config = Join-Path $himalayaDir 'config.toml'
if (-not (Test-Path -LiteralPath $config)) {
    Copy-Item -LiteralPath (Join-Path $pluginRoot 'config/config.sample.toml') -Destination $config
}

$mailskillPs1 = Join-Path $pluginRoot 'bin/mailskill.ps1'
$mailSecretPs1 = Join-Path $pluginRoot 'scripts/mail-secret.ps1'
$secretSetPs1 = Join-Path $pluginRoot 'scripts/secret-set.ps1'
$launchers = @{
    'mailskill.cmd' = "@pwsh -NoProfile -File `"$mailskillPs1`" %*"
    'mail-secret.cmd' = "@pwsh -NoProfile -File `"$mailSecretPs1`" %*"
    'mail-secret-set.cmd' = "@pwsh -NoProfile -File `"$secretSetPs1`" %*"
}
foreach ($item in $launchers.GetEnumerator()) {
    [IO.File]::WriteAllText((Join-Path $binDir $item.Key), $item.Value + "`r`n", [Text.ASCIIEncoding]::new())
}

if ($AddToUserPath) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { $_ })
    if ($binDir -notin $parts) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $binDir) -join ';'), 'User')
    }
}
Write-Host "Setup complete. CLI directory: $binDir"
Write-Host "Age public key: $publicKey"
if (-not $AddToUserPath) { Write-Host "Run again with -AddToUserPath to persist the CLI directory in your user PATH." }
Write-Host "Edit account settings: $config"
