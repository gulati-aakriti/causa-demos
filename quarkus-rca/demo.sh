#!/bin/bash
################################################################################
# Quarkus RCA Demo Script
#
# End-to-end demo that:
#
#   Step 1 — Runs install.sh from the quarkus-rca installer branch
#             Provisions: Kind cluster, Prometheus, k8s-mcp-server, Causa Backend,
#             Causa MCP, PostgreSQL (async-profiler & quarkus-mcp skipped — images TBD)
#
#   Step 2 — Deploys the quarkus-perf workload + load-gen job
#             into the causa-rca namespace on the kind cluster
#
#   Step 3 — Sources llm.env, creates the causa-gcp-credentials K8s Secret,
#             and pushes LLM config + alert cooldown to Causa via
#             POST /api/v1/configs
#
#   Step 4 — Writes the Causa MCP entry to ~/.bob/settings/mcp.json
#             and copies the causa-rca SKILL.md into ~/.bob/skills/
#
#   Step 5 — Prints a ready prompt with container/namespace/pod info
#             for the user to paste into Bob IDE
#
# Usage:  ./demo.sh [OPTIONS]
# Run with -h for full option list.
#
# Prerequisites:  kind  kubectl  docker or podman  git  python3
#
# To change installer repo or branch:
#   INSTALLER_URL  and  INSTALLER_BRANCH  variables below (or use CLI flags).
#   The installer is cloned from INSTALLER_URL @ INSTALLER_BRANCH each run.
################################################################################

set -o pipefail

# ---------------------------------------------------------------------------
# Script directory and library loading
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOGGING_FILE="$SCRIPT_DIR/lib/logging.sh"
UTILS_FILE="$SCRIPT_DIR/lib/utils.sh"
UNINSTALL_FILE="$SCRIPT_DIR/lib/uninstall.sh"

IMAGES_ENV_FILE="$SCRIPT_DIR/images.env"
if [[ -f "$IMAGES_ENV_FILE" ]]; then
    set -a
    source "$IMAGES_ENV_FILE"
    set +a
    echo -e "\033[0;36m[images.env]\033[0m Image overrides loaded from: $IMAGES_ENV_FILE"
fi

for _f in "$LOGGING_FILE" "$UTILS_FILE" "$UNINSTALL_FILE"; do
    if [[ ! -f "$_f" ]]; then
        echo "ERROR: $(basename "$_f") not found at $_f"
        exit 1
    fi
done

source "$LOGGING_FILE"
source "$UTILS_FILE"
source "$UNINSTALL_FILE"

_demo_exit_trap() { trap '' INT TERM; stop_spinner; exit 130; }
trap '_demo_exit_trap' INT TERM

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NAMESPACE="causa-rca"
TERMINATE=false
SKIP_INSTALLER=false
DEMO_DIR="$SCRIPT_DIR/artifacts"

WORKLOAD_APP_NAME="quarkus-perf"
WORKLOAD_CONTAINER_NAME="quarkus-perf"
export WORKLOAD_APP_NAME

# ---------------------------------------------------------------------------
# Installer configuration
# ---------------------------------------------------------------------------
# To use a different fork or branch, change these two variables or pass CLI flags.
INSTALLER_NAME="installer"
INSTALLER_URL="${INSTALLER_URL:-https://github.com/gulati-aakriti/installer}"
INSTALLER_BRANCH="${INSTALLER_BRANCH:-quarkus-rca}"

