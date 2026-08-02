#Requires -Version 5.1
<#
.SYNOPSIS
    Setup completo do ambiente de orquestração Claude Code + Antigravity CLI no Windows.

.DESCRIPTION
    Script unificado que configura AMBAS as camadas da orquestração:

    Camada 1 — Claude Code (orquestrador):
      - Servidor MCP Python (~/.claude/mcp/antigravity_mcp.py)
      - Registro MCP no escopo de usuário (claude mcp add --scope user)
      - Regra global de orquestração (~/.claude/CLAUDE.md)
      - Subagente executor opcional (~/.claude/agents/gemini-executor.md)

    Camada 2 — Antigravity CLI (executor):
      - Regra global de fallback entre modelos (~/.gemini/GEMINI.md)
      - Modelo padrão em settings.json → Gemini 3.1 Pro (High)

    O script também verifica e instala automaticamente todas as dependências:
      - Python 3.9+ (via winget)
      - Node.js LTS (via winget, necessário para o Claude Code)
      - Claude Code (npm install -g)
      - Antigravity CLI (script oficial do Google)
      - SDK MCP para Python (pip install mcp[cli])
      - pywinpty (pip install pywinpty, ConPTY para Windows nativo)

    Backups são criados automaticamente antes de qualquer alteração (.bak.TIMESTAMP).

.PARAMETER Check
    Apenas verifica o estado atual sem modificar nada.

.PARAMETER DryRun
    Mostra o que seria feito sem aplicar nenhuma alteração.

.PARAMETER Force
    Aplica sem pedir confirmação interativa.

.PARAMETER Uninstall
    Remove os artefatos criados por este script (com backup).

.PARAMETER Restore
    Restaura os arquivos a partir dos backups mais recentes.

.PARAMETER KeepSubagent
    Também instala o subagente gemini-executor (opcional).

.PARAMETER Model
    Nome do modelo padrão. O agy espera o NOME EXIBIDO com espaços e sufixo
    de esforço — ex.: "Gemini 3.1 Pro (High)", não um slug como "gemini-3.1-pro".

.PARAMETER SkipInstall
    Pula a instalação automática de ferramentas ausentes (só verifica).

.EXAMPLE
    .\setup-ambiente-completo.ps1
    # Instalação completa com confirmação interativa

.EXAMPLE
    .\setup-ambiente-completo.ps1 -Force
    # Instalação completa sem confirmação

.EXAMPLE
    .\setup-ambiente-completo.ps1 -Check
    # Apenas verifica o estado atual

.EXAMPLE
    .\setup-ambiente-completo.ps1 -DryRun
    # Mostra o que seria feito sem alterar nada

.EXAMPLE
    .\setup-ambiente-completo.ps1 -Model "Claude Opus 4.6 (Thinking)"
    # Usa Claude Opus como modelo padrão

.EXAMPLE
    .\setup-ambiente-completo.ps1 -Uninstall
    # Remove todos os artefatos (com backup)

.EXAMPLE
    .\setup-ambiente-completo.ps1 -Restore
    # Restaura backups mais recentes
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Uninstall,
    [switch]$Restore,
    [switch]$KeepSubagent,
    [switch]$SkipInstall,
    [string]$Model = "Gemini 3.1 Pro (High)"
)

$ErrorActionPreference = "Stop"

# =============================================================================
# Caminhos e Constantes
# =============================================================================

# Camada 1 — Claude Code
$ClaudeDir       = Join-Path $env:USERPROFILE ".claude"
$McpDir          = Join-Path $ClaudeDir "mcp"
$AgentsDir       = Join-Path $ClaudeDir "agents"
$ServerFile      = Join-Path $McpDir "antigravity_mcp.py"
$AgentFile       = Join-Path $AgentsDir "gemini-executor.md"
$ClaudeMemory    = Join-Path $ClaudeDir "CLAUDE.md"
$ServerName      = "antigravity"

# Camada 2 — Antigravity CLI
$GeminiDir       = Join-Path $env:USERPROFILE ".gemini"
$GeminiMdPath    = Join-Path $GeminiDir "GEMINI.md"
$SettingsDir     = Join-Path $GeminiDir "antigravity-cli"
$SettingsPath    = Join-Path $SettingsDir "settings.json"

# Marcadores no CLAUDE.md
$MarkBegin = "<!-- ORQUESTRA:BEGIN -->"
$MarkEnd   = "<!-- ORQUESTRA:END -->"

# =============================================================================
# Funções de Saída
# =============================================================================

