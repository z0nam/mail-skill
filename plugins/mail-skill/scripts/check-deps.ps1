$ErrorActionPreference = 'Stop'
$missing = @()
foreach ($tool in @('himalaya', 'age', 'age-keygen')) {
    $command = Get-Command $tool -ErrorAction SilentlyContinue
    if ($command) { Write-Host "OK $tool`: $($command.Source)" }
    else { Write-Host "MISSING $tool"; $missing += $tool }
}
if ($missing.Count -gt 0) {
    Write-Host 'Install on Windows:'
    Write-Host '  scoop install himalaya age'
    Write-Host '  or: winget install --id FiloSottile.age; cargo install --locked --git https://github.com/pimalaya/himalaya.git'
    exit 1
}
Write-Host 'All dependencies are available.'
