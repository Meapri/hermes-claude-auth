# install.ps1 - Claude Code OAuth bypass installer for hermes-agent on Windows.
#
# Windows equivalent of install.sh. The Hermes desktop build keeps its home at
# %LOCALAPPDATA%\hermes (not ~/.hermes) and its venv python at
# venv\Scripts\python.exe (not venv/bin/python), so the bash installer does not
# apply. This mirrors its behavior for Windows.
#
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Check
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -PostUpdate
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$PostUpdate
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Marker = "# hermes-claude-auth managed"

function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "[X] $m"  -ForegroundColor Red }
function Warn($m) { Write-Host "[!] $m"  -ForegroundColor Yellow }

# --- Locate Hermes home -----------------------------------------------------
$HermesHome = $env:HERMES_HOME
if (-not $HermesHome) { $HermesHome = Join-Path $env:LOCALAPPDATA "hermes" }
if (-not (Test-Path $HermesHome)) {
    $classic = Join-Path $HOME ".hermes"
    if (Test-Path $classic) { $HermesHome = $classic }
}
$AgentDir = $env:HERMES_AGENT_DIR
if (-not $AgentDir) { $AgentDir = Join-Path $HermesHome "hermes-agent" }
if (-not (Test-Path $AgentDir)) {
    Bad "hermes-agent not found at $AgentDir"
    Write-Host "    Install Hermes first: https://github.com/nousresearch/hermes-agent"
    exit 1
}
$PatchesDir = Join-Path $HermesHome "patches"

# --- Locate venv + site-packages -------------------------------------------
$VenvDir = $env:HERMES_VENV
if (-not $VenvDir -or -not (Test-Path $VenvDir)) {
    foreach ($c in @((Join-Path $AgentDir "venv"), (Join-Path $AgentDir ".venv"))) {
        if (Test-Path $c) { $VenvDir = $c; break }
    }
}
if (-not $VenvDir -or -not (Test-Path $VenvDir)) { Bad "No virtualenv found in $AgentDir"; exit 1 }

$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
if (-not (Test-Path $VenvPython)) { Bad "python.exe not found at $VenvPython"; exit 1 }

$SitePackages = & $VenvPython -c "import sysconfig; print(sysconfig.get_paths()['purelib'])"
if (-not (Test-Path $SitePackages)) { Bad "site-packages missing: $SitePackages"; exit 1 }
$SiteCustomize = Join-Path $SitePackages "sitecustomize.py"

$RepoPatch = Join-Path $ScriptDir "anthropic_billing_bypass.py"
$InstalledPatch = Join-Path $PatchesDir "anthropic_billing_bypass.py"

# --- Check mode -------------------------------------------------------------
if ($Check) {
    $AllOk = $true
    if (Test-Path $InstalledPatch) { Ok $InstalledPatch } else { Bad "MISSING: $InstalledPatch"; $AllOk = $false }
    if ((Test-Path $SiteCustomize) -and (Select-String -Path $SiteCustomize -SimpleMatch $Marker -Quiet)) {
        Ok "sitecustomize hook present"
    } else { Bad "sitecustomize hook MISSING or outdated"; $AllOk = $false }
    if ((Test-Path $InstalledPatch) -and (Test-Path $RepoPatch)) {
        if ((Get-FileHash $InstalledPatch).Hash -ne (Get-FileHash $RepoPatch).Hash) {
            Warn "DRIFT: installed anthropic_billing_bypass.py differs from repo"; $AllOk = $false
        }
    }
    # Runtime proof: the hook actually applies the bypass on a fresh interpreter.
    Push-Location $AgentDir
    $applied = & $VenvPython -c "from agent import anthropic_adapter as a; print(getattr(a,'_CLAUDE_CODE_BYPASS_APPLIED',False))" 2>$null
    Pop-Location
    if ($applied -eq "True") { Ok "bypass auto-applies at startup" } else { Bad "bypass did NOT auto-apply (got: $applied)"; $AllOk = $false }
    if ($AllOk) { Ok "Claude Code bypass intact."; exit 0 } else { Warn "Patches missing/drifted. Re-run: .\install.ps1"; exit 1 }
}

if ($PostUpdate) { Warn "[post-update] Restoring Claude Code bypass after hermes update..." }
else { Warn "[install] Installing Claude Code OAuth bypass (Windows)..." }

# --- Copy patch (outside venv so it survives hermes update) -----------------
New-Item -ItemType Directory -Force -Path $PatchesDir | Out-Null
Copy-Item $RepoPatch $InstalledPatch -Force
Ok "Copied patch to $PatchesDir"

# --- Install sitecustomize hook into the venv -------------------------------
$AntigravityMarker = "# hermes-antigravity managed"
if ((Test-Path $SiteCustomize) -and (Select-String -Path $SiteCustomize -SimpleMatch $AntigravityMarker -Quiet)) {
    Ok "Antigravity sitecustomize already present (includes Claude hook)"
} else {
    if ((Test-Path $SiteCustomize) -and -not (Select-String -Path $SiteCustomize -SimpleMatch $Marker -Quiet)) {
        Copy-Item $SiteCustomize "$SiteCustomize.pre-hermes-claude-auth" -Force
        Warn "Backed up existing sitecustomize.py"
    }
    Copy-Item (Join-Path $ScriptDir "sitecustomize_hook.py") $SiteCustomize -Force
    Ok "Installed hook into $SiteCustomize"
}

# --- Verify -----------------------------------------------------------------
Push-Location $AgentDir
$ver = & $VenvPython -c "import sys; sys.path.insert(0, r'$PatchesDir'); import anthropic_billing_bypass as b; print(b.__version__)" 2>$null
$applied = & $VenvPython -c "from agent import anthropic_adapter as a; print(getattr(a,'_CLAUDE_CODE_BYPASS_APPLIED',False))" 2>$null
Pop-Location
if ($ver) { Ok "Patch integrity: v$ver" } else { Bad "Patch import failed" }
if ($applied -eq "True") { Ok "Bypass auto-applies at startup" } else { Warn "Bypass did not auto-apply (got: $applied)" }

Write-Host ""
Ok "Installation complete."
Write-Host "  Patch: $InstalledPatch"
Write-Host "  Hook:  $SiteCustomize"
Write-Host "  Venv:  $VenvDir"
Write-Host "Verify: hermes chat --provider anthropic -m claude-sonnet-4-6 -q 'test'"
