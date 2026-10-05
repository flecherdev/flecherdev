# setup-freecad-mcp.ps1
# Configura FreeCAD MCP en Windows de punta a punta:
#   1. Instala uv/uvx (si falta) y lo agrega al PATH del usuario
#   2. Copia el addon FreeCADMCP a la carpeta Mod de FreeCAD
#   3. Registra el servidor MCP en Claude Code y/o Claude Desktop
#   4. Verifica que el RPC de FreeCAD responda en el puerto 9875
#
# Uso (PowerShell, sin admin):
#   powershell -ExecutionPolicy Bypass -File .\setup-freecad-mcp.ps1
#   (opcional) -RepoPath "C:\otra\ruta\freecad-mcp"

param(
    [string]$RepoPath = "C:\projects\tools\freecad-mcp"
)

# Continue: en PowerShell 5.1 el stderr de comandos nativos corta el script con "Stop"
$ErrorActionPreference = "Continue"

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    [!]  $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "    [X]  $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
Step "1/4 uv / uvx"
# ---------------------------------------------------------------------------
$uvBin = Join-Path $env:USERPROFILE ".local\bin"
$uvx = Join-Path $uvBin "uvx.exe"

if (-not (Test-Path $uvx)) {
    $found = Get-Command uvx -ErrorAction SilentlyContinue
    if ($found) {
        $uvx = $found.Source
    } else {
        Write-Host "    Instalando uv..."
        try {
            Invoke-RestMethod https://astral.sh/uv/install.ps1 -ErrorAction Stop | Invoke-Expression
        } catch {
            Warn "El instalador oficial fallo ($($_.Exception.Message)). Probando con winget..."
            winget install --id=astral-sh.uv -e --accept-source-agreements --accept-package-agreements
        }
        # refrescar PATH de esta sesion
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine")
        if (Test-Path (Join-Path $uvBin "uvx.exe")) {
            $uvx = Join-Path $uvBin "uvx.exe"
        } else {
            $found = Get-Command uvx -ErrorAction SilentlyContinue
            if (-not $found) { Fail "No pude instalar uvx. Abortando."; exit 1 }
            $uvx = $found.Source
        }
    }
}

# Asegurar que la carpeta de uvx este en el PATH del usuario (persistente)
$uvxDir = Split-Path $uvx -Parent
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not (($userPath -split ";") -contains $uvxDir)) {
    [Environment]::SetEnvironmentVariable("Path", "$uvxDir;$userPath", "User")
    Ok "Agregado $uvxDir al PATH del usuario"
}
if (-not (($env:Path -split ";") -contains $uvxDir)) { $env:Path = "$uvxDir;$env:Path" }
Ok "uvx: $uvx ($(& $uvx --version))"

# ---------------------------------------------------------------------------
Step "2/4 Addon FreeCADMCP"
# ---------------------------------------------------------------------------
$src = Join-Path $RepoPath "addon\FreeCADMCP"
if (-not (Test-Path (Join-Path $src "InitGui.py"))) {
    Fail "No encuentro $src\InitGui.py. Pasa la ruta del clon con -RepoPath"
    exit 1
}

$fcBase = Join-Path $env:APPDATA "FreeCAD"
$modDir = $null
foreach ($candidate in @("v1-1\Mod", "v1-0\Mod", "Mod")) {
    $parent = Split-Path (Join-Path $fcBase $candidate) -Parent
    if ($candidate -eq "Mod" -or (Test-Path $parent)) { $modDir = Join-Path $fcBase $candidate; break }
}
$dest = Join-Path $modDir "FreeCADMCP"
robocopy $src $dest /E /NFL /NDL /NJH /NJS /NP | Out-Null
if (Test-Path (Join-Path $dest "InitGui.py")) { Ok "Addon en $dest" } else { Fail "No se pudo copiar el addon a $dest"; exit 1 }

# ---------------------------------------------------------------------------
Step "3/4 Registrar MCP en Claude"
# ---------------------------------------------------------------------------
$registered = $false