function Write-Banner {
    Write-Host ""
    Write-Host "  +=================================================================+" -ForegroundColor Cyan
    Write-Host "  |                                                                 |" -ForegroundColor Cyan
    Write-Host "  |   Claude Code + Antigravity CLI -- Setup Completo               |" -ForegroundColor Cyan
    Write-Host "  |   Orquestracao via MCP + Fallback Automatico de Modelos          |" -ForegroundColor Cyan
    Write-Host "  |                                                                 |" -ForegroundColor Cyan
    Write-Host "  +=================================================================+" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Info  ($m) { Write-Host "  [i] $m"    -ForegroundColor Gray }
function Write-Ok    ($m) { Write-Host "  [+] $m"    -ForegroundColor Green }
function Write-Warn  ($m) { Write-Host "  [!] $m"    -ForegroundColor Yellow }
function Write-Err   ($m) { Write-Host "  [x] $m"    -ForegroundColor Red }
function Write-Step  ($m) { Write-Host "`n  == $m ==" -ForegroundColor White }
function Write-Dry   ($m) { Write-Host "  [~] [DRY] $m" -ForegroundColor Magenta }

# =============================================================================
# Helpers
# =============================================================================

function Get-PythonCommand {
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
    return $py
}

function Test-PythonModule {
    param([string]$PyExe, [string]$Module)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        & $PyExe -c "import $Module" *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Write-Utf8Bom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Backup-File {
    param([string]$Path)
    if (Test-Path $Path) {
        $stamp = Get-Date -Format "yyyyMMddHHmmss"
        $bakPath = "$Path.bak.$stamp"
        Copy-Item $Path $bakPath -Force
        return $bakPath
    }
    return $null
}

function Get-LatestBackup {
    param([string]$Path)
    $dir = Split-Path $Path -Parent
    $name = Split-Path $Path -Leaf
    $baks = Get-ChildItem -Path $dir -Filter "$name.bak.*" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    if ($baks.Count -gt 0) { return $baks[0].FullName }
    return $null
}

function Test-WingetAvailable {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Install-ViaWinget {
    param([string]$PackageId, [string]$DisplayName)
    if (-not (Test-WingetAvailable)) {
        Write-Warn "winget nao disponivel -- instale $DisplayName manualmente."
        return $false
    }
    if ($DryRun) {
        Write-Dry "Instalaria $DisplayName via: winget install $PackageId"
        return $true
    }
    Write-Info "Instalando $DisplayName via winget..."
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    & winget install $PackageId --accept-source-agreements --accept-package-agreements --silent *> $null
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($rc -eq 0) {
        Write-Ok "$DisplayName instalado com sucesso"
        Write-Warn "REINICIE O TERMINAL para que o PATH seja atualizado antes de continuar."
        return $true
    } else {
        Write-Warn "winget retornou exit $rc para $DisplayName -- pode ja estar instalado ou precisar de intervencao manual."
        return $false
    }
}

# =============================================================================
# Modo Restore
# =============================================================================

if ($Restore) {
    Write-Banner
    Write-Step "Restaurando backups mais recentes"

    $restored = 0
    foreach ($path in @($ServerFile, $ClaudeMemory, $AgentFile, $GeminiMdPath, $SettingsPath)) {
        $bak = Get-LatestBackup -Path $path
        if ($bak) {
            if ($DryRun) {
                Write-Dry "Restauraria $bak -> $path"
            } else {
                Copy-Item $bak $path -Force
                Write-Ok "Restaurado: $path (de $bak)"
            }
            $restored++
        } else {
            Write-Info "Sem backup para: $path"
        }
    }

    if ($restored -eq 0) {
        Write-Warn "Nenhum backup encontrado."
    } else {
        Write-Ok "$restored arquivo(s) restaurado(s)."
    }
    Write-Host ""
    exit 0
}

# =============================================================================
# Verificacao de Pre-requisitos
# =============================================================================

function Test-AllPrereqs {
    Write-Step "Pre-requisitos"
    $issues = @()
    $warnings = @()

    # --- PowerShell ---
    $psVer = $PSVersionTable.PSVersion
    if ($psVer.Major -ge 5) {
        Write-Ok "PowerShell $psVer"
    } else {
        Write-Err "PowerShell $psVer (minimo: 5.1)"
        $issues += "PowerShell muito antigo"
    }

    # --- winget ---
    if (Test-WingetAvailable) {
        Write-Ok "winget disponivel (instalacao automatica habilitada)"
    } else {
        Write-Warn "winget nao disponivel -- ferramentas ausentes precisarao de instalacao manual"
        $warnings += "winget ausente"
    }

    # --- Python ---
    $py = Get-PythonCommand
    if ($py) {
        $ver = & $py.Source -c "import sys;print('%d.%d.%d'%sys.version_info[:3])"
        & $py.Source -c "import sys;sys.exit(0 if sys.version_info[:2]>=(3,9) else 1)"
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Python $ver (>= 3.9) em $($py.Source)"
        } else {
            Write-Err "Python $ver e muito antigo (precisa 3.9+)"
            $issues += "Python < 3.9"
        }
    } else {
        Write-Err "Python nao encontrado no PATH"
        $issues += "Python ausente"
    }

    # --- Node.js ---
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $nodeVer = (& node --version 2>$null)
        Write-Ok "Node.js $nodeVer"
    } else {
        Write-Warn "Node.js nao encontrado -- necessario para instalar o Claude Code"
        $warnings += "Node.js ausente"
    }

    # --- npm ---
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        $npmVer = (& npm --version 2>$null)
        Write-Ok "npm $npmVer"
    } else {
        Write-Warn "npm nao encontrado -- necessario para instalar o Claude Code"
        $warnings += "npm ausente"
    }

    # --- Claude Code ---
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Write-Ok "Claude Code (claude) encontrado"
    } else {
        Write-Warn "Claude Code (claude) nao encontrado no PATH"
        $warnings += "Claude Code ausente"
    }

    # --- Antigravity CLI ---
    if (Get-Command agy -ErrorAction SilentlyContinue) {
        Write-Ok "Antigravity CLI (agy) encontrado"
    } else {
        Write-Warn "Antigravity CLI (agy) nao encontrado"
        $warnings += "agy ausente"
    }

    # --- Variaveis de ambiente (assinatura Claude) ---
    $persisted = @()
    $processOnly = @()
    foreach ($v in "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY") {
        $u = [Environment]::GetEnvironmentVariable($v, "User")
        $m = [Environment]::GetEnvironmentVariable($v, "Machine")
        $pr = [Environment]::GetEnvironmentVariable($v, "Process")
        if ($u -or $m)  { $persisted += $v }
        elseif ($pr)    { $processOnly += $v }
    }
    if ($persisted.Count -gt 0) {
        Write-Err "$($persisted -join ', ') persistido(s) no escopo usuario/maquina -- desliga a assinatura Claude!"
        $issues += "ANTHROPIC_* persistido"
    } elseif ($processOnly.Count -gt 0) {
        Write-Warn "$($processOnly -join ', ') presente(s) apenas NESTE processo (esperado dentro do Claude Code)"
    } else {
        Write-Ok "Sem ANTHROPIC_BASE_URL/ANTHROPIC_API_KEY vazando (assinatura preservada)"
    }

    # --- Dependencias Python ---
    if ($py) {
        if (Test-PythonModule -PyExe $py.Source -Module "mcp.server.fastmcp") {
            Write-Ok "SDK mcp (Python) presente"
        } else {
            Write-Warn "SDK mcp (Python) ausente -- sera instalado"
            $warnings += "mcp ausente"
        }

        if (Test-PythonModule -PyExe $py.Source -Module "winpty") {
            Write-Ok "pywinpty presente"
        } else {
            Write-Warn "pywinpty ausente -- sera instalado"
            $warnings += "pywinpty ausente"
        }
    }

    return @{ Issues = $issues; Warnings = $warnings }
}

# =============================================================================
# Instalacao Automatica de Ferramentas
# =============================================================================

function Install-MissingTools {
    Write-Step "Instalacao de ferramentas ausentes"

    $needsRestart = $false

    # --- Python ---
    $py = Get-PythonCommand
    if (-not $py) {
        Write-Info "Python nao encontrado. Tentando instalar..."
        if (Install-ViaWinget -PackageId "Python.Python.3.12" -DisplayName "Python 3.12") {
            $needsRestart = $true
        }
    }

    # --- Node.js ---
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Info "Node.js nao encontrado. Tentando instalar..."
        if (Install-ViaWinget -PackageId "OpenJS.NodeJS.LTS" -DisplayName "Node.js LTS") {
            $needsRestart = $true
        }
    }

    if ($needsRestart -and -not $DryRun) {
        Write-Host ""
        Write-Warn "============================================================"
        Write-Warn "  FERRAMENTAS INSTALADAS -- REINICIE O TERMINAL"
        Write-Warn "  Apos reiniciar, rode este script novamente."
        Write-Warn "============================================================"
        Write-Host ""
        exit 0
    }

    # --- Claude Code (requer npm) ---
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            if ($DryRun) {
                Write-Dry "Instalaria Claude Code via: npm install -g @anthropic-ai/claude-code"
            } else {
                Write-Info "Instalando Claude Code via npm..."
                $prev = $ErrorActionPreference
                $ErrorActionPreference = "SilentlyContinue"
                & npm install -g @anthropic-ai/claude-code *> $null
                $rc = $LASTEXITCODE
                $ErrorActionPreference = $prev
                if ($rc -eq 0) {
                    Write-Ok "Claude Code instalado"
                    Write-Warn "Execute 'claude' para autenticar (abre navegador para OAuth)."
                } else {
                    Write-Warn "Falha ao instalar Claude Code (exit $rc) -- instale manualmente: npm install -g @anthropic-ai/claude-code"
                }
            }
        } else {
            Write-Warn "npm ausente -- nao e possivel instalar o Claude Code automaticamente."
            Write-Warn "  Instale Node.js e depois: npm install -g @anthropic-ai/claude-code"
        }
    }

    # --- Antigravity CLI ---
    if (-not (Get-Command agy -ErrorAction SilentlyContinue)) {
        if ($DryRun) {
            Write-Dry "Instalaria Antigravity CLI via: irm https://antigravity.google/cli/install.ps1 | iex"
        } else {
            Write-Info "Instalando Antigravity CLI..."
            try {
                $installScript = Invoke-RestMethod "https://antigravity.google/cli/install.ps1"
                Invoke-Expression $installScript
                Write-Ok "Antigravity CLI instalado"
                Write-Warn "Execute 'agy' para autenticar (Google Sign-In com conta Google AI Pro)."
            } catch {
                Write-Warn "Falha ao instalar Antigravity CLI: $_"
                Write-Warn "  Instale manualmente: irm https://antigravity.google/cli/install.ps1 | iex"
            }
        }
    }

    # --- Dependencias Python ---
    $py = Get-PythonCommand
    if ($py) {
        foreach ($dep in @(
            @{ Module = "mcp.server.fastmcp"; Package = "mcp[cli]" },
            @{ Module = "winpty";             Package = "pywinpty" }
        )) {
            if (Test-PythonModule -PyExe $py.Source -Module $dep.Module) {
                Write-Ok "$($dep.Package) ja presente"
                continue
            }
            if ($DryRun) {
                Write-Dry "Instalaria $($dep.Package) via pip"
                continue
            }
            Write-Info "Instalando $($dep.Package)..."
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = "SilentlyContinue"
            & $py.Source -m pip install --quiet --disable-pip-version-check $dep.Package *> $null
            $rc = $LASTEXITCODE
            $ErrorActionPreference = $prevEap
            if ($rc -eq 0 -and (Test-PythonModule -PyExe $py.Source -Module $dep.Module)) {
                Write-Ok "$($dep.Package) instalado"
            } else {
                Write-Warn "Falha ao instalar $($dep.Package) -- rode manualmente: pip install '$($dep.Package)'"
            }
        }
    }
}