# ---------------------------------------------------------------------------
# Bob IDE config
# ---------------------------------------------------------------------------
BOB_MCP_CONFIG="${HOME}/.bob/settings/mcp.json"
# Causa MCP Server is on NodePort 30005 (see installer manifests/causa_mcp/deployment.yaml)
CAUSA_MCP_URL="http://localhost:30005"
CAUSA_BACKEND_URL="http://localhost:30001"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
show_help() {
    echo "Quarkus RCA Demo Script"
    echo ""
    echo "Usage: $0 [-n namespace] [-t] [--skip-installer] [--installer-url URL] [--installer-branch BRANCH] [-h]"
    echo ""
    echo "Options:"
    echo "    -n namespace             Namespace for the RCA stack and workload (default: causa-rca)"
    echo "    -t                       Terminate mode: clean up all resources"
    echo "    --skip-installer         Skip running install.sh (use when stack is already deployed)"
    echo "    --installer-url URL      Git URL of the installer repo"
    echo "                             Default: https://github.com/gulati-aakriti/installer"
    echo "    --installer-branch BRANCH  Branch to check out from the installer repo"
    echo "                               Default: quarkus-rca"
    echo "    -h                       Show this help message"
    echo ""
    echo "Installer repo / branch:"
    echo "    The installer is cloned from INSTALLER_URL at INSTALLER_BRANCH."
    echo "    To permanently use a different repo or branch, edit these variables"
    echo "    at the top of this script, or export them before running:"
    echo "        export INSTALLER_URL=https://github.com/my-fork/installer"
    echo "        export INSTALLER_BRANCH=my-feature-branch"
    echo "        ./demo.sh"
    echo ""
    echo "Examples:"
    echo "    # Full automated demo (installs stack + deploys workload)"
    echo "    $0"
    echo ""
    echo "    # Custom namespace"
    echo "    $0 -n my-rca"
    echo ""
    echo "    # Skip installer (stack already running)"
    echo "    $0 --skip-installer"
    echo ""
    echo "    # Tear down everything"
    echo "    $0 -t"
    echo ""
    echo "Prerequisites:  kind  kubectl  docker or podman  git  python3"
    echo ""
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -n)               NAMESPACE="$2"; shift 2 ;;
        -t)               TERMINATE=true; shift ;;
        --skip-installer) SKIP_INSTALLER=true; shift ;;
        --installer-url)
            [[ -z "${2:-}" ]] && { echo "ERROR: value required for --installer-url" >&2; exit 1; }
            INSTALLER_URL="$2"; shift 2 ;;
        --installer-branch)
            [[ -z "${2:-}" ]] && { echo "ERROR: value required for --installer-branch" >&2; exit 1; }
            INSTALLER_BRANCH="$2"; shift 2 ;;
        -h) show_help; exit 0 ;;
        *)  echo "ERROR: Invalid option: $1" >&2; echo "Use -h for help"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Initialise logging
# ---------------------------------------------------------------------------
SCRIPT_START_TIME=$(start_timer)
LOG_FILE="$SCRIPT_DIR/demo.log"

if [[ "$TERMINATE" == "true" ]]; then
    init_logging "$LOG_FILE" "true"
else
    init_logging "$LOG_FILE" "false"
fi

# ---------------------------------------------------------------------------
# Opening banner
# ---------------------------------------------------------------------------
if [[ "$TERMINATE" == "true" ]]; then
    {
        echo ""
        echo -e "${COLOR_CYAN}${COLOR_BOLD}==========================================${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Quarkus RCA Demo — Cleanup${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}==========================================${COLOR_RESET}"
        echo ""
    } >/dev/tty 2>/dev/null || true
    write_to_log_file "INFO" "Demo Cleanup — namespace: $NAMESPACE"
else
    {
        echo ""
        echo -e "${COLOR_CYAN}${COLOR_BOLD}==========================================${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Running Quarkus RCA Demo${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}==========================================${COLOR_RESET}"
        echo ""
    } >/dev/tty 2>/dev/null || true
    write_to_log_file "INFO" "Demo Setup — namespace: $NAMESPACE"
    echo -e "${COLOR_CYAN}Namespace:${COLOR_RESET}        ${COLOR_BOLD}${NAMESPACE}${COLOR_RESET}" >/dev/tty 2>/dev/null || true
    echo -e "${COLOR_CYAN}Installer URL:${COLOR_RESET}    ${COLOR_BOLD}${INSTALLER_URL}${COLOR_RESET}" >/dev/tty 2>/dev/null || true
    echo -e "${COLOR_CYAN}Installer Branch:${COLOR_RESET} ${COLOR_BOLD}${INSTALLER_BRANCH}${COLOR_RESET}" >/dev/tty 2>/dev/null || true
    echo "" >/dev/tty 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Terminate mode
