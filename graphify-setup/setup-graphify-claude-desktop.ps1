# One-shot: install graphify, build a graph of a folder, and register it in Claude Desktop.
# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File setup-graphify-claude-desktop.ps1 C:\path\to\project
param([string]$Project, [string]$Name)
$ErrorActionPreference = "Stop"

if (-not $Project) { $Project = Read-Host "Folder to graph (full path)" }
$Project = $Project.Trim('"').TrimEnd('\')
if (-not (Test-Path $Project -PathType Container)) { throw "Not a folder: $Project" }
$Project = (Resolve-Path $Project).Path
if (-not $Name) { $Name = "graphify-" + ((Split-Path $Project -Leaf) -replace '[^A-Za-z0-9_-]', '-') }

# 1. uv (Python tool installer)
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
  Write-Host "==> Installing uv"
  powershell -ExecutionPolicy Bypass -c "irm https://astral.sh/uv/install.ps1 | iex"
  $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
}

# 2. graphify with the MCP server
Write-Host "==> Installing graphify"
uv tool install --force --python 3.12 "graphifyy[mcp]"
if ($LASTEXITCODE -ne 0) { throw "graphify install failed" }
$BinDir = (uv tool dir --bin).Trim()
$env:Path = "$BinDir;$env:Path"
$McpBin = Join-Path $BinDir "graphify-mcp.exe"
if (-not (Test-Path $McpBin)) { throw "graphify-mcp not found in $BinDir" }

# 3. Build the graph (code is parsed locally; no API key needed)
Write-Host "==> Building graph for $Project"
$haveLlm = $env:ANTHROPIC_API_KEY -or $env:OPENAI_API_KEY -or $env:GEMINI_API_KEY -or (Get-Command claude -ErrorAction SilentlyContinue)
if ($haveLlm) { graphify extract "$Project"; if ($LASTEXITCODE -ne 0) { graphify extract "$Project" --code-only } }
else { graphify extract "$Project" --code-only }
$Graph = Join-Path $Project "graphify-out\graph.json"
if (-not (Test-Path $Graph)) { throw "Graph was not created at $Graph" }

# 4. Register with Claude Desktop (merge, keep existing servers)
$Cfg = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"
# Microsoft Store install of Claude keeps its config in a packaged folder
$store = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($store) {
  $storeCfg = Join-Path $store.FullName "LocalCache\Roaming\Claude\claude_desktop_config.json"
  if (Test-Path (Split-Path $storeCfg)) { $Cfg = $storeCfg }
}
New-Item -ItemType Directory -Force -Path (Split-Path $Cfg) | Out-Null
if (Test-Path $Cfg) { Copy-Item $Cfg "$Cfg.bak.$([DateTimeOffset]::Now.ToUnixTimeSeconds())" }
uv run --no-project --python 3.12 python -c @"
import json, os, sys
cfg, name, cmd, graph = sys.argv[1:]
data = {}
if os.path.exists(cfg) and os.path.getsize(cfg):
    with open(cfg, encoding='utf-8-sig') as f:
        data = json.load(f)
data.setdefault('mcpServers', {})[name] = {'command': cmd, 'args': [graph]}
with open(cfg, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
print(f"==> Added MCP server '{name}' to {cfg}")
"@ "$Cfg" "$Name" "$McpBin" "$Graph"
if ($LASTEXITCODE -ne 0) { throw "Could not update $Cfg" }

Write-Host ""
Write-Host "Done. Fully quit Claude Desktop (right-click tray icon > Quit) and reopen it."
Write-Host "Then ask: `"Using $Name, what are the main components of this project?`""