# =============================================================================
# Conteudo do Servidor MCP (Camada 1)
# =============================================================================

function Get-ServerContent {
    param([string]$ModelId)
    $tpl = @'
#!/usr/bin/env python3
"""antigravity-mcp - expoe o Antigravity CLI (agy) como ferramentas MCP.

gemini_execute(prompt, model?, timeout?) -> str
    Roda `agy -p` sob PTY (workaround do issue #76), limpa ANSI e devolve texto.
    Reporta progresso em tempo real via notifications/progress do MCP.
    Em quota/erro/saida-vazia LEVANTA erro cuja mensagem comeca com
    'GEMINI_UNAVAILABLE:' -> vira tool error (isError) para o orquestrador.

    Guardrail de encoding: apos a execucao, detecta arquivos em que o agy
    introduziu mojibake (dupla codificacao UTF-8->CP1252). NAO reverte o
    arquivo (preserva o codigo bom do agy); anexa ao resultado um aviso
    [GUARDRAIL-ENCODING] com as linhas exatas para o Claude corrigir a mao.
    Desligavel via AGY_ENCODING_GUARD=0.

gemini_execute_verbose(prompt, model?, timeout?) -> str
    Igual ao gemini_execute, mas devolve o output bruto (sem limpeza ANSI).
    Use para diagnosticar problemas de output ou verificar o raciocinio do agy.

gemini_models() -> str
    Lista os IDs de modelo disponiveis (agy models).

Deps: mcp (pip install "mcp[cli]") + pywinpty no Windows nativo.
Gerado por setup-ambiente-completo.ps1 - edicoes manuais serao sobrescritas.
"""
import asyncio
import os
import re

from mcp.server.fastmcp import FastMCP, Context

DEFAULT_MODEL = os.environ.get("AGY_EXEC_MODEL", "__MODEL_ID__")
DEFAULT_TIMEOUT = os.environ.get("AGY_EXEC_TIMEOUT", "30m")

ANSI = re.compile(r"\x1B(?:\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\))")
QUOTA = re.compile(r"quota|rate.?limit|resource.?exhausted|429|cooldown|weekly|"
                   r"try again|limit reached|unavailable", re.I)

mcp = FastMCP("antigravity")


class GeminiUnavailable(RuntimeError):
    """Mensagem sempre comeca com GEMINI_UNAVAILABLE: - dispara o fallback."""


def _clean(raw):
    r"""Reduz a saida de TUI do agy a texto util.

    Duas passadas, nesta ordem:
    1. Remove sequencias ANSI (cores, movimentos de cursor, apagar linha).
    2. Emula a semantica de carriage return. O agy anima um spinner reescrevendo
       a MESMA linha com '\r' antes de cada frame; sem isso os frames sobrevivem
       como texto ("... Fetching available models..." repetido) e afogam a
       resposta real. Num terminal, so o ultimo segmento apos um '\r' fica
       visivel - e o mesmo criterio se aplica aqui.

    A normalizacao de CRLF vem ANTES do split por '\r': as linhas terminam em
    '\r\n' e, sem isso, o '\r' final de cada linha apagaria o proprio conteudo.
    """
    text = ANSI.sub("", raw).replace("\r\n", "\n")
    text = "\n".join(line.split("\r")[-1] for line in text.split("\n"))
    # rstrip por linha, preservando linhas em branco internas (importam em codigo)
    return "\n".join(line.rstrip() for line in text.split("\n")).strip()


async def _run_agy_streaming(args, ctx=None):
    """Roda `agy` sob PTY com streaming de progresso via MCP.

    Diferente da versao anterior (sincrona, buffer total), esta versao:
    1. Le chunks incrementalmente do PTY
    2. Envia notifications/progress ao Claude Code a cada chunk significativo
    3. Roda a leitura bloqueante em thread separada para nao travar o event loop

    Retorna (texto_limpo, texto_bruto, exit_code).
    """
    cmd = ["agy"] + list(args)

    if os.name == "nt":                       # Windows nativo -> ConPTY
        try:
            from winpty import PtyProcess
        except ImportError:
            raise GeminiUnavailable(
                "GEMINI_UNAVAILABLE: pywinpty ausente (pip install pywinpty) ou use WSL")

        proc = PtyProcess.spawn(cmd)
        chunks = []
        lines_seen = 0

        while True:
            try:
                chunk = await asyncio.to_thread(proc.read)
                chunks.append(chunk)
                lines_seen += chunk.count("\n")

                # Extrai a ultima linha significativa para reportar progresso
                cleaned = _clean(chunk)
                if cleaned.strip() and ctx:
                    last_line = cleaned.strip().split("\n")[-1][:200]
                    try:
                        await ctx.report_progress(
                            progress=lines_seen,
                            total=0,
                            message="[agy] " + last_line
                        )
                    except Exception:
                        pass  # Nao deixa falha de progresso quebrar a execucao
            except EOFError:
                break

        raw = "".join(chunks)
        code = proc.wait()
    else:                                     # Unix/WSL -> pty da stdlib
        import pty
        buf = bytearray()

        def reader(fd):
            buf.extend(os.read(fd, 4096))
            return b""                        # suprime o echo: nao polui o stdio do MCP

        status = pty.spawn(cmd, reader)
        raw = buf.decode("utf-8", "replace")
        code = os.waitstatus_to_exitcode(status)

    return _clean(raw), raw, code


# ---------------------------------------------------------------------------
# Guardrail de encoding: detecta mojibake introduzido pelo agy
# ---------------------------------------------------------------------------
# O agy tem bug documentado: le um arquivo UTF-8, decodifica os bytes como
# CP1252 e regrava, produzindo dupla codificacao (mojibake). O resultado ainda
# e UTF-8 VALIDO -- entao um decode("utf-8") estrito NAO pega. A deteccao real
# compara a assinatura de mojibake antes vs. depois da execucao do agy.
#
# Politica: NAO reverter o arquivo. O agy costuma escrever muito codigo bom e
# so as linhas acentuadas corrompem; reverter sacrificaria o trabalho todo. Em
# vez disso, preservamos o arquivo e reportamos as linhas exatas para o Claude
# corrigir cirurgicamente (edicao direta).

# Lead U+00C2/U+00C3/U+00E2 (bytes 0x82..0xE2 de sequencias UTF-8 lidas como
# CP1252) seguido de outro char Latin-1; mais o par "a-EUR" e o U+FFFD.
_MOJIBAKE = re.compile(
    "[\u00c2\u00c3\u00e2][\u0080-\u00ff]"
    "|\u00e2\u20ac"
    "|\ufffd"
)

_SKIP_DIRS = {
    ".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build",
    ".mypy_cache", ".pytest_cache", ".idea", ".vs", "bin", "obj",
}


def _mojibake_count(text):
    return len(_MOJIBAKE.findall(text))


def _file_corrupted(before, after):
    """True sse o agy introduziu mojibake: assinatura aumentou, ou o arquivo
    era UTF-8 valido e deixou de ser. Auto-calibrado -> zero falso positivo."""
    try:
        after.decode("utf-8")
        after_valid = True
    except UnicodeDecodeError:
        after_valid = False
    try:
        before.decode("utf-8")
        before_valid = True
    except UnicodeDecodeError:
        before_valid = False
    if before_valid and not after_valid:
        return True
    b = _mojibake_count(before.decode("utf-8", "replace"))
    a = _mojibake_count(after.decode("utf-8", "replace"))
    return a > b


def _corrupt_lines(after):
    """Lista (numero_da_linha, texto) das linhas com mojibake no arquivo."""
    text = after.decode("utf-8", "replace")
    out = []
    for i, line in enumerate(text.split("\n"), 1):
        if _MOJIBAKE.search(line):
            out.append((i, line))
    return out


def _repair_hint(line):
    """Sugestao revertendo a dupla codificacao. So uma DICA -- quem aplica e
    o Claude. Retorna None se a reversao nao produzir texto limpo."""
    try:
        fixed = line.encode("cp1252").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return None
    if fixed != line and not _MOJIBAKE.search(fixed):
        return fixed
    return None


def _iter_candidates(root):
    maxb = int(os.environ.get("AGY_GUARD_MAXBYTES", "5000000"))
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in _SKIP_DIRS]
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            try:
                if os.path.getsize(p) > maxb:
                    continue
            except OSError:
                continue
            out.append(p)
    return out