# --- Claude Code (CLI) ---
$claude = Get-Command claude -ErrorAction SilentlyContinue
if ($claude) {
    & claude mcp remove freecad --scope user 2>$null | Out-Null
    & claude mcp add freecad --scope user -- $uvx freecad-mcp
    if ($LASTEXITCODE -eq 0) { Ok "Registrado en Claude Code (scope user)"; $registered = $true }
    else { Warn "claude mcp add devolvio codigo $LASTEXITCODE" }
} else {
    Warn "Claude Code (comando 'claude') no esta instalado; lo salteo"
}

# --- Claude Desktop ---
$desktopConfigs = @(Join-Path $env:APPDATA "Claude\claude_desktop_config.json")
$pkg = Get-ChildItem (Join-Path $env:LOCALAPPDATA "Packages") -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pkg) { $desktopConfigs += Join-Path $pkg.FullName "LocalCache\Roaming\Claude\claude_desktop_config.json" }

foreach ($cfgPath in $desktopConfigs) {
    $cfgDir = Split-Path $cfgPath -Parent
    if (-not (Test-Path $cfgDir)) { continue }   # Claude Desktop no instalado en esta variante

    if (Test-Path $cfgPath) {
        Copy-Item $cfgPath "$cfgPath.bak" -Force
        $raw = Get-Content $cfgPath -Raw
        $cfg = if ([string]::IsNullOrWhiteSpace($raw)) { [pscustomobject]@{} } else { $raw | ConvertFrom-Json -ErrorAction Stop }
    } else {
        $cfg = [pscustomobject]@{}
    }
    if (-not ($cfg.PSObject.Properties.Name -contains "mcpServers")) {
        $cfg | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{})
    }
    $entry = [pscustomobject]@{ command = $uvx; args = @("freecad-mcp") }
    if ($cfg.mcpServers.PSObject.Properties.Name -contains "freecad") {
        $cfg.mcpServers.freecad = $entry
    } else {
        $cfg.mcpServers | Add-Member -NotePropertyName freecad -NotePropertyValue $entry
    }
    # UTF-8 sin BOM (Claude Desktop no acepta BOM)
    [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    Ok "Registrado en Claude Desktop: $cfgPath (backup .bak si existia)"
    $registered = $true
}

if (-not $registered) {
    Warn "No encontre Claude Code ni Claude Desktop. Instala uno:"
    Warn "  Claude Code:    npm install -g @anthropic-ai/claude-code   (y volve a correr este script)"
    Warn "  Claude Desktop: https://claude.ai/download"
}

# Precalentar el paquete para que la primera conexion no tarde
Write-Host "    Descargando freecad-mcp (primera vez puede tardar)..."
& $uvx freecad-mcp --help 2>$null | Out-Null
Ok "freecad-mcp listo"

# ---------------------------------------------------------------------------
Step "4/4 FreeCAD RPC (puerto 9875)"
# ---------------------------------------------------------------------------
$tcp = Test-NetConnection -ComputerName localhost -Port 9875 -WarningAction SilentlyContinue
if ($tcp.TcpTestSucceeded) {
    Ok "FreeCAD responde en localhost:9875"
} else {
    Warn "FreeCAD no responde en 9875. Abri FreeCAD > Ver > Banco de trabajo > MCP Addon > menu 'FreeCAD MCP' > Start RPC Server"
    Warn "(y activa 'Auto-Start Server' en ese menu para no repetirlo)"
}

Write-Host "`nListo. Siguiente paso:" -ForegroundColor Cyan
Write-Host "  - Claude Desktop: cerralo del todo (tambien desde la bandeja) y volve a abrirlo"
Write-Host "  - Claude Code:    abri una terminal nueva y ejecuta 'claude', despues '/mcp' para ver 'freecad' conectado"
Write-Host "  Prueba: 'Crea en FreeCAD un cubo de 20 mm y saca una captura de la vista'"
