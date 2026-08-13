#!/bin/bash
################################################################################
# Uninstall / Cleanup — Quarkus RCA Demo
################################################################################

if [[ -n "${DEMO_UNINSTALL_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly DEMO_UNINSTALL_LIB_LOADED=1

WORKLOAD_APP_NAME="${WORKLOAD_APP_NAME:-quarkus-perf}"

cleanup_directory() {
    local dir="$1"
    [[ -z "$dir" ]] && { log_error "cleanup_directory requires a path"; return 1; }
    if [[ -d "$dir" ]]; then
        log_file_only "Removing directory: $dir"
        rm -rf "$dir"
        log_install_success "Directory removed: $(basename "$dir")"
    else
        log_file_only "Directory not found (already clean): $dir"
    fi
    return 0
}

delete_manifest() {
    local manifest="$1"
    local ns="${2:-default}"
    [[ -z "$manifest" ]] && { log_error "delete_manifest requires a manifest file"; return 1; }
    if [[ ! -f "$manifest" ]]; then
        log_file_only "Manifest not found (skipping): $manifest"
        return 0
    fi
    log_file_only "Deleting resources from: $manifest (namespace: $ns)"
    kubectl delete -f "$manifest" -n "$ns" --ignore-not-found=true >>"$LOG_FILE" 2>&1 || true
    log_install_success "${WORKLOAD_APP_NAME} workload deleted"
    return 0
}

terminate_demo() {
    local namespace="$1"
    local demo_dir="$2"
    local skip_installer="${3:-false}"

    if [[ -z "$namespace" || -z "$demo_dir" ]]; then
        log_error "terminate_demo requires namespace and demo_dir"
        return 1
    fi

    log_file_only "TERMINATE MODE — namespace: $namespace"

    # ── Step 1: Run installer teardown via install.sh --terminate ────────────
    # The installer script is named install.sh on the quarkus-rca branch.
    if [[ "$skip_installer" == "false" ]]; then
        log_section "Running installer cleanup (install.sh --terminate)"
        local installer_script="$demo_dir/installer/install.sh"
        if [[ -f "$installer_script" ]]; then
            log_file_only "Running: bash $installer_script --terminate -n $namespace"
            start_spinner "Running install.sh --terminate..."
            bash "$installer_script" --terminate -n "$namespace" 2>&1 \
                | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"
            local rc=${PIPESTATUS[0]}
            stop_spinner
            if [[ $rc -eq 0 ]]; then
                log_install_success "Installer cleanup"
            else
                log_file_only "Installer cleanup encountered issues — check log: $LOG_FILE"
            fi
        else
            log_file_only "Installer script not found: $installer_script — skipping"
            log_validation_success "Installer cleanup (skipped — script not found)"
        fi
    else
        log_file_only "Installer cleanup skipped (--skip-installer)"
    fi

    # ── Step 2: Delete quarkus-perf workload + load-gen + monitoring ─────────
    log_section "Deleting quarkus-perf workload"

    # Resolve manifests directory relative to the script that sources this lib
    local _manifest_dir
    _manifest_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/manifests"

    if check_namespace "$namespace"; then
        # Delete load-gen job first (doesn't have a static manifest path)
        start_spinner "Deleting load-gen job..."
        kubectl delete job quarkus-perf-load-gen -n "$namespace" \
            --ignore-not-found=true >>"$LOG_FILE" 2>&1 || true
        stop_spinner
        log_install_success "load-gen job deleted"

        # Delete monitoring resources
        local monitoring_manifest="$_manifest_dir/quarkus-perf-monitoring.yaml"
        start_spinner "Deleting monitoring rules..."
        if [[ -f "$monitoring_manifest" ]]; then
            kubectl delete -f "$monitoring_manifest" -n "$namespace" \
                --ignore-not-found=true >>"$LOG_FILE" 2>&1 || true
        fi
        stop_spinner
        log_install_success "monitoring rules deleted"

        # Delete workload
        local workload_manifest="$_manifest_dir/quarkus-perf-deploy.yaml"
        start_spinner "Deleting quarkus-perf deployment..."
        stop_spinner
        delete_manifest "$workload_manifest" "$namespace"
    else
        log_file_only "Namespace $namespace not found — skipping workload deletion"
        log_validation_success "quarkus-perf cleanup (skipped — namespace not found)"
    fi

    # ── Step 3: Remove cloned repos / artifacts ───────────────────────────────
    log_section "Removing cloned repositories"
    start_spinner "Removing artifacts..."
    stop_spinner
    cleanup_directory "$demo_dir"

    log_install_success "Cleanup completed"
    return 0
}

export -f cleanup_directory
export -f delete_manifest
export -f terminate_demo