def _read_text_bytes(path):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    if b"\x00" in data[:4096]:      # provavelmente binario -> ignora
        return None
    return data


def _snapshot(root):
    snap = {}
    for p in _iter_candidates(root):
        data = _read_text_bytes(p)
        if data is not None:
            snap[p] = data
    return snap


async def _guarded_run(args, ctx=None):
    """Envolve _run_agy_streaming com o guardrail de encoding.

    Retorna (clean, raw, code, warnings), onde warnings e uma lista de
    (path, [(lineno, texto), ...]) para cada arquivo em que o agy introduziu
    mojibake. Nenhum arquivo e modificado aqui.
    """
    if os.environ.get("AGY_ENCODING_GUARD", "1") == "0":
        clean, raw, code = await _run_agy_streaming(args, ctx=ctx)
        return clean, raw, code, []

    root = os.getcwd()
    before = _snapshot(root)
    clean, raw, code = await _run_agy_streaming(args, ctx=ctx)

    warnings = []
    seen = set()
    # Arquivos preexistentes que o agy alterou
    for p, old in before.items():
        seen.add(p)
        new = _read_text_bytes(p)
        if new is None or new == old:
            continue
        if _file_corrupted(old, new):
            warnings.append((p, _corrupt_lines(new)))
    # Arquivos novos que o agy criou ja com mojibake
    for p in _iter_candidates(root):
        if p in seen:
            continue
        new = _read_text_bytes(p)
        if new is None:
            continue
        if _file_corrupted(b"", new):
            warnings.append((p, _corrupt_lines(new)))
    return clean, raw, code, warnings


def _format_warnings(warnings, root):
    if not warnings:
        return ""
    out = [
        "",
        "[GUARDRAIL-ENCODING] agy introduziu mojibake (UTF-8->CP1252) em "
        "%d arquivo(s)." % len(warnings),
        "O conteudo do agy foi PRESERVADO; corrija APENAS as linhas abaixo via",
        "edicao direta (Claude), sem reescrever o resto do arquivo:",
    ]
    for p, corrupt in warnings:
        try:
            rel = os.path.relpath(p, root)
        except ValueError:
            rel = p
        out.append("  " + rel + ":")
        for lineno, text in corrupt[:50]:
            snippet = text.strip()[:120]
            hint = _repair_hint(text)
            if hint:
                out.append("    L%d: %s   -> sugestao: %s"
                           % (lineno, snippet, hint.strip()[:120]))
            else:
                out.append("    L%d: %s" % (lineno, snippet))
        if len(corrupt) > 50:
            out.append("    ... (+%d linhas com mojibake)" % (len(corrupt) - 50))
    out.append("ACAO: aplique Edit cirurgico so nessas linhas; nao delegue de")
    out.append("novo ao agy nem reverta o arquivo inteiro.")
    return "\n".join(out)


@mcp.tool()
async def gemini_execute(prompt: str, model: str = "", timeout: str = "",
                         ctx: Context = None) -> str:
    """Executa uma instrucao de codigo ja planejada via Antigravity CLI (Gemini).

    Use para aplicar edicoes multi-arquivo e refatoracoes extensas DEPOIS que o
    plano estiver aprovado. O prompt deve ser UMA instrucao completa e
    autocontida - o agy nao ve o historico da conversa.

    Reporta progresso em tempo real: o Claude Code mostrara o raciocinio do agy
    enquanto ele trabalha, sem precisar esperar o resultado final.
    """
    if not prompt or not prompt.strip():
        raise GeminiUnavailable("GEMINI_UNAVAILABLE: prompt vazio")

    if ctx:
        try:
            await ctx.report_progress(
                progress=0, total=0,
                message="[agy] Iniciando execucao via Antigravity CLI..."
            )
        except Exception:
            pass

    clean, _raw, code, warns = await _guarded_run([
        "--dangerously-skip-permissions",
        "--print-timeout", timeout or DEFAULT_TIMEOUT,
        "--model", model or DEFAULT_MODEL,
        "-p", prompt,
    ], ctx=ctx)

    if ctx:
        try:
            await ctx.report_progress(
                progress=100, total=100,
                message="[agy] Execucao concluida - processando resultado"
            )
        except Exception:
            pass

    if code != 0:
        detalhe = (clean[-300:] if clean else "sem saida").replace("\n", " ")
        raise GeminiUnavailable(
            "GEMINI_UNAVAILABLE: agy saiu com codigo %d: %s" % (code, detalhe))
    if not clean or QUOTA.search(clean):
        tail = clean[-200:] if clean else "sem saida (possivel quota/non-TTY)"
        raise GeminiUnavailable("GEMINI_UNAVAILABLE: " + tail.replace("\n", " "))
    guard = _format_warnings(warns, os.getcwd())
    return clean + ("\n" + guard if guard else "")


