#!/usr/bin/env bash
# One-shot: install graphify, build a graph of a folder, and register it in Claude Desktop.
# Usage: bash setup-graphify-claude-desktop.sh /path/to/your/project [server-name]
set -euo pipefail

PROJECT="${1:-}"
if [ -z "$PROJECT" ]; then
  read -r -p "Folder to graph (drag it here, then Enter): " PROJECT
fi
PROJECT="${PROJECT%/}"; PROJECT="${PROJECT/#\~/$HOME}"
[ -d "$PROJECT" ] || { echo "Not a folder: $PROJECT"; exit 1; }
PROJECT="$(cd "$PROJECT" && pwd)"
NAME="${2:-graphify-$(basename "$PROJECT" | tr -c 'A-Za-z0-9_-' '-' | sed 's/-*$//')}"

# 1. uv (Python tool installer)
if ! command -v uv >/dev/null 2>&1; then
  echo "==> Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# 2. graphify with the MCP server
echo "==> Installing graphify"
uv tool install --force --python 3.12 "graphifyy[mcp]"
BIN_DIR="$(uv tool dir --bin)"
export PATH="$BIN_DIR:$PATH"
MCP_BIN="$BIN_DIR/graphify-mcp"
[ -x "$MCP_BIN" ] || { echo "graphify-mcp not found in $BIN_DIR"; exit 1; }

# 3. Build the graph (code is parsed locally; no API key needed)
echo "==> Building graph for $PROJECT"
if [ -n "${ANTHROPIC_API_KEY:-}${OPENAI_API_KEY:-}${GEMINI_API_KEY:-}" ] || command -v claude >/dev/null 2>&1; then
  graphify extract "$PROJECT" || graphify extract "$PROJECT" --code-only
else
  graphify extract "$PROJECT" --code-only
fi
GRAPH="$PROJECT/graphify-out/graph.json"
[ -f "$GRAPH" ] || { echo "Graph was not created at $GRAPH"; exit 1; }

# 4. Register with Claude Desktop
case "$(uname -s)" in
  Darwin) CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
  *)      CFG="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json" ;;
esac
mkdir -p "$(dirname "$CFG")"
[ -f "$CFG" ] && cp "$CFG" "$CFG.bak.$(date +%s)"
uv run --no-project --python 3.12 python - "$CFG" "$NAME" "$MCP_BIN" "$GRAPH" <<'PY'
import json, os, sys
cfg, name, cmd, graph = sys.argv[1:]
data = {}
if os.path.exists(cfg) and os.path.getsize(cfg):
    with open(cfg) as f:
        data = json.load(f)
data.setdefault("mcpServers", {})[name] = {"command": cmd, "args": [graph]}
with open(cfg, "w") as f:
    json.dump(data, f, indent=2)
print(f"==> Added MCP server '{name}' to {cfg}")
PY

echo
echo "Done. Fully quit Claude Desktop (Cmd+Q) and reopen it."
echo "Then ask: \"Using $NAME, what are the main components of this project?\""
