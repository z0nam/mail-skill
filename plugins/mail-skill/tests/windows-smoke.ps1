$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path -Parent $PSScriptRoot
$adapter = Join-Path $pluginRoot 'bin/mailskill.ps1'
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('mail-skill-test-' + [guid]::NewGuid().ToString('N'))
$fake = Join-Path $tempDir 'fake-himalaya.ps1'
$capture = Join-Path $tempDir 'arguments.json'
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    @'
$args | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:MAIL_SKILL_TEST_CAPTURE -Encoding utf8
'@ | Set-Content -LiteralPath $fake -Encoding utf8
    $env:HIMALAYA_BIN = $fake
    $env:MAIL_SKILL_TEST_CAPTURE = $capture

    & $adapter accounts
    $actual = @(Get-Content -Raw -LiteralPath $capture | ConvertFrom-Json)
    $expected = @('account', 'list', '-o', 'json')
    if ((Compare-Object $expected $actual -SyncWindow 0)) { throw 'accounts arguments differ' }

    & $adapter search work 'subject' 'quarterly report'
    $actual = @(Get-Content -Raw -LiteralPath $capture | ConvertFrom-Json)
    $expected = @('envelope', 'list', '-a', 'work', '-o', 'json', '--', 'subject', 'quarterly report')
    if ((Compare-Object $expected $actual -SyncWindow 0)) { throw 'search arguments differ' }

    Remove-Item -LiteralPath $capture
    $env:MAIL_SKILL_ALLOW_INTERACTIVE_REPLY = $null
    try { & $adapter reply work 42; throw 'reply should have been blocked' }
    catch {
        if ($_.Exception.Message -notlike '*explicit user approval*') { throw }
    }
    if (Test-Path -LiteralPath $capture) { throw 'blocked reply invoked himalaya' }

    $env:MAIL_SKILL_ALLOW_INTERACTIVE_REPLY = '1'
    & $adapter reply work 42
    $actual = @(Get-Content -Raw -LiteralPath $capture | ConvertFrom-Json)
    $expected = @('message', 'reply', '42', '-a', 'work')
    if ((Compare-Object $expected $actual -SyncWindow 0)) { throw 'approved reply arguments differ' }

    @'
$Arguments = $args
if ($Arguments[0] -in @('--decrypt', '-d')) {
    Get-Content -LiteralPath $Arguments[-1]
    $global:LASTEXITCODE = 0
    return
}
$outputIndex = [Array]::IndexOf($Arguments, '--output')
if ($outputIndex -lt 0) { $outputIndex = [Array]::IndexOf($Arguments, '-o') }
Copy-Item -LiteralPath $Arguments[-1] -Destination $Arguments[$outputIndex + 1] -Force
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath (Join-Path $tempDir 'age.ps1') -Encoding utf8
    @'
$Arguments = $args
if ($Arguments[0] -eq '-o') { Set-Content -LiteralPath $Arguments[1] -Value 'AGE-SECRET-KEY-TEST' }
elseif ($Arguments[0] -eq '-y') { Write-Output 'age1testrecipient' }
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath (Join-Path $tempDir 'age-keygen.ps1') -Encoding utf8
    Copy-Item -LiteralPath $fake -Destination (Join-Path $tempDir 'himalaya.ps1')

    $originalPath = $env:Path
    $env:Path = "$tempDir;$env:Path"
    $env:MAIL_SKILL_CONFIG_DIR = Join-Path $tempDir 'config/mail-skill'
    $env:MAIL_SKILL_HIMALAYA_CONFIG_DIR = Join-Path $tempDir 'config/himalaya'
    & (Join-Path $pluginRoot 'scripts/bootstrap.ps1')
    $configDir = $env:MAIL_SKILL_CONFIG_DIR
    if (-not (Test-Path -LiteralPath (Join-Path $configDir 'bin/mailskill.cmd'))) { throw 'bootstrap did not create launcher' }
    'test-value' | pwsh -NoProfile -File (Join-Path $pluginRoot 'scripts/secret-set.ps1') test-account -FromStdin
    if ($LASTEXITCODE -ne 0) { throw 'secret-set subprocess failed' }
    $secret = pwsh -NoProfile -File (Join-Path $pluginRoot 'scripts/mail-secret.ps1') test-account
    if ($LASTEXITCODE -ne 0) { throw 'mail-secret subprocess failed' }
    if ($secret -ne 'test-value') { throw 'secret round trip failed' }

    Write-Host 'Windows smoke tests passed.'
} finally {
    $env:HIMALAYA_BIN = $null
    $env:MAIL_SKILL_TEST_CAPTURE = $null
    $env:MAIL_SKILL_ALLOW_INTERACTIVE_REPLY = $null
    if ($originalPath) { $env:Path = $originalPath }
    $env:MAIL_SKILL_CONFIG_DIR = $null
    $env:MAIL_SKILL_HIMALAYA_CONFIG_DIR = $null
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}