@mcp.tool()
async def gemini_execute_verbose(prompt: str, model: str = "", timeout: str = "",
                                  ctx: Context = None) -> str:
    """Igual ao gemini_execute, mas devolve o output bruto sem limpeza ANSI.

    Use para diagnosticar problemas de output ou verificar a linha de raciocinio
    completa do agy, incluindo sequencias de terminal e frames de spinner.
    """
    if not prompt or not prompt.strip():
        raise GeminiUnavailable("GEMINI_UNAVAILABLE: prompt vazio")

    if ctx:
        try:
            await ctx.report_progress(
                progress=0, total=0,
                message="[agy] Iniciando execucao (modo verbose)..."
            )
        except Exception:
            pass

    clean, raw, code, warns = await _guarded_run([
        "--dangerously-skip-permissions",
        "--print-timeout", timeout or DEFAULT_TIMEOUT,
        "--model", model or DEFAULT_MODEL,
        "-p", prompt,
    ], ctx=ctx)

    if code != 0:
        detalhe = (raw[-500:] if raw else "sem saida").replace("\n", " ")
        raise GeminiUnavailable(
            "GEMINI_UNAVAILABLE: agy saiu com codigo %d: %s" % (code, detalhe))
    if not clean or QUOTA.search(clean):
        tail = raw[-300:] if raw else "sem saida (possivel quota/non-TTY)"
        raise GeminiUnavailable("GEMINI_UNAVAILABLE: " + tail.replace("\n", " "))
    guard = _format_warnings(warns, os.getcwd())
    return raw + ("\n" + guard if guard else "")


@mcp.tool()
async def gemini_models(ctx: Context = None) -> str:
    """Lista os nomes de modelo disponiveis no Antigravity CLI."""
    if ctx:
        try:
            await ctx.report_progress(
                progress=0, total=0,
                message="[agy] Consultando modelos disponiveis..."
            )
        except Exception:
            pass

    clean, _raw, _ = await _run_agy_streaming(["models"], ctx=ctx)
    return clean or "sem saida"


if __name__ == "__main__":
    mcp.run()   # transporte stdio
'@
    return $tpl.Replace("__MODEL_ID__", $ModelId)
}

# =============================================================================
# Conteudo do Bloco de Orquestracao -- CLAUDE.md (Camada 1)
# =============================================================================

function Get-OrquestraBlock {
    $body = @'
## Orquestracao Claude + Gemini (regra global)

### Papel do Claude nesta maquina: Planejador, Orquestrador e Auditor

O Claude opera com uma hierarquia estrita de responsabilidades. Respeite
esta ordem -- ela existe para maximizar a qualidade do codigo (auditoria
cruzada) e a economia de tokens (o orcamento do Gemini e maior):

| Prioridade | Papel | O que faz | Quando coda |
|:----------:|-------|-----------|-------------|
| 1 | **Planejador** | Analisa requisitos, arquiteta solucoes, toma decisoes de design | Nunca |
| 2 | **Orquestrador** | Decompoe tarefas, monta prompts autocontidos, delega ao `agy` | Nunca |
| 3 | **Auditor** | Revisa `git diff`, valida contratos, corrige desvios pontuais | Correcoes cirurgicas pos-auditoria |
| 4 | **Executor (fallback)** | Assume a codificacao quando o `agy` esta indisponivel | So apos esgotar tentativas de delegacao |

### Regra cardinal: DELEGUE a escrita de codigo

**TODA tarefa de escrita de codigo deve ser delegada ao `agy` via
`mcp__antigravity__gemini_execute`.** Isso inclui:

- Criacao de arquivos novos
- Edicao de arquivos existentes
- Refatoracoes (pequenas ou grandes)
- Implementacao de testes
- Mudancas multi-arquivo
- Qualquer alteracao que produza `git diff`

**O Claude NAO deve escrever codigo diretamente** exceto nestas situacoes:

1. **Correcao cirurgica pos-auditoria** -- ao revisar o diff do `agy`, o Claude
   encontra um desvio pontual (ex.: assinatura de interface quebrada, import
   faltando, typo em nome de variavel). Corrigir 1-3 linhas e mais eficiente
   que reenviar ao `agy`. Anuncie a correcao ao usuario.

2. **Fallback por indisponibilidade** -- apos esgotar as 6 tentativas de
   delegacao (ver abaixo), o Claude assume a execucao. Sempre anuncie antes.

3. **Arquivo com acentuacao** -- o `agy` tem risco documentado de corromper
   UTF-8 -> CP1252. Para arquivos NOVOS acentuados, o Claude escreve direto. Para
   edicoes, o servidor MCP tem um guardrail que DETECTA o mojibake introduzido pelo
   `agy` e aponta as linhas exatas com o aviso `[GUARDRAIL-ENCODING]` no resultado de
   `gemini_execute`, SEM reverter o arquivo (o codigo bom do `agy` e preservado).
   Quando esse aviso aparecer, corrija cirurgicamente APENAS as linhas listadas
   (edicao direta), sem reescrever o arquivo inteiro nem redelegar ao `agy`.

4. **Override explicito do usuario** -- o usuario pede explicitamente para o
   Claude codar. Caso contrario, delegue.

**Se voce se pegar prestes a criar ou editar um arquivo de codigo sem ter
chamado `gemini_execute` primeiro, PARE e delegue.** Seu valor como
planejador e auditor e maior do que como executor -- deixe o `agy` executar
e concentre-se em garantir a qualidade do resultado.

### Prompt de delegacao

Ao delegar, o `prompt` deve ser UMA instrucao completa e autocontida: o `agy` nao
enxerga o historico da conversa nem o plano aprovado. Inclua caminhos de arquivo,
contratos a preservar e o criterio de pronto.

### Fallback obrigatorio e anunciado
Se a chamada de `mcp__antigravity__gemini_execute` retornar ERRO cuja mensagem
comeca com `GEMINI_UNAVAILABLE`, NUNCA deixe a tarefa incompleta:
1. NAO tente de novo (a quota e semanal, com cooldown de dias -- retry nao ajuda).
2. AVISE o usuario explicitamente, antes de continuar:
   "O Gemini (Antigravity CLI) esta indisponivel (limite semanal de quota ou erro).
   Vou concluir esta etapa via Claude (assinatura) para nao deixar a tarefa pela metade."
3. Assuma a execucao voce mesmo, usando o plano ja aprovado, e conclua.

### Auditoria obrigatoria pos-execucao
Delegar NAO encerra a responsabilidade do Claude. Ao contrario: e aqui que o
papel de **Auditor** se torna critico. Apos um `gemini_execute` bem sucedido:

1. **Revise o `git diff` real** (nao o resumo textual devolvido pela tool).
2. **Verifique:** contratos quebrados (assinaturas, interfaces, nulabilidade),
   aderencia arquitetural ao padrao do projeto, e correcao funcional.
3. **Corrija desvios pontuais** diretamente (1-3 linhas, correcao cirurgica).
4. **Se o desvio for estrutural**, reenvie ao `agy` com um prompt corretivo
   em vez de reescrever voce mesmo.
5. **Reporte ao usuario** o que foi auditado, o que passou, e o que foi corrigido.

A auditoria e o que transforma a delegacao em verificacao cruzada: o `agy`
executa sem vicio de confirmacao do planejador, e o Claude valida sem o
vicio de execucao do implementador. Dois modelos, duas perspectivas, um
resultado mais confiavel.

Esta regra e global. Um projeto so a ignora se o CLAUDE.md do proprio projeto
disser explicitamente o contrario.
'@
    return ($MarkBegin + "`r`n" + $body + "`r`n" + $MarkEnd)
}

# =============================================================================
# Conteudo do Subagente (Camada 1 -- opcional)
# =============================================================================