# ---------------------------------------------------------------------------
if [[ "$TERMINATE" == "true" ]]; then
    terminate_demo "$NAMESPACE" "$DEMO_DIR" "$SKIP_INSTALLER"

    # Remove Causa MCP entry from Bob mcp.json
    if [[ -f "$BOB_MCP_CONFIG" ]]; then
        start_spinner "Removing Causa MCP from Bob IDE config..."
        if command_exists python3; then
            python3 - "$BOB_MCP_CONFIG" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
    cfg.get("mcpServers", {}).pop("causa-rca", None)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("removed")
except Exception as e:
    print(f"warn: {e}", file=sys.stderr)
PYEOF
        fi
        stop_spinner
        log_install_success "Causa MCP removed from Bob IDE config"
    fi

    ELAPSED=$(get_elapsed_time "$SCRIPT_START_TIME")
    write_to_log_file "SUCCESS" "Total cleanup time: $ELAPSED"
    {
        echo ""
        echo -e "${COLOR_BOLD_YELLOW}Total cleanup time: $ELAPSED${COLOR_RESET}"
        echo ""
    } >/dev/tty 2>/dev/null || true
    exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
# Check non-runtime prerequisites first
if ! check_required_commands git kubectl kind; then
    log_error "Missing required commands. Please install them and try again."
    exit 1
fi

# Resolve container runtime — prefer docker, fall back to podman
if command_exists docker; then
    CONTAINER_RUNTIME="docker"
elif command_exists podman; then
    CONTAINER_RUNTIME="podman"
else
    log_error "No container runtime found. Install docker or podman."
    log_error "  - docker: https://docs.docker.com/get-docker/"
    log_error "  - podman: https://podman.io/getting-started/installation"
    exit 1
fi
export CONTAINER_RUNTIME
write_to_log_file "INFO" "Container runtime: $CONTAINER_RUNTIME"

log_validation_success "Validating Prerequisites"

ensure_directory "$DEMO_DIR"
cd "$DEMO_DIR"

# ===========================================================================
# Step 1: Run install.sh (Causa RCA stack on kind)
# ===========================================================================
log_section "Step 1: Installing Causa RCA stack via install.sh"

# ---------------------------------------------------------------------------
# 1a: Clone / update the installer repo
# ---------------------------------------------------------------------------
INSTALLER_DIR="$DEMO_DIR/$INSTALLER_NAME"

