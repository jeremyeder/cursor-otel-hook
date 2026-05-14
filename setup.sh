#!/bin/bash
# Setup cursor-otel-hook for TAILWIND Cursor users.
#
# Ships the SA token in the config file — no oc login required at runtime.
# All values configurable via env vars for automation.
#
# Required env vars:
#   MLFLOW_TRACKING_TOKEN  - ServiceAccount bearer token
#
# Optional env vars (with defaults):
#   MLFLOW_TRACKING_URI    - MLflow OTLP endpoint (default: jeder-evalhub)
#   MLFLOW_WORKSPACE       - MLflow workspace (default: evalhub)
#   MLFLOW_EXPERIMENT_ID   - Experiment ID (default: 11)
#   SERVICE_NAME           - OTEL service name (default: tailwind-cursor)
#   MASK_PROMPTS           - Mask prompt content (default: true)
#
# Usage:
#   MLFLOW_TRACKING_TOKEN="eyJ..." bash setup.sh
#   # or with all env vars already exported:
#   bash setup.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

MLFLOW_TRACKING_URI="${MLFLOW_TRACKING_URI:-https://mlflow-direct.apps.rosa.jeder-evalhub.uqi3.p3.openshiftapps.com}"
MLFLOW_WORKSPACE="${MLFLOW_WORKSPACE:-evalhub}"
MLFLOW_EXPERIMENT_ID="${MLFLOW_EXPERIMENT_ID:-11}"
SERVICE_NAME="${SERVICE_NAME:-tailwind-cursor}"
MASK_PROMPTS="${MASK_PROMPTS:-true}"

echo "========================================="
echo "TAILWIND Cursor OTEL Hook Setup"
echo "========================================="
echo ""

# Validate required token
if [ -z "${MLFLOW_TRACKING_TOKEN:-}" ]; then
    echo -e "${RED}Error: MLFLOW_TRACKING_TOKEN is required${NC}"
    echo ""
    echo "Get the token from the cluster:"
    echo "  oc get secret mlflow-claude-tracing-token -n evalhub -o jsonpath='{.data.token}' | base64 -d"
    echo ""
    echo "Or use the same token from your Claude Code settings:"
    echo "  jq -r '.env.MLFLOW_TRACKING_TOKEN // .environment.MLFLOW_TRACKING_TOKEN' .claude/settings.json"
    exit 1
fi
echo -e "${GREEN}✓${NC} Token provided (${#MLFLOW_TRACKING_TOKEN} chars)"

# Prefer uv, fall back to pip
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

if command -v uv &> /dev/null; then
    uv venv --quiet 2>/dev/null || true
    uv pip install -e . --quiet
    VENV_PYTHON="$PROJECT_DIR/.venv/bin/python"
    echo -e "${GREEN}✓${NC} Installed via uv"
else
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Error: python3 or uv required${NC}"
        exit 1
    fi
    [ ! -d "venv" ] && python3 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip -q && pip install -e . -q
    VENV_PYTHON="$PROJECT_DIR/venv/bin/python"
    echo -e "${GREEN}✓${NC} Installed via pip"
fi

# Create hooks directory
CURSOR_HOOKS_DIR="$HOME/.cursor/hooks"
mkdir -p "$CURSOR_HOOKS_DIR"

# Write config with SA token baked in
CONFIG_FILE="$CURSOR_HOOKS_DIR/otel_config.json"
cat > "$CONFIG_FILE" << EOF
{
  "OTEL_EXPORTER_OTLP_ENDPOINT": "$MLFLOW_TRACKING_URI",
  "OTEL_SERVICE_NAME": "$SERVICE_NAME",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_INSECURE": "false",
  "OTEL_EXPORTER_OTLP_HEADERS": {
    "Authorization": "Bearer $MLFLOW_TRACKING_TOKEN",
    "x-mlflow-workspace": "$MLFLOW_WORKSPACE",
    "x-mlflow-experiment-id": "$MLFLOW_EXPERIMENT_ID"
  },
  "CURSOR_OTEL_MASK_PROMPTS": "$MASK_PROMPTS"
}
EOF
echo -e "${GREEN}✓${NC} Config: $CONFIG_FILE"

# Write wrapper script (simple — no token injection needed)
WRAPPER_SCRIPT="$CURSOR_HOOKS_DIR/otel_hook.sh"
cat > "$WRAPPER_SCRIPT" << WRAPPER
#!/bin/bash
exec "$VENV_PYTHON" -m cursor_otel_hook --config "$CONFIG_FILE" "\$@"
WRAPPER
chmod +x "$WRAPPER_SCRIPT"
echo -e "${GREEN}✓${NC} Wrapper: $WRAPPER_SCRIPT"

# Write hooks.json (warn if exists)
HOOKS_CONFIG="$HOME/.cursor/hooks.json"
if [ ! -f "$HOOKS_CONFIG" ]; then
    cat > "$HOOKS_CONFIG" << EOF
{
  "version": 1,
  "hooks": {
    "sessionStart": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}],
    "sessionEnd": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}],
    "preToolUse": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}],
    "postToolUse": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}],
    "postToolUseFailure": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}],
    "afterShellExecution": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}],
    "afterMCPExecution": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}],
    "beforeReadFile": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}],
    "afterFileEdit": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}],
    "beforeSubmitPrompt": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}],
    "subagentStart": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}],
    "subagentStop": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}],
    "stop": [{"command": "$WRAPPER_SCRIPT", "timeout": 5}]
  }
}
EOF
    echo -e "${GREEN}✓${NC} Hooks: $HOOKS_CONFIG"
else
    echo -e "${YELLOW}!${NC} hooks.json exists — merge manually if needed: $HOOKS_CONFIG"
fi

echo ""
echo -e "${GREEN}Setup complete.${NC} Restart Cursor to activate."
echo ""
echo "  Endpoint:   $MLFLOW_TRACKING_URI"
echo "  Workspace:  $MLFLOW_WORKSPACE"
echo "  Experiment: $MLFLOW_EXPERIMENT_ID"
echo "  Masking:    $MASK_PROMPTS"
echo ""
echo "Runtime overrides via env vars (config.py merges them):"
echo "  OTEL_EXPORTER_OTLP_ENDPOINT   - point at a different MLflow"
echo "  OTEL_SERVICE_NAME              - change service name"
echo "  OTEL_EXPORTER_OTLP_HEADERS    - add/override auth headers"
echo ""
echo "Test:  echo '{\"hook_event_name\":\"test\"}' | $WRAPPER_SCRIPT"
echo "Logs:  tail -f ~/.cursor/hooks/cursor_otel_hook.log"