function Get-AgentContent {
    @'
---
name: gemini-executor
description: >-
  Executor pesado. Aplica mudancas de codigo, refatoracoes extensas e edicoes
  multi-arquivo DEPOIS que o plano estiver aprovado. NAO planeja -- apenas
  delega ao Antigravity CLI via MCP.
tools: mcp__antigravity__gemini_execute
---

Voce delega a execucao ao Antigravity CLI atraves da ferramenta MCP e devolve o
resultado ao Claude orquestrador. Voce NUNCA faz a tarefa voce mesmo.

Procedimento:
1. Traduza o pedido em UMA instrucao de execucao concreta, completa e autocontida
   (caminhos de arquivo, contratos a preservar, criterio de pronto).
2. Chame `mcp__antigravity__gemini_execute` com essa instrucao.
3. Interprete o resultado:
   - Se a chamada RETORNAR ERRO com `GEMINI_UNAVAILABLE`: nao tente de novo, nao
     improvise. Responda ao Claude com `GEMINI_UNAVAILABLE: <motivo>`.
   - Caso contrario: devolva a saida verbatim, sem reescrever.

Regras:
- Nunca execute a logica da tarefa por conta propria.
- Uma tentativa por chamada. Sem retries (quota semanal tem cooldown longo).
'@
}

# =============================================================================
# Conteudo do GEMINI.md (Camada 2)
# =============================================================================

function Get-GeminiMdContent {
    @"
# Regras Globais -- Antigravity

## Estrategia de Modelos e Orquestracao de Fallback

### Cadeia de prioridade de modelos (do mais capaz ao mais leve)

Ao executar tarefas, respeite a seguinte ordem de preferencia de modelos.
Todos os modelos abaixo estao disponiveis na assinatura Google AI Pro e possuem
**cotas independentes** -- esgotar um nao afeta os outros.

| Prioridade | Modelo                           | Uso ideal                                      |
|:----------:|----------------------------------|-------------------------------------------------|
| 1          | Gemini 3.1 Pro (High)            | Execucao pesada, refatoracoes extensas, multi-arquivo |
| 2          | Claude Opus 4.6 (Thinking)       | Raciocinio profundo, arquitetura, decisoes complexas |
| 3          | Claude Sonnet 4.6 (Thinking)     | Raciocinio intermediario quando Opus esgotar     |
| 4          | Gemini 3.5 Flash (High)          | Tarefas rapidas, pesquisas, geracao leve         |
| 5          | Gemini 3.5 Flash (Medium)        | Ultimo recurso, cota mais generosa               |

### Deteccao proativa de limite de quota

Ao receber QUALQUER sinal de limite de quota, rate limit ou indisponibilidade
de modelo -- incluindo, mas nao limitado a:

- Mensagens com: ``quota``, ``rate limit``, ``429``, ``resource exhausted``, ``cooldown``,
  ``try again``, ``limit reached``, ``unavailable``, ``capacity``
- Respostas vazias ou degradadas inesperadamente
- Erros de timeout repetidos

Siga IMEDIATAMENTE este procedimento:

1. **NAO tente de novo** no mesmo modelo (a quota pode ser semanal com cooldown
   de dias -- retry e desperdicio).
2. **AVISE o usuario** de forma clara e visivel ANTES de qualquer outra acao:

   > **Limite de modelo atingido**
   > O modelo **[nome do modelo atual]** atingiu o limite de quota.
   > **Recomendo trocar para: [proximo modelo da cadeia]** via Model Selection
   > nas configuracoes, para continuar sem interrupcao.
   > Modelos restantes na cadeia: [listar os que ainda nao foram esgotados]

3. **NUNCA deixe a tarefa incompleta.** Se o usuario nao trocar de modelo,
   continue trabalhando com o modelo atual da melhor forma possivel, informando
   que a qualidade ou velocidade pode estar degradada.

### Delegacao inteligente a subagentes

Ao invocar subagentes, utilize o parametro ``Model`` de forma estrategica para
preservar a cota do modelo principal:

- **Pesquisa e leitura de arquivos**: use ``Model="flash"`` (Gemini Flash)
- **Tarefas simples e mecanicas**: use ``Model="flash_lite"``
- **Tarefas complexas que exigem raciocinio**: use ``Model="inherit"`` ou ``Model="pro"``
- **Multiplos subagentes em paralelo**: prefira ``Model="flash"`` para todos,
  a menos que a tarefa exija raciocinio profundo

Isso preserva a cota dos modelos mais capazes (Gemini Pro, Claude Opus) para
as tarefas onde fazem diferenca real.

### Resumo da estrategia

- **Maximizar o uso de cada modelo** antes de recomendar a troca
- **Os modelos mais capazes primeiro** (Gemini Pro e Claude Opus)
- **Aviso proativo** assim que detectar qualquer sinal de limite
- **Nunca parar** -- sempre sugerir o proximo modelo da cadeia
- **Subagentes economicos** -- usar modelos leves para tarefas que nao exigem
  raciocinio profundo

### Override por projeto

Esta regra e global e se aplica a todos os workspaces. Um projeto especifico
pode sobrescreve-la declarando regras diferentes em seu proprio
``.agents/rules/`` ou ``GEMINI.md`` local.
"@
}

# =============================================================================
# Instalacao -- Camada 1 (Claude Code)
# =============================================================================

function Install-McpServer {
    Write-Step "Camada 1: Servidor MCP"
    New-Item -ItemType Directory -Force -Path $McpDir | Out-Null
    if ($DryRun) {
        Write-Dry "Escreveria servidor MCP em $ServerFile"
    } else {
        Backup-File $ServerFile | Out-Null
        Write-Utf8NoBom -Path $ServerFile -Content (Get-ServerContent -ModelId $Model)
        Write-Ok "Servidor MCP escrito: $ServerFile (modelo padrao: $Model)"
    }
}

function Register-McpServer {
    Write-Step "Camada 1: Registro MCP no Claude Code"
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Warn "claude ausente -- registre manualmente depois:"
        Write-Warn "  claude mcp add --scope user $ServerName -- python '$ServerFile'"
        return
    }

    if ($DryRun) {
        Write-Dry "Registraria servidor '$ServerName' no escopo de usuario"
        return
    }

    # Idempotencia: remove registro anterior
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    & claude mcp remove --scope user $ServerName *> $null
    $ErrorActionPreference = $prev

    & claude mcp add --scope user $ServerName -- python $ServerFile
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Servidor '$ServerName' registrado no escopo de usuario (vale em todos os projetos)"
    } else {
        Write-Warn "Falha ao registrar (exit $LASTEXITCODE). Registre manualmente:"
        Write-Warn "  claude mcp add --scope user $ServerName -- python '$ServerFile'"
    }
}