if [[ "$SKIP_INSTALLER" == "false" ]]; then
    start_spinner "Cloning installer (branch: $INSTALLER_BRANCH)..."
    if ! clone_repo "$INSTALLER_URL" "$INSTALLER_DIR" "$INSTALLER_BRANCH" \
            2>&1 | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"; then
        stop_spinner
        log_error "Failed to clone installer from $INSTALLER_URL"
        exit 1
    fi
    stop_spinner
    log_install_success "installer cloned (branch: $INSTALLER_BRANCH)"

    # install.sh is the entry point on the quarkus-rca branch.
    # If you want to use main or a different branch in future, update
    # INSTALLER_BRANCH above (or --installer-branch CLI flag) — the script
    # name is always install.sh.
    INSTALL_SCRIPT="$INSTALLER_DIR/install.sh"
    if [[ ! -f "$INSTALL_SCRIPT" ]]; then
        log_error "install.sh not found in $INSTALLER_DIR (branch: $INSTALLER_BRANCH)"
        log_error "Expected: $INSTALL_SCRIPT"
        exit 1
    fi

    # ---------------------------------------------------------------------------
    # 1b: Run install.sh with --target kind and image overrides
    # ---------------------------------------------------------------------------
    # Images are provided explicitly so the installer uses exactly what we want:
    #   causa backend:     quay.io/rh-ee-shesaxen/causa-backend:adc-fix
    #   causa mcp:         quay.io/bmenghan/causa-mcp-server:latest
    #   k8s mcp server:    quay.io/containers/kubernetes_mcp_server:v0.0.62
    # async-profiler, async-profiler-mcp, quarkus-mcp images are not yet
    # available — install.sh skips them gracefully (non-fatal warnings).
    #
    # To permanently change the images, edit images.env in this directory.
    # The images below are loaded from images.env at script startup (set -a).
    # ---------------------------------------------------------------------------
    {
        echo ""
        echo -e "${COLOR_CYAN}Running install.sh --target kind ...${COLOR_RESET}"
        echo ""
    } >/dev/tty 2>/dev/null || true

    _INSTALL_ARGS=(
        --target kind
        -n "${NAMESPACE}"
    )

    # Pass image overrides if set via images.env or environment
    [[ -n "${K8S_MCP_SERVER_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--k8s-mcp-server-image "$K8S_MCP_SERVER_IMAGE")
    [[ -n "${CAUSA_BACKEND_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--causa-backend-image "$CAUSA_BACKEND_IMAGE")
    [[ -n "${CAUSA_MCP_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--causa-mcp-image "$CAUSA_MCP_IMAGE")
    [[ -n "${ASYNC_PROFILER_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--async-profiler-image "$ASYNC_PROFILER_IMAGE")
    [[ -n "${ASYNC_PROFILER_MCP_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--async-profiler-mcp-image "$ASYNC_PROFILER_MCP_IMAGE")
    [[ -n "${QUARKUS_MCP_IMAGE:-}" ]] && \
        _INSTALL_ARGS+=(--quarkus-mcp-image "$QUARKUS_MCP_IMAGE")

    write_to_log_file "INFO" "Running: bash $INSTALL_SCRIPT ${_INSTALL_ARGS[*]}"

    # Run install.sh — its output is tee'd to terminal AND log file
    bash "$INSTALL_SCRIPT" "${_INSTALL_ARGS[@]}" \
        2>&1 | tee -a "$LOG_FILE"
    _install_rc=${PIPESTATUS[0]}

    if [[ $_install_rc -ne 0 ]]; then
        log_error "install.sh failed (exit code: $_install_rc). Check log: $LOG_FILE"
        exit 1
    fi
    log_install_success "Causa RCA stack deployed"
else
    log_install_success "Skipping installer (--skip-installer flag set)"
    log_file_only "Installer skipped by user"
    INSTALLER_DIR="${INSTALLER_DIR:-}"
fi

# ===========================================================================
# Step 2: Deploy quarkus-perf workload + load-gen
# ===========================================================================
log_section "Step 2: Deploying quarkus-perf workload"

WORKLOAD_MANIFEST="$SCRIPT_DIR/manifests/quarkus-perf-deploy.yaml"
LOAD_GEN_MANIFEST="$SCRIPT_DIR/manifests/quarkus-perf-load-gen.yaml"

if [[ ! -f "$WORKLOAD_MANIFEST" ]]; then
    log_error "Workload manifest not found: $WORKLOAD_MANIFEST"
    exit 1
fi

start_spinner "Creating namespace $NAMESPACE..."
ensure_namespace "$NAMESPACE" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"
stop_spinner

# ── Deploy quarkus-perf ──────────────────────────────────────────────────
start_spinner "Deploying quarkus-perf workload..."
if ! apply_manifest "$WORKLOAD_MANIFEST" "$NAMESPACE" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"; then
    stop_spinner
    log_error "Failed to deploy quarkus-perf workload"
    exit 1
fi
stop_spinner
log_install_success "quarkus-perf deployed to $NAMESPACE"

# ── Wait for quarkus-perf to be ready ─────────────────────────────────────
start_spinner "Waiting for quarkus-perf to be ready (up to 300s)..."
if ! wait_for_deployment "quarkus-perf" "$NAMESPACE" 300 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"; then
    stop_spinner
    log_file_only "quarkus-perf not ready within timeout — continuing"
    log_validation_success "quarkus-perf readiness (timed out — check: kubectl get pods -n $NAMESPACE)"
else
    stop_spinner
    log_install_success "quarkus-perf is ready"
fi

# ── Start load-gen job (generates traffic that drives heap leak) ──────────
start_spinner "Starting load-gen job (drives OOM pressure)..."
if [[ -f "$LOAD_GEN_MANIFEST" ]]; then
    # Delete previous job if it exists (Jobs are immutable)
    kubectl delete job quarkus-perf-load-gen -n "$NAMESPACE" \
        --ignore-not-found=true >>"$LOG_FILE" 2>&1 || true
    if ! apply_manifest "$LOAD_GEN_MANIFEST" "$NAMESPACE" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"; then
        stop_spinner
        log_file_only "Failed to start load-gen job — continuing (OOM will take longer)"
    else
        stop_spinner
        log_install_success "load-gen job started (20 workers × 100ms delay → OOM in ~3-5 min)"
    fi
else
    stop_spinner
    log_file_only "Load-gen manifest not found: $LOAD_GEN_MANIFEST — skipping"
    log_validation_success "load-gen job (skipped — manifest not found)"
fi


# ===========================================================================
# Step 3: Configure Causa Backend — LLM credentials + alert cooldown
# ===========================================================================
# Sources llm.env, creates the causa-gcp-credentials K8s Secret from
# causa-gcp-key.json, and pushes LLM config + alert cooldown to Causa via
# POST /api/v1/configs.
#
# Non-fatal: if VERTEX_PROJECT_ID is not set, only cooldown is pushed.
# Causa still performs RCA using heuristics without LLM config.
# ===========================================================================
log_section "Step 3: Configuring Causa Backend (LLM + cooldown)"

# ── Load llm.env if present ───────────────────────────────────────────────
_LLM_ENV_FILE="$SCRIPT_DIR/llm.env"
if [[ -f "$_LLM_ENV_FILE" ]]; then
    write_to_log_file "INFO" "Loading LLM config from: $_LLM_ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$_LLM_ENV_FILE"
    set +a
else
    write_to_log_file "INFO" "llm.env not found — using exported environment variables"
    write_to_log_file "INFO" "Copy llm.env.example to llm.env and fill in values to enable LLM RCA"
fi

# ── Auto-create causa-gcp-credentials K8s Secret from local key file ─────
_GCP_KEY_FILE="$SCRIPT_DIR/causa-gcp-key.json"
if [[ -n "${VERTEX_PROJECT_ID:-}" ]]; then
    if kubectl get secret causa-gcp-credentials \
            -n "$NAMESPACE" >>"$LOG_FILE" 2>&1; then
        write_to_log_file "INFO" "causa-gcp-credentials secret already exists in $NAMESPACE"
    elif [[ -f "$_GCP_KEY_FILE" ]]; then
        start_spinner "Creating causa-gcp-credentials secret from causa-gcp-key.json..."
        if kubectl create secret generic causa-gcp-credentials \
                --from-file="key.json=$_GCP_KEY_FILE" \
                -n "$NAMESPACE" >>"$LOG_FILE" 2>&1; then
            stop_spinner
            log_install_success "causa-gcp-credentials secret created"
        else
            stop_spinner
            log_file_only "Failed to create causa-gcp-credentials secret — check $LOG_FILE"
        fi
    else
        write_to_log_file "WARN" "causa-gcp-key.json not found at $_GCP_KEY_FILE"
        write_to_log_file "WARN" "Place the GCP service-account key there to enable LLM RCA"
    fi
fi

# ── Read GCP key back as a single-line base64 blob from the K8s Secret ───
_GCP_B64=""
if [[ -n "${VERTEX_PROJECT_ID:-}" ]]; then
    _GCP_B64=$(kubectl get secret causa-gcp-credentials \
        -n "$NAMESPACE" \
        -o "jsonpath={.data.key\.json}" \
        2>>"$LOG_FILE" | tr -d '[:space:]' || true)
    if [[ -z "$_GCP_B64" ]]; then
        write_to_log_file "WARN" "causa-gcp-credentials secret missing or empty — GOOGLE_APPLICATION_CREDENTIALS not pushed"
    fi
fi

# ── Build POST /api/v1/configs payload ───────────────────────────────────
_COOLDOWN_MINUTES="${CAUSA_ALERT_COOLDOWN:-1}"
_COOLDOWN_SECONDS=$(( _COOLDOWN_MINUTES * 60 ))

_CONFIG_PAIRS="\"ALERT_COOLDOWN_PERIOD\":\"${_COOLDOWN_SECONDS}\","
_CONFIG_PAIRS="${_CONFIG_PAIRS}\"ALERT_COOLDOWN_MINUTES\":\"${_COOLDOWN_MINUTES}\","

if [[ -n "${VERTEX_PROJECT_ID:-}" ]]; then
    _CONFIG_PAIRS="${_CONFIG_PAIRS}\"VERTEX_PROJECT_ID\":\"${VERTEX_PROJECT_ID}\","
    [[ -n "${VERTEX_LOCATION:-}" ]]  && _CONFIG_PAIRS="${_CONFIG_PAIRS}\"VERTEX_LOCATION\":\"${VERTEX_LOCATION}\","
    [[ -n "${LLM_MODEL_NAME:-}" ]]   && _CONFIG_PAIRS="${_CONFIG_PAIRS}\"LLM_MODEL_NAME\":\"${LLM_MODEL_NAME}\","
    [[ -n "${LLM_PROVIDER:-}" ]]     && _CONFIG_PAIRS="${_CONFIG_PAIRS}\"LLM_PROVIDER\":\"${LLM_PROVIDER}\","
    [[ -n "$_GCP_B64" ]]             && _CONFIG_PAIRS="${_CONFIG_PAIRS}\"GOOGLE_APPLICATION_CREDENTIALS\":\"${_GCP_B64}\","
fi
_CONFIG_PAIRS="${_CONFIG_PAIRS%,}"
_CONFIG_PAYLOAD="{\"configs\":{${_CONFIG_PAIRS}}}"

if [[ -n "${VERTEX_PROJECT_ID:-}" ]]; then
    write_to_log_file "INFO" "Pushing LLM config + cooldown (${_COOLDOWN_MINUTES}min) to Causa"
else
    write_to_log_file "INFO" "Pushing cooldown only (${_COOLDOWN_MINUTES}min) — VERTEX_PROJECT_ID not set"
fi

# ── Find running Causa Backend pod ───────────────────────────────────────
_CAUSA_POD=$(kubectl get pods \
    -l "app=causa-backend" \
    -n "$NAMESPACE" \
    --field-selector="status.phase=Running" \
    -o "jsonpath={.items[0].metadata.name}" \
    2>>"$LOG_FILE" || true)

if [[ -z "$_CAUSA_POD" ]]; then
    write_to_log_file "WARN" "Causa Backend pod not running — skipping config push (RCA will run without LLM)"
else
    start_spinner "Pushing config to Causa Backend (up to 5 attempts)..."
    _cfg_rc=1
    for _attempt in 1 2 3 4 5; do
        _cfg_rc=0
        kubectl exec -n "$NAMESPACE" "$_CAUSA_POD" -- \
            curl -sf --max-time 10 \
            -X POST "http://localhost:8080/api/v1/configs" \
            -H "Content-Type: application/json" \
            -d "$_CONFIG_PAYLOAD" \
            >>"$LOG_FILE" 2>&1 || _cfg_rc=$?

        if [[ $_cfg_rc -eq 0 ]]; then
            break
        fi
        write_to_log_file "INFO" "Config push attempt ${_attempt}/5 failed (rc=${_cfg_rc}) — retrying in 10s..."
        [[ $_attempt -lt 5 ]] && sleep 10
    done
    stop_spinner
    if [[ $_cfg_rc -eq 0 ]]; then
        log_install_success "Causa Backend configured (LLM config + cooldown pushed)"
    else
        log_file_only "Config push failed after 5 attempts (non-fatal — RCA will run without LLM)"
        log_validation_success "Causa config push (failed — check $LOG_FILE)"
    fi
fi

# ===========================================================================
# Step 4: Register Causa MCP in Bob IDE + write causa-rca SKILL.md
# ===========================================================================
log_section "Step 4: Registering Causa MCP in Bob IDE"

# ── 4a: Write Causa MCP entry to ~/.bob/settings/mcp.json ─────────────────
start_spinner "Writing Causa MCP entry to ~/.bob/settings/mcp.json..."

_bob_mcp_dir="$(dirname "$BOB_MCP_CONFIG")"
mkdir -p "$_bob_mcp_dir"

if command_exists python3; then
    python3 - "$BOB_MCP_CONFIG" "$CAUSA_MCP_URL" << 'PYEOF'
import json, sys, os
path, url = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.isfile(path):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except json.JSONDecodeError:
        cfg = {}
cfg.setdefault("mcpServers", {})["causa-rca"] = {
    "type": "http",
    "url": url + "/mcp",
    "description": "Causa RCA — root cause analysis for Quarkus/Java apps"
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("ok")
PYEOF
    _reg_rc=$?
else
    if [[ ! -f "$BOB_MCP_CONFIG" ]]; then
        printf '{"mcpServers":{"causa-rca":{"type":"http","url":"%s/mcp","description":"Causa RCA"}}}\n' \
            "$CAUSA_MCP_URL" > "$BOB_MCP_CONFIG"
    fi
    _reg_rc=0
fi

stop_spinner
if [[ $_reg_rc -eq 0 ]]; then
    log_install_success "Causa MCP registered in Bob IDE ($CAUSA_MCP_URL/mcp)"
    write_to_log_file "INFO" "Bob MCP config: $BOB_MCP_CONFIG"
else
    log_file_only "Bob MCP config update failed — add manually (see below)"
    log_validation_success "Bob IDE config (failed — add manually)"
fi

# ── 4b: Copy causa-rca SKILL.md to ~/.bob/skills/ ────────────────────────
# The SKILL.md in this repo (checked into .bob/skills/causa-rca/SKILL.md)
# is the authoritative version. Copy it to the user's Bob skill directory.
BOB_SKILL_DIR="${HOME}/.bob/skills/causa-rca"
BOB_SKILL_FILE="${BOB_SKILL_DIR}/SKILL.md"
REPO_SKILL_FILE="${SCRIPT_DIR}/../.bob/skills/causa-rca/SKILL.md"

start_spinner "Copying causa-rca SKILL.md to Bob IDE..."
mkdir -p "$BOB_SKILL_DIR"

if [[ -f "$REPO_SKILL_FILE" ]]; then
    cp "$REPO_SKILL_FILE" "$BOB_SKILL_FILE"
    _skill_rc=$?
else
    # Fallback: write a minimal SKILL.md stub if the repo file is missing
    cat > "$BOB_SKILL_FILE" << 'SKILL_EOF'
---
name: causa-rca
description: Activate when a developer asks about application health, diagnostics, root cause analysis, existing RCA results, or why their application is failing.
compatibility: Requires the Causa MCP server to be configured in Bob with tools initiate_rca and get_rca_result.
---

# Causa RCA Skill

Use tools initiate_rca and get_rca_result from the Causa MCP server.
See the full SKILL.md in the causa-demos repo for complete instructions.
SKILL_EOF
    _skill_rc=$?
fi

stop_spinner
if [[ $_skill_rc -eq 0 && -f "$BOB_SKILL_FILE" ]]; then
    log_install_success "causa-rca SKILL.md written to Bob IDE"
    write_to_log_file "INFO" "Skill: $BOB_SKILL_FILE"
else
    log_file_only "Failed to write causa-rca SKILL.md"
    log_validation_success "causa-rca skill (failed — copy manually to ~/.bob/skills/causa-rca/SKILL.md)"
fi

# ===========================================================================
# Step 5: Print Bob prompt with container / namespace / pod info
# ===========================================================================
# Identify the current quarkus-perf pod name so we can give the user a
# ready-to-paste prompt for Bob IDE.
# ===========================================================================

# Discover current quarkus-perf pod name (may be empty right after deploy)
_QP_POD=$(kubectl get pod \
    -n "$NAMESPACE" \
    -l "app=quarkus-perf" \
    --field-selector="status.phase=Running" \
    -o "jsonpath={.items[0].metadata.name}" \
    2>>"$LOG_FILE" || true)

# If not running yet, grab any pod in any phase for the prompt
if [[ -z "$_QP_POD" ]]; then
    _QP_POD=$(kubectl get pod \
        -n "$NAMESPACE" \
        -l "app=quarkus-perf" \
        -o "jsonpath={.items[0].metadata.name}" \
        2>>"$LOG_FILE" || true)
fi

_POD_DISPLAY="${_QP_POD:-quarkus-perf-<generated-suffix>}"

{
    echo ""
    echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
    echo -e "${COLOR_BOLD_GREEN}  Demo is ready. Switch to Bob IDE now.${COLOR_RESET}"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_BOLD_YELLOW}What's happening:${COLOR_RESET}"
    echo -e "  • quarkus-perf is running with CHAOS_MEMORY_CACHE_ENABLED=true"
    echo -e "  • load-gen is hitting /api/bookings + /api/accounts/*/transactions"
    echo -e "  • Heap leak fills 512Mi in ~3-5 minutes → OOMKilled"

    echo ""
    echo -e "${COLOR_BOLD_YELLOW}Workload details:${COLOR_RESET}"
    echo -e "  Container:  ${COLOR_BOLD}${WORKLOAD_CONTAINER_NAME}${COLOR_RESET}"
    echo -e "  Namespace:  ${COLOR_BOLD}${NAMESPACE}${COLOR_RESET}"
    echo -e "  Pod:        ${COLOR_BOLD}${_POD_DISPLAY}${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_BOLD_YELLOW}Type this in Bob IDE chat:${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_BOLD}Use Causa RCA to investigate why my quarkus-perf app keeps crashing."
    echo -e "  App: ${WORKLOAD_APP_NAME}, namespace: ${NAMESPACE},"
    echo -e "  container: ${WORKLOAD_CONTAINER_NAME}, pod: ${_POD_DISPLAY}."
    echo -e "  Run RCA using the causa-rca skill and show me the root cause and fix.${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}What Bob will do:${COLOR_RESET}"
    echo -e "  1. Use the causa-rca skill (initiate_rca + get_rca_result)"
    echo -e "  2. Initiate RCA for ${WORKLOAD_APP_NAME} in namespace ${NAMESPACE}"
    echo -e "  3. Poll until COMPLETED, then present root cause + fix"
    echo ""
    echo -e "${COLOR_CYAN}Note:${COLOR_RESET} You can prompt Bob immediately — no need to wait for an OOMKill."
    echo -e "  Watch pod restarts: ${COLOR_BOLD}kubectl get pods -n ${NAMESPACE} -w${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}Causa Backend:${COLOR_RESET} ${CAUSA_BACKEND_URL}/api/v1/diagnostics"
    echo -e "${COLOR_CYAN}Causa MCP:${COLOR_RESET}     ${CAUSA_MCP_URL}/mcp"
    echo -e "${COLOR_CYAN}Skill file:${COLOR_RESET}    ${BOB_SKILL_FILE}"
    echo -e "${COLOR_CYAN}MCP config:${COLOR_RESET}    ${BOB_MCP_CONFIG}"
    echo ""
} >/dev/tty 2>/dev/null || true

# ---------------------------------------------------------------------------
# Completion summary
# ---------------------------------------------------------------------------
ELAPSED=$(get_elapsed_time "$SCRIPT_START_TIME")
write_to_log_file "SUCCESS" "Demo setup completed in $ELAPSED"

{
    echo "========================================"
    echo "Quarkus RCA Demo — Completed"
    echo "========================================"
    echo "Namespace:    $NAMESPACE"
    echo "Demo log:     $LOG_FILE"
    [[ "$SKIP_INSTALLER" == "false" && -n "${INSTALLER_DIR:-}" ]] && \
        echo "Installer log: ${INSTALLER_DIR}/install.log"
    echo "========================================"
} >>"$LOG_FILE"

{
    echo -e "${COLOR_BOLD_YELLOW}Total setup time: $ELAPSED${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_CYAN}Log file: ${LOG_FILE}${COLOR_RESET}"
    echo ""
} >/dev/tty 2>/dev/null || true
