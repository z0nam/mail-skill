# PowerShell bootstrap script for mail-skill on Windows
# 셋업 — 기계당 한 번. deps 설치 안내 + age 키 생성 + 심링크/복사 설정.

$ErrorActionPreference = "Stop"

# 1) 경로 정의
$REPO = Resolve-Path "$PSScriptRoot\.."
$CONFIG_DIR = "$env:USERPROFILE\.config"
# 키/시크릿 디렉터리는 리졸버(mail-secret)·README 와 반드시 일치해야 한다: mail-skill.
# (과거 mail-mcp 였으나 리네임됨 — 여기가 어긋나면 부트스트랩 직후 auth.cmd 가 키 없음으로 실패한다.)
$MAIL_SKILL_DIR = "$CONFIG_DIR\mail-skill"
$HIMALAYA_DIR = "$CONFIG_DIR\himalaya"
$CLAUDE_SKILLS_DIR = "$env:USERPROFILE\.claude\skills"
$CODEX_SKILLS_DIR = "$env:USERPROFILE\.codex\skills"
$KEY_PATH = "$MAIL_SKILL_DIR\age-key.txt"

# 2) 의존성 확인 (himalaya, age, age-keygen, python)
#    python 은 날짜검색 클라이언트측 폴백(scripts/date-search.py)에 쓰인다 — 없어도
#    대부분 동작하지만, 네이버웍스류 서버의 날짜검색이 조용히 0건일 때 폴백이 안 된다.
Write-Host "1. 의존성 점검..." -ForegroundColor Cyan
$deps = @("himalaya", "age", "age-keygen")
foreach ($dep in $deps) {
    if (-not (Get-Command $dep -ErrorAction SilentlyContinue)) {
        Write-Warning "⚠ '$dep' 이(가) PATH에 없습니다. scoop, winget 또는 manual 설치가 필요합니다."
        if ($dep -eq "himalaya") {
            Write-Host "   -> winget install pimalaya.himalaya  또는  scoop install himalaya" -ForegroundColor Gray
        } elseif ($dep -like "age*") {
            Write-Host "   -> winget install FiloSottile.age  또는  scoop install age" -ForegroundColor Gray
        }
    }
}
if (-not (Get-Command python -ErrorAction SilentlyContinue) -and -not (Get-Command python3 -ErrorAction SilentlyContinue)) {
    Write-Warning "⚠ 'python' 이(가) PATH에 없습니다(선택). 날짜검색 폴백에만 필요합니다."
    Write-Host "   -> winget install Python.Python.3.12  또는  scoop install python" -ForegroundColor Gray
}

# 3) age 키 생성
Write-Host "`n2. age 개인키/공개키 생성..." -ForegroundColor Cyan
if (-not (Test-Path $MAIL_SKILL_DIR)) {
    New-Item -ItemType Directory -Path $MAIL_SKILL_DIR -Force | Out-Null
}

if (-not (Test-Path $KEY_PATH)) {
    if (Get-Command age-keygen -ErrorAction SilentlyContinue) {
        age-keygen -o $KEY_PATH
        Write-Host "개인키 생성 완료: $KEY_PATH" -ForegroundColor Green
    } else {
        Write-Error "age-keygen 명령어를 실행할 수 없어 age 키를 생성하지 못했습니다."
    }
} else {
    Write-Host "기존 age 개인키가 존재합니다: $KEY_PATH" -ForegroundColor Yellow
}

$PUB = & age-keygen -y $KEY_PATH
$PUB = $PUB.Trim()

# 4) 심링크 설정
Write-Host "`n3. 설정 파일 및 스킬 심링크 구성..." -ForegroundColor Cyan

# 디렉토리 생성
if (-not (Test-Path $HIMALAYA_DIR)) { New-Item -ItemType Directory -Path $HIMALAYA_DIR -Force | Out-Null }
if (-not (Test-Path $CLAUDE_SKILLS_DIR)) { New-Item -ItemType Directory -Path $CLAUDE_SKILLS_DIR -Force | Out-Null }
if (-not (Test-Path $CODEX_SKILLS_DIR)) { New-Item -ItemType Directory -Path $CODEX_SKILLS_DIR -Force | Out-Null }

function Create-Symlink {
    param (
        [string]$Link,
        [string]$Target
    )
    if (Test-Path $Link) {
        Remove-Item $Link -Force -Recurse
    }
    try {
        New-Item -ItemType SymbolicLink -Path $Link -Target $Target -Force | Out-Null
        Write-Host "심링크 완료: $Link -> $Target" -ForegroundColor Green
    } catch {
        Write-Warning "심링크 생성 실패 (권한 부족 또는 개발자 모드 미활용). 복사본으로 대체합니다."
        Copy-Item -Path $Target -Destination $Link -Recurse -Force
        Write-Host "복사 완료: $Link" -ForegroundColor Yellow
    }
}

Create-Symlink -Link "$HIMALAYA_DIR\config.toml" -Target "$REPO\config\config.toml"
Create-Symlink -Link "$CLAUDE_SKILLS_DIR\mail" -Target "$REPO\.claude\skills\mail"
Create-Symlink -Link "$CODEX_SKILLS_DIR\mail" -Target "$REPO\.claude\skills\mail"

# 5) config.toml 준비 안내 (없으면 샘플 복사 안내)
if (-not (Test-Path "$HIMALAYA_DIR\config.toml")) {
    Write-Host "`n4. config.toml 이 아직 없습니다." -ForegroundColor Yellow
    Write-Host "   -> Copy-Item `"$REPO\config\config.sample.toml`" `"$HIMALAYA_DIR\config.toml`" 로 시작해 계정을 채우세요." -ForegroundColor Gray
}

Write-Host "`n── 이 기계 age 공개키 ──" -ForegroundColor Green
Write-Host "  $PUB" -ForegroundColor White
Write-Host "→ 타 기계의 secrets/recipients.txt에 추가하고 'scripts/secret-edit'(또는 secret-set) 실행 후 push하십시오." -ForegroundColor Gray
Write-Host "  그 후 이 기계에서 git pull을 받으면 암호화된 기밀 조회가 가능합니다." -ForegroundColor Gray

Write-Host "`n── PATH 설정 (필수) ──" -ForegroundColor Green
Write-Host "  bin\ 에 mailskill.cmd / mail-secret.cmd / secret-set.cmd shim 이 있습니다." -ForegroundColor Gray
Write-Host "  이 경로를 PATH 에 넣어야 'mailskill' 과, Himalaya auth.cmd 의 'mail-secret' 이 동작합니다:" -ForegroundColor Gray
Write-Host "    setx PATH `"`$env:PATH;$REPO\bin`"   # 새 터미널부터 적용" -ForegroundColor White
Write-Host "  확인:  mailskill accounts" -ForegroundColor Gray