function Install-ClaudeMemory {
    Write-Step "Camada 1: Regra global de orquestracao (CLAUDE.md)"
    New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
    $block = Get-OrquestraBlock

    if ($DryRun) {
        Write-Dry "Escreveria/atualizaria bloco de orquestracao em $ClaudeMemory"
        return
    }

    if ((Test-Path $ClaudeMemory) -and (Select-String -Path $ClaudeMemory -SimpleMatch $MarkBegin -Quiet)) {
        [void](Backup-File $ClaudeMemory)
        $text = [System.IO.File]::ReadAllText($ClaudeMemory)
        $pattern = [regex]::Escape($MarkBegin) + "[\s\S]*?" + [regex]::Escape($MarkEnd)
        $text = [regex]::Replace($text, $pattern,
                    [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1)
        Write-Utf8NoBom -Path $ClaudeMemory -Content $text
        Write-Ok "Bloco de orquestracao ATUALIZADO em $ClaudeMemory (backup criado)"
    } else {
        $prefix = ""
        if (Test-Path $ClaudeMemory) {
            [void](Backup-File $ClaudeMemory)
            $prefix = ([System.IO.File]::ReadAllText($ClaudeMemory)).TrimEnd() + "`r`n`r`n"
            Write-Warn "CLAUDE.md existente sem marcadores -- bloco sera ANEXADO ao final."
        }
        Write-Utf8NoBom -Path $ClaudeMemory -Content ($prefix + $block + "`r`n")
        Write-Ok "Bloco de orquestracao gravado em $ClaudeMemory"
    }
}

function Install-Subagent {
    Write-Step "Camada 1: Subagente executor (opcional)"
    New-Item -ItemType Directory -Force -Path $AgentsDir | Out-Null
    if ($DryRun) {
        Write-Dry "Escreveria subagente em $AgentFile"
    } else {
        Backup-File $AgentFile | Out-Null
        Write-Utf8NoBom -Path $AgentFile -Content (Get-AgentContent)
        Write-Ok "Subagente escrito: $AgentFile"
    }
}

# =============================================================================
# Instalacao -- Camada 2 (Antigravity CLI)
# =============================================================================

function Install-GeminiMd {
    Write-Step "Camada 2: Regra global de fallback (GEMINI.md)"

    if ($DryRun) {
        Write-Dry "Escreveria/atualizaria GEMINI.md em $GeminiMdPath"
        return
    }

    New-Item -ItemType Directory -Force -Path $GeminiDir | Out-Null

    if (Test-Path $GeminiMdPath) {
        Backup-File $GeminiMdPath | Out-Null
        Write-Info "Backup criado de GEMINI.md existente"
    }

    Write-Utf8Bom -Path $GeminiMdPath -Content (Get-GeminiMdContent)
    Write-Ok "GEMINI.md gravado em $GeminiMdPath"
}

function Install-SettingsJson {
    Write-Step "Camada 2: Modelo padrao no settings.json"

    if (-not (Test-Path $SettingsPath)) {
        Write-Warn "settings.json nao encontrado em $SettingsPath"
        Write-Info "Verifique se o Antigravity CLI foi executado ao menos uma vez."
        Write-Info "Rode 'agy' para inicializar e depois execute este script novamente."
        return
    }

    if ($DryRun) {
        Write-Dry "Atualizaria modelo padrao em $SettingsPath"
        return
    }

    $settingsRaw = Get-Content $SettingsPath -Raw -Encoding UTF8
    $settings = $settingsRaw | ConvertFrom-Json
    $currentModel = $settings.model

    Write-Info "Modelo atual: $currentModel"
    Write-Info "Modelo alvo:  $Model"

    if ($currentModel -eq $Model) {
        Write-Ok "Modelo ja esta configurado corretamente"
    } else {
        Backup-File $SettingsPath | Out-Null
        $settings.model = $Model
        $settingsJson = $settings | ConvertTo-Json -Depth 10
        Write-Utf8Bom -Path $SettingsPath -Content $settingsJson
        Write-Ok "Modelo atualizado: '$currentModel' -> '$Model'"
    }
}

# =============================================================================
# Smoke Test
# =============================================================================

function Invoke-SmokeTest {
    Write-Step "Smoke test"

    if ($DryRun) {
        Write-Dry "Executaria smoke test do servidor MCP"
        return
    }

    $py = Get-PythonCommand
    if (-not $py) { Write-Warn "Python ausente -- pulando."; return }

    # 1) O servidor importa?
    $importCheck = @"
import importlib.util, sys
spec = importlib.util.spec_from_file_location('antigravity_mcp', r'$ServerFile')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print('IMPORT_OK')
"@
    $out = & $py.Source -c $importCheck
    if ($LASTEXITCODE -eq 0 -and ($out -join '') -match 'IMPORT_OK') {
        Write-Ok "Servidor importa corretamente (SDK mcp presente)"
    } else {
        Write-Err "Servidor NAO importa -- o Claude Code mostrara o MCP como 'failed'."
        Write-Err "  Saida: $($out -join ' ')"
        return
    }

    # 2) O PTY funciona? (agy models nao consome quota)
    if (-not (Get-Command agy -ErrorAction SilentlyContinue)) {
        Write-Warn "agy ausente -- pulando o teste de PTY."
        return
    }
    Write-Info "Testando o PTY com 'agy models' (nao consome quota de geracao)..."
    $ptyCheck = @"
import importlib.util, asyncio
spec = importlib.util.spec_from_file_location('antigravity_mcp', r'$ServerFile')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
out, _raw, _ = asyncio.run(m._run_agy_streaming(['models']))
print('PTY_EMPTY' if not out else 'PTY_OK: ' + out[:160].replace('\n', ' '))
"@
    $out2 = & $py.Source -c $ptyCheck
    $joined = ($out2 -join ' ')
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Teste de PTY falhou (exit $LASTEXITCODE): $joined"
    } elseif ($joined -match 'PTY_EMPTY') {
        Write-Warn "PTY devolveu saida VAZIA -- e o sintoma do bug #76 nao contornado."
        Write-Warn "  Rode 'agy models' num terminal real. Se funcionar la, considere o WSL."
    } else {
        Write-Ok "PTY capturou a saida do agy: $joined"
    }
}

# =============================================================================
# Modo Check
# =============================================================================

function Invoke-Check {
    Write-Banner
    $result = Test-AllPrereqs

    Write-Step "Artefatos da Camada 1 (Claude Code)"

    if (Test-Path $ServerFile) { Write-Ok "Servidor MCP presente: $ServerFile" }
    else { Write-Warn "Servidor MCP ausente: $ServerFile" }

    if ((Test-Path $ClaudeMemory) -and (Select-String -Path $ClaudeMemory -SimpleMatch $MarkBegin -Quiet)) {
        Write-Ok "Regra global de orquestracao presente em $ClaudeMemory"
    } else { Write-Warn "Regra global de orquestracao ausente em $ClaudeMemory" }

    if (Get-Command claude -ErrorAction SilentlyContinue) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $list = & claude mcp list 2>$null
        $ErrorActionPreference = $prev
        if (($list -join "`n") -match [regex]::Escape($ServerName)) {
            Write-Ok "Servidor '$ServerName' registrado no Claude Code"
        } else {
            Write-Warn "Servidor '$ServerName' NAO aparece em 'claude mcp list'"
        }
    }

    if (Test-Path $AgentFile) {
        if (Select-String -Path $AgentFile -SimpleMatch "mcp__antigravity__gemini_execute" -Quiet) {
            Write-Ok "Subagente presente e configurado para tool MCP"
        } else {
            Write-Warn "Subagente presente mas nao configurado para tool MCP"
        }
    } else { Write-Info "Subagente ausente (esperado sem -KeepSubagent)" }

    Write-Step "Artefatos da Camada 2 (Antigravity)"

    if (Test-Path $GeminiMdPath) {
        $mdContent = Get-Content $GeminiMdPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($mdContent -and ($mdContent -match "Cadeia de prioridade")) {
            Write-Ok "GEMINI.md com regras de fallback presente em $GeminiMdPath"
        } else {
            Write-Warn "GEMINI.md existe mas nao contem regras de fallback"
        }
    } else { Write-Warn "GEMINI.md ausente: $GeminiMdPath" }

    if (Test-Path $SettingsPath) {
        $settings = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Ok "settings.json: modelo = $($settings.model)"
    } else { Write-Warn "settings.json ausente: $SettingsPath" }

    Write-Step "Resumo"
    if ($result.Issues.Count -gt 0) {
        Write-Err "$($result.Issues.Count) problema(s) bloqueante(s):"
        foreach ($i in $result.Issues) { Write-Err "  - $i" }
    }
    if ($result.Warnings.Count -gt 0) {
        Write-Warn "$($result.Warnings.Count) aviso(s):"
        foreach ($w in $result.Warnings) { Write-Warn "  - $w" }
    }
    if ($result.Issues.Count -eq 0 -and $result.Warnings.Count -eq 0) {
        Write-Ok "Tudo OK!"
    }

    Write-Host ""
    Write-Info "Confirme dentro de um projeto: claude -> /mcp e /memory"
}

