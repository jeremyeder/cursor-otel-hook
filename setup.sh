#!/bin/bash
# Setup script for cursor-otel-hook (TAILWIND fork)
#
# Installs the hook, configures it to send traces directly to MLflow
# on the jeder-evalhub ROSA cluster. Requires:
#   - oc login to jeder-evalhub cluster
#   - Python 3.8+ (or uv)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

MLFLOW_ENDPOINT="https://mlflow-direct.apps.rosa.jeder-evalhub.uqi3.p3.openshiftapps.com/v1/traces"
MLFLOW_WORKSPACE="evalhub"
MLFLOW_EXPERIMENT_ID="11"
SERVICE_NAME="tailwind-cursor"

echo "========================================="
echo "TAILWIND Cursor OTEL Hook Setup"
echo "========================================="
echo ""

# Check prerequisites
if ! command -v oc &> /dev/null; then
    echo -e "${RED}Error: oc CLI not found${NC}"
    exit 1
fi

if ! oc whoami &> /dev/null 2>&1; then
    echo -e "${RED}Error: not logged in to OpenShift. Run: oc login${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} OpenShift: $(oc whoami)"

# Prefer uv, fall back to pip
if command -v uv &> /dev/null; then
    PKG_MGR="uv"
    echo -e "${GREEN}✓${NC} Using uv"
else
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Error: Python 3 not found (install uv or python3)${NC}"
        exit 1
    fi
    PKG_MGR="pip"
    echo -e "${GREEN}✓${NC} Using pip (python $(python3 --version | cut -d' ' -f2))"
fi

# Install into venv
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

if [ "$PKG_MGR" = "uv" ]; then
    uv venv --quiet 2>/dev/null || true
    uv pip install -e . --quiet
    VENV_PYTHON="$PROJECT_DIR/.venv/bin/python"
else
    if [ ! -d "venv" ]; then
        python3 -m venv venv
    fi
    source venv/bin/activate
    pip install --upgrade pip -q
    pip install -e . -q
    VENV_PYTHON="$PROJECT_DIR/venv/bin/python"
fi
echo -e "${GREEN}✓${NC} Package installed"

# Create hooks directory
CURSOR_HOOKS_DIR="$HOME/.cursor/hooks"
mkdir -p "$CURSOR_HOOKS_DIR"

# Create config (no auth token — wrapper injects it at runtime)
CONFIG_FILE="$CURSOR_HOOKS_DIR/otel_config.json"
cat > "$CONFIG_FILE" << EOF
{
  "OTEL_EXPORTER_OTLP_ENDPOINT": "$MLFLOW_ENDPOINT",
  "OTEL_SERVICE_NAME": "$SERVICE_NAME",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_INSECURE": "false",
  "OTEL_EXPORTER_OTLP_HEADERS": {
    "x-mlflow-workspace": "$MLFLOW_WORKSPACE",
    "x-mlflow-experiment-id": "$MLFLOW_EXPERIMENT_ID"
  },
  "CURSOR_OTEL_MASK_PROMPTS": "true"
}
EOF
echo -e "${GREEN}✓${NC} Config: $CONFIG_FILE"

# Create wrapper script that injects OC token at runtime
WRAPPER_SCRIPT="$CURSOR_HOOKS_DIR/otel_hook.sh"
cat > "$WRAPPER_SCRIPT" << WRAPPER
#!/bin/bash
# TAILWIND Cursor OTEL Hook Wrapper
# Injects OC bearer token at runtime so traces authenticate to MLflow

# Get fresh OC token (cached by oc CLI, ~24h TTL)
OC_TOKEN=\$(oc whoami -t 2>/dev/null)
if [ -z "\$OC_TOKEN" ]; then
    # Not logged in — skip telemetry silently, don't block Cursor
    exec cat > /dev/null
fi

export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer \$OC_TOKEN,x-mlflow-workspace=$MLFLOW_WORKSPACE,x-mlflow-experiment-id=$MLFLOW_EXPERIMENT_ID"

exec "$VENV_PYTHON" -m cursor_otel_hook --config "$CONFIG_FILE" "\$@"
WRAPPER

chmod +x "$WRAPPER_SCRIPT"
echo -e "${GREEN}✓${NC} Wrapper: $WRAPPER_SCRIPT"

# Create hooks.json (or warn if exists)
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
    echo -e "${YELLOW}!${NC} hooks.json already exists — merge manually if needed"
    echo "   $HOOKS_CONFIG"
fi

echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "Restart Cursor to activate. Traces go to:"
echo "  https://mlflow-direct.apps.rosa.jeder-evalhub.uqi3.p3.openshiftapps.com/#/experiments/$MLFLOW_EXPERIMENT_ID"
echo ""
echo "Test manually:"
echo "  echo '{\"hook_event_name\":\"test\"}' | $WRAPPER_SCRIPT"
echo ""
echo "View logs:"
echo "  tail -f ~/.cursor/hooks/cursor_otel_hook.log"
