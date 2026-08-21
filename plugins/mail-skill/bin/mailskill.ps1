[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('accounts', 'folders', 'list', 'search', 'read', 'reply', 'doctor')]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CommandArgs
)

$ErrorActionPreference = 'Stop'
$himalaya = if ($env:HIMALAYA_BIN) { $env:HIMALAYA_BIN } else { 'himalaya' }

function Invoke-Himalaya([string[]]$Arguments) {
    & $himalaya @Arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Require-Argument([int]$Index, [string]$Name) {
    if ($CommandArgs.Count -le $Index -or [string]::IsNullOrWhiteSpace($CommandArgs[$Index])) {
        throw "missing required argument: $Name"
    }
    $CommandArgs[$Index]
}

switch ($Command) {
    'accounts' { Invoke-Himalaya @('account', 'list', '-o', 'json') }
    'folders' {
        $account = Require-Argument 0 'account'
        Invoke-Himalaya @('folder', 'list', '-a', $account, '-o', 'json')
    }
    'list' {
        $account = Require-Argument 0 'account'
        $count = if ($CommandArgs.Count -gt 1) { $CommandArgs[1] } else { '20' }
        Invoke-Himalaya @('envelope', 'list', '-a', $account, '--page-size', $count, '-o', 'json')
    }
    'search' {
        $account = Require-Argument 0 'account'
        $query = if ($CommandArgs.Count -gt 1) { $CommandArgs[1..($CommandArgs.Count - 1)] } else { @() }
        Invoke-Himalaya (@('envelope', 'list', '-a', $account, '-o', 'json', '--') + $query)
    }
    'read' {
        $account = Require-Argument 0 'account'
        $id = Require-Argument 1 'id'
        $arguments = @('message', 'read', $id, '-a', $account)
        if ($CommandArgs.Count -gt 2) { $arguments += @('-f', $CommandArgs[2]) }
        Invoke-Himalaya ($arguments + @('-o', 'json'))
    }
    'reply' {
        if ($env:MAIL_SKILL_ALLOW_INTERACTIVE_REPLY -ne '1') {
            throw 'reply is interactive and may send mail. Set MAIL_SKILL_ALLOW_INTERACTIVE_REPLY=1 only after explicit user approval.'
        }
        $account = Require-Argument 0 'account'
        $id = Require-Argument 1 'id'
        Invoke-Himalaya @('message', 'reply', $id, '-a', $account)
    }
    'doctor' {
        $account = Require-Argument 0 'account'
        Invoke-Himalaya @('account', 'doctor', $account)
    }
}