# =============================================================================
# Modo Uninstall
# =============================================================================

function Invoke-Uninstall {
    Write-Banner
    Write-Step "Desinstalando artefatos"

    # Camada 1
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        & claude mcp remove --scope user $ServerName *> $null
        $ErrorActionPreference = $prev
        Write-Ok "Registro MCP '$ServerName' removido"
    }

    foreach ($f in @($ServerFile, $AgentFile)) {
        if (Test-Path $f) {
            Backup-File $f | Out-Null
            Remove-Item $f -Force
            Write-Ok "Removido (com backup): $f"
        } else { Write-Info "Ja ausente: $f" }
    }

    if ((Test-Path $ClaudeMemory) -and (Select-String -Path $ClaudeMemory -SimpleMatch $MarkBegin -Quiet)) {
        [void](Backup-File $ClaudeMemory)
        $text = [System.IO.File]::ReadAllText($ClaudeMemory)
        $pattern = "\r?\n?" + [regex]::Escape($MarkBegin) + "[\s\S]*?" + [regex]::Escape($MarkEnd) + "\r?\n?"
        $text = [regex]::Replace($text, $pattern, "`r`n", 1)
        Write-Utf8NoBom -Path $ClaudeMemory -Content $text
        Write-Ok "Bloco de orquestracao removido de $ClaudeMemory (backup criado)"
    }

    # Camada 2
    if (Test-Path $GeminiMdPath) {
        Backup-File $GeminiMdPath | Out-Null
        Remove-Item $GeminiMdPath -Force
        Write-Ok "Removido (com backup): $GeminiMdPath"
    }

    Write-Warn "Dependencias Python (mcp, pywinpty) NAO foram desinstaladas."
    Write-Warn "settings.json NAO foi alterado (o modelo padrao permanece)."
    Write-Info "Use -Restore para reverter a partir dos backups."
}

# =============================================================================
# Main
# =============================================================================

Write-Banner

if ($Check)     { Invoke-Check;     exit 0 }
if ($Uninstall) { Invoke-Uninstall; exit 0 }

# --- Confirmacao ---
if (-not $Force -and -not $DryRun) {
    Write-Host "  Este script ira:"
    Write-Host "    1. Verificar e instalar ferramentas ausentes (Python, Node, Claude Code, agy)" -ForegroundColor White
    Write-Host "    2. Instalar dependencias Python (mcp, pywinpty)" -ForegroundColor White
    Write-Host "    3. Criar o servidor MCP e registrar no Claude Code" -ForegroundColor White
    Write-Host "    4. Configurar regras de orquestracao (CLAUDE.md)" -ForegroundColor White
    Write-Host "    5. Configurar fallback de modelos (GEMINI.md)" -ForegroundColor White
    Write-Host "    6. Atualizar modelo padrao em settings.json" -ForegroundColor White
    Write-Host "    7. Executar smoke test" -ForegroundColor White
    Write-Host ""
    Write-Host "  Modelo padrao: $Model" -ForegroundColor Cyan
    Write-Host "  Backups serao criados automaticamente antes de qualquer alteracao." -ForegroundColor Gray
    Write-Host ""
    $confirm = Read-Host "  Continuar? (S/n)"
    if ($confirm -and $confirm -notin @("s", "S", "sim", "y", "yes", "")) {
        Write-Host "`n  Cancelado pelo usuario.`n" -ForegroundColor Yellow
        exit 0
    }
}

if ($DryRun) {
    Write-Host "  [DRY RUN] Nenhuma alteracao sera aplicada.`n" -ForegroundColor Magenta
}

# --- Pre-requisitos ---
$prereqs = Test-AllPrereqs

if ($prereqs.Issues.Count -gt 0 -and -not $SkipInstall) {
    if (-not $DryRun) {
        Install-MissingTools
        # Re-verifica
        $prereqs = Test-AllPrereqs
        if ($prereqs.Issues.Count -gt 0) {
            Write-Err "Pre-requisitos bloqueantes ainda presentes apos tentativa de instalacao."
            Write-Err "Corrija manualmente e rode novamente."
            exit 1
        }
    }
} elseif ($prereqs.Issues.Count -gt 0 -and $SkipInstall) {
    Write-Err "Pre-requisitos bloqueantes falharam e -SkipInstall ativo."
    exit 1
}

# --- Instalar ferramentas que sao warnings (nao bloqueantes) ---
if (-not $SkipInstall) {
    Install-MissingTools
}

# --- Camada 1: Claude Code ---
Install-McpServer
Install-ClaudeMemory
if ($KeepSubagent) { Install-Subagent }
Register-McpServer

# --- Camada 2: Antigravity ---
Install-GeminiMd
Install-SettingsJson

# --- Smoke test ---
Invoke-SmokeTest

# --- Resultado final ---
Write-Host ""
Write-Host "  +=================================================================+" -ForegroundColor Green
if ($DryRun) {
    Write-Host "  |   DRY RUN concluido -- nenhuma alteracao foi aplicada           |" -ForegroundColor Magenta
    Write-Host "  |   Execute sem -DryRun para aplicar.                             |" -ForegroundColor Magenta
} else {
    Write-Host "  |   Setup concluido com sucesso!                                  |" -ForegroundColor Green
    Write-Host "  |                                                                 |" -ForegroundColor Green
    Write-Host "  |   Cadeia de fallback:                                           |" -ForegroundColor Green
    Write-Host "  |     1. Gemini 3.1 Pro (High)       -- execucao pesada           |" -ForegroundColor White
    Write-Host "  |     2. Claude Opus 4.6 (Thinking)  -- raciocinio profundo       |" -ForegroundColor White
    Write-Host "  |     3. Claude Sonnet 4.6 (Thinking) -- intermediario            |" -ForegroundColor White
    Write-Host "  |     4. Gemini 3.5 Flash (High)     -- tarefas rapidas           |" -ForegroundColor White
    Write-Host "  |     5. Gemini 3.5 Flash (Medium)   -- ultimo recurso            |" -ForegroundColor White
}
Write-Host "  +=================================================================+" -ForegroundColor Green
Write-Host ""

if (-not $DryRun) {
    Write-Host "  Proximos passos:" -ForegroundColor Yellow
    Write-Host "    1. Abra um terminal NOVO (para PATH atualizado)" -ForegroundColor White
    Write-Host "    2. Se ainda nao autenticou: 'claude' e 'agy' (cada um abre OAuth)" -ForegroundColor White
    Write-Host "    3. Dentro de um projeto: claude -> /mcp (antigravity connected)" -ForegroundColor White
    Write-Host "    4. Verifique: claude -> /memory (CLAUDE.md carregado)" -ForegroundColor White
    Write-Host "    5. Teste: peca algo que envolva planejar + executar" -ForegroundColor White
    Write-Host ""
    Write-Host "  Comandos uteis:" -ForegroundColor Gray
    Write-Host "    .\setup-ambiente-completo.ps1 -Check      Verificar estado" -ForegroundColor Gray
    Write-Host "    .\setup-ambiente-completo.ps1 -Restore    Restaurar backups" -ForegroundColor Gray
    Write-Host "    .\setup-ambiente-completo.ps1 -Uninstall  Remover artefatos" -ForegroundColor Gray
    Write-Host "    agy models                                Ver modelos disponiveis" -ForegroundColor Gray
}
Write-Host ""
