# Quarkus RCA Demo — Setup Guide

---

## Prerequisites

The following tools must be installed and available in your `$PATH`:

```text
kind      kubectl     docker (or podman)     git     python3
```

---

## Credentials Setup (required for LLM-powered RCA)

Causa performs AI-powered RCA using Claude on Google Vertex AI. You need a GCP service account with the `roles/aiplatform.user` role.

```bash
# 1. Copy the example and fill in your GCP project details
cp llm.env.example llm.env
# edit llm.env — set VERTEX_PROJECT_ID (and VERTEX_LOCATION, LLM_MODEL_NAME if different from defaults)

# 2. Place your GCP service account key in the quarkus-rca directory (gitignored)
cp /path/to/your/key.json causa-gcp-key.json
```

To create a GCP service account and download the key:

```bash
gcloud iam service-accounts create causa-llm-sa \
  --project="${VERTEX_PROJECT_ID}"

gcloud projects add-iam-policy-binding "${VERTEX_PROJECT_ID}" \
  --member="serviceAccount:causa-llm-sa@${VERTEX_PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/aiplatform.user" --condition=None

gcloud iam service-accounts keys create causa-gcp-key.json \
  --iam-account="causa-llm-sa@${VERTEX_PROJECT_ID}.iam.gserviceaccount.com"
```

If neither `llm.env` nor `causa-gcp-key.json` is present, the demo still runs — Causa performs RCA using heuristics only (no LLM analysis).

---

## Quick Start

```bash
git clone https://github.com/causaai/causa-demos.git
cd causa-demos/quarkus-rca

# Full demo — Kind cluster + installer + workload + LLM config
./demo.sh

# Tear down everything when done
./demo.sh -t
```

---

## All CLI Options

| Option | Default | Description |
|--------|---------|-------------|
| `-n NAMESPACE` | `causa-rca` | Namespace for the RCA stack and workload |
| `-t` | — | Terminate mode — clean up all resources |
| `--skip-installer` | — | Skip cloning and running the installer (stack already deployed) |
| `--installer-url URL` | `https://github.com/gulati-aakriti/installer` | Git URL of the installer repo to clone |
| `--installer-branch BRANCH` | `quarkus-rca` | Branch to check out from the installer repo |
| `-h` | — | Show help |

---

## Examples

```bash
# Deploy to a custom namespace
./demo.sh -n my-rca

# Use a different installer fork or branch
./demo.sh \
  --installer-url    https://github.com/causaai/installer \
  --installer-branch main

# RCA stack already running — skip the installer, just deploy the workload and configure
./demo.sh --skip-installer

# Tear down from a custom namespace
./demo.sh -t -n my-rca
```

---

## Image Overrides

Default images are defined in [`images.env`](../images.env). Override without editing the file:

```bash
# Via export
export CAUSA_MCP_IMAGE=quay.io/causaai/causa-mcp:v0.1.0
./demo.sh

# Or edit images.env directly
CAUSA_MCP_IMAGE=quay.io/causaai/causa-mcp:v0.1.0
```

Available override variables:

| Variable | Component |
|----------|-----------|
| `CAUSA_BACKEND_IMAGE` | Causa Backend |
| `CAUSA_MCP_IMAGE` | Causa MCP Server |
| `K8S_MCP_SERVER_IMAGE` | Kubernetes MCP Server |
| `ASYNC_PROFILER_IMAGE` | Async Profiler |
| `ASYNC_PROFILER_MCP_IMAGE` | Async Profiler MCP |
| `QUARKUS_MCP_IMAGE` | Quarkus MCP |

---

## Alertmanager Setup

The installer configures Prometheus Alertmanager to route `causa-.*` alerts to the Causa webhook automatically. The `causa-high-memory` alert fires when a labelled pod exceeds 80% of its memory limit. This is what triggers autonomous RCA — no manual trigger is needed.

To inspect the alert routing:
```bash
kubectl get configmap -n causa-rca -l app=alertmanager -o yaml
```

To verify the Causa webhook is receiving alerts:
```bash
kubectl logs -n causa-rca -l app=causa-backend -f | grep -i alert
```

---

## Repository Structure

```
quarkus-rca/
├── demo.sh                          # Main demo script — run this
├── llm.env                          # YOUR FILE — gitignored, never commit
├── llm.env.example                  # Template — committed, safe to share
├── causa-gcp-key.json               # YOUR FILE — gitignored, never commit
├── images.env                       # Image override defaults
├── docs/
│   └── SETUP.md                     # This file
├── lib/
│   ├── logging.sh
│   ├── utils.sh
│   └── uninstall.sh
└── manifests/
    ├── quarkus-perf-deploy.yaml     # quarkus-perf workload (CHAOS flags enabled)
    ├── quarkus-perf-load-gen.yaml   # Load generator job (20 workers)
    ├── quarkus-perf-monitoring.yaml # Prometheus ServiceMonitor + alert rule
    └── perf-impact-deploy.yaml      # Reference manifest

.bob/
└── skills/
    └── causa-rca/
        └── SKILL.md                 # Auto-loaded by Bob when this repo is open
```

---

## Troubleshooting

### Kind cluster does not start

```bash
# Check Docker is running
docker info

# Delete and recreate the cluster
kind delete cluster --name causa
./demo.sh
```

### Causa Backend pod not ready

```bash
kubectl get pods -n causa-rca
kubectl describe pod -n causa-rca -l app=causa-backend
kubectl logs -n causa-rca -l app=causa-backend --previous
```

### LLM config push fails

The script retries 5 times with a 10-second interval. If all attempts fail, Causa still runs RCA using heuristics. To push config manually:

```bash
kubectl exec -n causa-rca deploy/causa-backend -- \
  curl -sf -X POST http://localhost:8080/api/v1/configs \
  -H "Content-Type: application/json" \
  -d '{"configs":{"VERTEX_PROJECT_ID":"your-project","VERTEX_LOCATION":"us-east5"}}'
```

### Bob IDE does not see the Causa MCP server

Check `~/.bob/settings/mcp.json` — it should contain:

```json
{
  "mcpServers": {
    "causa-rca": {
      "type": "http",
      "url": "http://localhost:30005/mcp",
      "description": "Causa RCA — root cause analysis for Quarkus/Java apps"
    }
  }
}
```

Verify the Causa MCP pod is running and the NodePort is reachable:
```bash
kubectl get pods -n causa-rca -l app=causa-mcp
curl http://localhost:30005/mcp
```

### OOMKill not happening

Check that the load-gen job is running:
```bash
kubectl get jobs -n causa-rca
kubectl logs -n causa-rca -l app=quarkus-perf-load-gen
```

Check that chaos flags are set on the workload:
```bash
kubectl get deployment quarkus-perf -n causa-rca -o jsonpath='{.spec.template.spec.containers[0].env}' | python3 -m json.tool
```

`CHAOS_MEMORY_CACHE_ENABLED` and `CHAOS_HTTP_LARGE_RESPONSE_ENABLED` must both be `"true"`.

### Full cleanup

```bash
./demo.sh -t
kind delete cluster --name causa
```
