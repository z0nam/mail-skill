# read-masked.ps1 — 비밀번호를 글자마다 '*' 로 보여주며 SecureString 으로 받는다(dot-source 해서 쓴다).
#   $sec = Read-MaskedSecure '<프롬프트>'   → 화면에는 '*' 와 길이("받음 N자")만 나간다.
# Read-Host -AsSecureString 은 아무것도 안 찍어서 입력이 들어갔는지 알 수 없다는 피드백이 있었다.
# 값은 SecureString 에만 쌓고 평문 문자열로 만들지 않는다. 입력이 리다이렉트돼 ReadKey 를 못 쓰면
# 기존 Read-Host -AsSecureString 으로 돌아간다(별표는 없지만 동작은 같다).
function Read-MaskedSecure([string]$Prompt) {
    if ([Console]::IsInputRedirected) {
        [Console]::Error.Write("${Prompt}: ")
        return (Read-Host -AsSecureString)
    }
    [Console]::Error.Write("${Prompt}: ")
    $sec = New-Object System.Security.SecureString
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Enter) { break }
        if ($k.Key -eq [ConsoleKey]::Backspace) {
            if ($sec.Length -gt 0) { $sec.RemoveAt($sec.Length - 1); [Console]::Error.Write("`b `b") }
            continue
        }
        if ([char]::IsControl($k.KeyChar) -or $k.KeyChar -eq [char]0) { continue }   # Tab·ESC·화살표 등
        $sec.AppendChar($k.KeyChar)
        [Console]::Error.Write('*')
    }
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine("받음 $($sec.Length)자")
    return $sec
}
