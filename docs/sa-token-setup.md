# MLflow ServiceAccount Token Setup

The cursor-otel-hook and Claude Code both authenticate to MLflow using a long-lived Kubernetes ServiceAccount token. This token does not expire and does not require `oc login`.

## Create the SA and token (one-time, per cluster)

Requires cluster admin on the target RHOAI cluster.

```bash
WORKSPACE=evalhub

# 1. Create ServiceAccount
oc create serviceaccount mlflow-claude-tracing -n $WORKSPACE

# 2. Grant admin role in the workspace namespace
oc adm policy add-role-to-user admin \
  system:serviceaccount:${WORKSPACE}:mlflow-claude-tracing -n $WORKSPACE

# 3. Create non-expiring token secret
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mlflow-claude-tracing-token
  namespace: $WORKSPACE
  annotations:
    kubernetes.io/service-account.name: mlflow-claude-tracing
type: kubernetes.io/service-account-token
EOF

# 4. Retrieve the token
SA_TOKEN=$(oc get secret mlflow-claude-tracing-token -n $WORKSPACE \
  -o jsonpath='{.data.token}' | base64 -d)
echo "Token: ${#SA_TOKEN} chars"
```

## Create the direct Route (one-time, per cluster)

RHOAI's data-science-gateway OAuth proxy doesn't accept SA bearer tokens. A direct Route bypasses OAuth for programmatic API access.

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

oc apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: mlflow-direct
  namespace: redhat-ods-applications
  annotations:
    haproxy.router.openshift.io/timeout: 300s
spec:
  host: mlflow-direct.${CLUSTER_DOMAIN}
  to:
    kind: Service
    name: mlflow
  port:
    targetPort: https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
EOF
```

## Retrieve the token

```bash
oc get secret mlflow-claude-tracing-token -n evalhub \
  -o jsonpath='{.data.token}' | base64 -d
```

Or from an existing Claude Code project that already has it configured:

```bash
jq -r '.environment.MLFLOW_TRACKING_TOKEN' .claude/settings.json
```

## Rotate the token

Delete and recreate the secret. The SA stays the same.

```bash
WORKSPACE=evalhub

# Delete old token
oc delete secret mlflow-claude-tracing-token -n $WORKSPACE

# Create new token
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mlflow-claude-tracing-token
  namespace: $WORKSPACE
  annotations:
    kubernetes.io/service-account.name: mlflow-claude-tracing
type: kubernetes.io/service-account-token
EOF

# Retrieve new token
NEW_TOKEN=$(oc get secret mlflow-claude-tracing-token -n $WORKSPACE \
  -o jsonpath='{.data.token}' | base64 -d)
```

After rotation, re-run `setup.sh` on each client machine with the new `MLFLOW_TRACKING_TOKEN`.

## Security scope

- The SA has `admin` role in the `evalhub` namespace only — not cluster-wide
- It can read/write MLflow experiments, traces, and artifacts within that namespace
- The direct Route exposes MLflow without the OAuth proxy — access is gated by the SA token (bearer auth)
- Acceptable for dev/test clusters; for production, add network policies to restrict Route access

## Shared across clients

The same token is used by:
- **Claude Code**: stored in `.claude/settings.json` as `MLFLOW_TRACKING_TOKEN`
- **Cursor**: stored in `~/.cursor/hooks/otel_config.json` as an Authorization header
- **CI/scripts**: passed via `MLFLOW_TRACKING_TOKEN` env var
