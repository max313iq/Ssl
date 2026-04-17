#!/bin/bash
# Hardened Docker + NVIDIA + trainer bootstrap for Azure Batch pool nodes
# - Idempotent setup
# - Network/apt retries
# - Optional Docker Hub auth
# - Lightweight container usage monitor with auto-restart
# - No hardcoded secrets

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
umask 022
SCRIPT_VERSION="2026-02-26-gpufix-580-server-1"

IMAGE="${IMAGE:-docker.io/riccorg/ml-compute-platform:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-ai-trainer}"

DOCKER_USERNAME="${DOCKER_USERNAME:-}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}"
DOCKER_PASSWORD_FILE="${DOCKER_PASSWORD_FILE:-}"

CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-90}"
CONSECUTIVE_LOW_USAGE_LIMIT="${CONSECUTIVE_LOW_USAGE_LIMIT:-5}"
LOW_CPU_THRESHOLD="${LOW_CPU_THRESHOLD:-0}"
LOW_GPU_THRESHOLD="${LOW_GPU_THRESHOLD:-0}"
RESTART_COOLDOWN_SECONDS="${RESTART_COOLDOWN_SECONDS:-45}"
USAGE_WARMUP_SECONDS="${USAGE_WARMUP_SECONDS:-180}"
IMAGE_CHECK_INTERVAL_SECONDS="${IMAGE_CHECK_INTERVAL_SECONDS:-600}"
MONITOR_LOG_FILE="${MONITOR_LOG_FILE:-/var/log/usage-monitor.log}"

INSTALL_NVIDIA_DRIVERS="${INSTALL_NVIDIA_DRIVERS:-auto}" # auto|true|false
ALLOW_REBOOT_AFTER_DRIVER_INSTALL="${ALLOW_REBOOT_AFTER_DRIVER_INSTALL:-false}"
FORCE_CONTAINER_RECREATE="${FORCE_CONTAINER_RECREATE:-false}"
FABRIC_MANAGER_ENABLE="${FABRIC_MANAGER_ENABLE:-auto}" # auto|true|false
CUDA_READY_WAIT_SECONDS="${CUDA_READY_WAIT_SECONDS:-120}"
REQUIRE_GPU_READY="${REQUIRE_GPU_READY:-true}"
NVIDIA_PREFERRED_MAJOR="${NVIDIA_PREFERRED_MAJOR:-580}"
NVIDIA_PREFERRED_FLAVOR="${NVIDIA_PREFERRED_FLAVOR:-server}" # server|standard
ENFORCE_NVIDIA_PREFERRED_MAJOR="${ENFORCE_NVIDIA_PREFERRED_MAJOR:-true}" # true keeps host stack aligned with preferred major
REQUIRE_PRECOMPILED_AZURE_NVIDIA_MODULES="${REQUIRE_PRECOMPILED_AZURE_NVIDIA_MODULES:-true}"
NVIDIA_DKMS_WAIT_SECONDS="${NVIDIA_DKMS_WAIT_SECONDS:-1200}"
NVIDIA_DRIVER_READY_WAIT_SECONDS="${NVIDIA_DRIVER_READY_WAIT_SECONDS:-240}"
NVIDIA_DRIVER_READY_RETRY_SECONDS="${NVIDIA_DRIVER_READY_RETRY_SECONDS:-5}"

STATE_DIR="/var/lib/ai-trainer-bootstrap"
LOCK_FILE="/var/run/ai-trainer-bootstrap.lock"
BOOTSTRAP_LOG="/var/log/ai-trainer-bootstrap.log"
MONITOR_SCRIPT_PATH="/usr/local/bin/usage-monitor"
MONITOR_SERVICE_PATH="/etc/systemd/system/usage-monitor.service"
APT_ACQUIRE_RETRIES="5"
APT_DPKG_USE_PTY="0"
MOK_RAND_FILE="/var/lib/shim-signed/mok/.rnd"

mkdir -p "$STATE_DIR"
mkdir -p /var/log
touch "$BOOTSTRAP_LOG"

if [[ "${EUID}" -eq 0 ]]; then
    SUDO=""
else
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        printf "%s [ERROR] This script must run as root or have sudo installed.\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$BOOTSTRAP_LOG"
        exit 1
    fi
fi

log() {
    local level="$1"
    shift
    local msg="$*"
    printf "%s [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" | tee -a "$BOOTSTRAP_LOG"
}

info() { log "INFO" "$*"; }
warn() { log "WARN" "$*"; }
error() { log "ERROR" "$*"; }

run_root() {
    if [[ "$#" -eq 0 ]]; then
        warn "run_root called without arguments; skipping."
        return 0
    fi
    if [[ -n "$SUDO" ]]; then
        "$SUDO" "$@"
    else
        "$@"
    fi
}

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

on_error() {
    local line="$1"
    local cmd="${2:-unknown}"
    local code="${3:-1}"
    error "Bootstrap failed at line $line (exit=$code, cmd=$cmd)"
}
trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

with_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        info "Another bootstrap instance is already running. Exiting cleanly."
        exit 0
    fi
}

retry() {
    local attempts="$1"
    local sleep_seconds="$2"
    shift 2
    local n=1
    while true; do
        if "$@"; then
            return 0
        fi
        if [[ "$n" -ge "$attempts" ]]; then
            return 1
        fi
        warn "Retry $n/$attempts failed for: $*"
        sleep "$sleep_seconds"
        n=$((n + 1))
    done
}

run_with_timeout() {
    local timeout_seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" "$@"
    else
        "$@"
    fi
}

wait_for_apt_locks() {
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
       || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
       || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [[ "$waited" -ge 300 ]]; then
            error "Timed out waiting for apt/dpkg lock"
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 0
}
recover_dpkg_state() {
    wait_for_apt_locks
    if run_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a dpkg --configure -a; then
        return 0
    fi

    warn "dpkg --configure -a failed; attempting apt dependency repair."
    wait_for_apt_locks
    if ! run_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -f -yq --no-install-recommends -o "Acquire::Retries=${APT_ACQUIRE_RETRIES}" -o "Dpkg::Use-Pty=${APT_DPKG_USE_PTY}"; then
        return 1
    fi

    wait_for_apt_locks
    run_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a dpkg --configure -a
}

apt_update() {
    wait_for_apt_locks
    recover_dpkg_state
    run_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -yq -o "Acquire::Retries=${APT_ACQUIRE_RETRIES}" -o "Dpkg::Use-Pty=${APT_DPKG_USE_PTY}"
}

apt_install() {
    wait_for_apt_locks
    recover_dpkg_state
    run_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -yq --no-install-recommends -o "Acquire::Retries=${APT_ACQUIRE_RETRIES}" -o "Dpkg::Use-Pty=${APT_DPKG_USE_PTY}" "$@"
}

docker_is_running() {
    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl is-active --quiet docker
        return $?
    fi
    pgrep -x dockerd >/dev/null 2>&1
}

gpu_present() {
    lspci | grep -qi nvidia || [[ -e /dev/nvidiactl || -e /dev/nvidia0 ]]
}
nvidia_smi_bin() {
    local smi=""
    smi="$(command -v nvidia-smi 2>/dev/null || true)"
    if [[ -n "$smi" ]]; then
        echo "$smi"
        return 0
    fi
    for smi in \
        /usr/bin/nvidia-smi \
        /bin/nvidia-smi \
        /usr/local/nvidia/bin/nvidia-smi \
        /usr/lib/nvidia*/bin/nvidia-smi \
        /usr/lib/nvidia*/nvidia-smi; do
        if [[ -x "$smi" ]]; then
            echo "$smi"
            return 0
        fi
    done
    smi="$(find /usr -type f -name nvidia-smi 2>/dev/null | head -1 || true)"
    if [[ -n "$smi" && -x "$smi" ]]; then
        echo "$smi"
        return 0
    fi

    return 1
}

ensure_nvidia_smi_command_path() {
    local smi=""
    smi="$(nvidia_smi_bin || true)"
    [[ -n "$smi" ]] || return 1

    if [[ "$smi" != "/usr/bin/nvidia-smi" ]]; then
        run_root ln -sf "$smi" /usr/bin/nvidia-smi || true
    fi

    run_root mkdir -p /etc/profile.d >/dev/null 2>&1 || true
    run_root bash -c "printf '%s\n' 'export PATH=/usr/bin:/usr/local/nvidia/bin:/usr/lib/nvidia/current/bin:\$PATH' > /etc/profile.d/nvidia-path.sh" || true
    run_root chmod 0644 /etc/profile.d/nvidia-path.sh >/dev/null 2>&1 || true

    command -v nvidia-smi >/dev/null 2>&1 || [[ -x /usr/bin/nvidia-smi ]]
}

nvidia_ready() {
    local smi=""
    smi="$(nvidia_smi_bin || true)"
    [[ -n "$smi" ]] || return 1
    "$smi" >/dev/null 2>&1
}

nvidia_driver_major() {
    local smi=""
    smi="$(nvidia_smi_bin || true)"
    [[ -n "$smi" ]] || return 1
    "$smi" --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
        | head -1 \
        | awk -F'.' '{print $1}' \
        | tr -dc '0-9'
}
running_azure_kernel() {
    uname -r 2>/dev/null | grep -qi '\-azure'
}
prepare_mok_rng_seed() {
    local mok_dir=""
    mok_dir="$(dirname "$MOK_RAND_FILE")"
    run_root mkdir -p "$mok_dir" >/dev/null 2>&1 || true
    if [[ ! -s "$MOK_RAND_FILE" ]]; then
        info "Creating MOK RNG seed file to avoid openssl RAND load warnings during DKMS signing."
        run_root dd if=/dev/urandom of="$MOK_RAND_FILE" bs=256 count=1 status=none >/dev/null 2>&1 || true
        run_root chmod 0600 "$MOK_RAND_FILE" >/dev/null 2>&1 || true
    fi
    export RANDFILE="$MOK_RAND_FILE"
    return 0
}
wait_for_nvidia_dkms_completion() {
    local -i timeout_seconds="${NVIDIA_DKMS_WAIT_SECONDS:-1200}"
    local -i retry_seconds="${NVIDIA_DRIVER_READY_RETRY_SECONDS:-5}"
    local -i waited=0
    local status_lines=""
    
    if [[ "$retry_seconds" -le 0 ]]; then
        retry_seconds=5
    fi
    if [[ "$timeout_seconds" -le 0 ]]; then
        return 0
    fi
    
    while [[ "$waited" -lt "$timeout_seconds" ]]; do
        status_lines="$(dkms status 2>/dev/null | grep -Ei '^nvidia' || true)"
        if [[ -z "$status_lines" ]]; then
            return 0
        fi
        if echo "$status_lines" | grep -Eqi '(added|building|installing|built)'; then
            info "Waiting for NVIDIA DKMS to finish (${waited}/${timeout_seconds}s)..."
            sleep "$retry_seconds"
            waited=$((waited + retry_seconds))
            continue
        fi
        return 0
    done
    
    warn "Timed out waiting for NVIDIA DKMS completion after ${timeout_seconds}s."
    return 1
}
wait_for_nvidia_driver_ready() {
    local -i timeout_seconds="${NVIDIA_DRIVER_READY_WAIT_SECONDS:-240}"
    local -i retry_seconds="${NVIDIA_DRIVER_READY_RETRY_SECONDS:-5}"
    local -i waited=0
    
    if [[ "$retry_seconds" -le 0 ]]; then
        retry_seconds=5
    fi
    
    while [[ "$waited" -lt "$timeout_seconds" ]]; do
        run_root modprobe nvidia >/dev/null 2>&1 || true
        run_root modprobe nvidia_uvm >/dev/null 2>&1 || true
        if nvidia_ready; then
            return 0
        fi
        sleep "$retry_seconds"
        waited=$((waited + retry_seconds))
    done
    
    return 1
}
install_precompiled_nvidia_modules_if_available() {
    local major="${1:-}"
    local flavor="${2:-server}"
    local -a candidates=()
    local pkg=""
    
    [[ -n "$major" ]] || return 1
    if ! running_azure_kernel; then
        return 1
    fi
    
    if [[ "$flavor" == "server" ]]; then
        candidates=("linux-modules-nvidia-${major}-server-azure")
    else
        candidates=("linux-modules-nvidia-${major}-azure")
    fi
    
    for pkg in "${candidates[@]}"; do
        if ! package_available "$pkg"; then
            continue
        fi
        info "Installing precompiled NVIDIA kernel modules for Azure kernel: $pkg"
        if retry 2 15 apt_install "$pkg"; then
            return 0
        fi
    done
    
    warn "No precompiled Azure NVIDIA module package installed for major=${major} flavor=${flavor}; DKMS build path will be used."
    return 1
}
verify_preferred_nvidia_alignment() {
    local preferred_major="${NVIDIA_PREFERRED_MAJOR:-580}"
    local preferred_flavor="${NVIDIA_PREFERRED_FLAVOR,,}"
    local active_major=""
    
    [[ -n "$preferred_major" ]] || return 1
    active_major="$(nvidia_driver_major || true)"
    [[ -n "$active_major" ]] || return 1
    
    if [[ "$active_major" != "$preferred_major" ]]; then
        return 1
    fi
    
    if [[ "$preferred_flavor" == "server" ]]; then
        if package_installed "nvidia-driver-${preferred_major}-server" \
            || package_installed "nvidia-headless-no-dkms-${preferred_major}-server"; then
            return 0
        fi
        return 1
    fi
    
    return 0
}

gpu_is_h100() {
    local smi=""
    smi="$(nvidia_smi_bin || true)"
    if [[ -n "$smi" ]]; then
        if "$smi" --query-gpu=name --format=csv,noheader 2>/dev/null | grep -qi 'H100'; then
            return 0
        fi
    fi
    lspci 2>/dev/null | grep -qi 'H100'
}

should_enable_fabric_manager() {
    case "${FABRIC_MANAGER_ENABLE:-auto}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        auto|AUTO)
            gpu_is_h100
            return $?
            ;;
        *)
            return 1
            ;;
    esac
}

package_available() {
    apt-cache show "$1" >/dev/null 2>&1
}
package_installed() {
    local pkg="$1"
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed'
}

detect_nvidia_userland_flavor() {
    local major="${1:-}"
    if [[ -z "$major" ]]; then
        echo "standard"
        return 0
    fi

    if package_installed "nvidia-utils-${major}-server" \
        || package_installed "nvidia-compute-utils-${major}-server" \
        || package_installed "libnvidia-compute-${major}-server"; then
        echo "server"
        return 0
    fi

    if package_installed "nvidia-utils-${major}" \
        || package_installed "nvidia-compute-utils-${major}" \
        || package_installed "libnvidia-compute-${major}"; then
        echo "standard"
        return 0
    fi

    if dpkg -l 2>/dev/null | awk '/^ii[[:space:]]+nvidia-driver-[0-9]+-server([[:space:]]|$)/{found=1} END{exit(found?0:1)}'; then
        echo "server"
        return 0
    fi

    echo "standard"
    return 0
}

install_nvidia_userland_for_major() {
    local major="${1:-}"
    local flavor="${2:-standard}"
    local -a candidates=()
    local pkg=""

    [[ -n "$major" ]] || return 1

    if [[ "$flavor" == "server" ]]; then
        candidates=("nvidia-utils-${major}-server" "nvidia-compute-utils-${major}-server")
    else
        candidates=("nvidia-utils-${major}" "nvidia-compute-utils-${major}")
    fi

    for pkg in "${candidates[@]}"; do
        if ! package_available "$pkg"; then
            continue
        fi
        info "Trying flavor-aware nvidia-smi recovery package: $pkg"
        if retry 2 10 apt_install "$pkg"; then
            ensure_nvidia_smi_command_path || true
            if [[ -n "$(nvidia_smi_bin || true)" ]]; then
                return 0
            fi
        fi
    done

    return 1
}

enable_restricted_repos_if_needed() {
    if ! command -v add-apt-repository >/dev/null 2>&1; then
        return 0
    fi
    run_root add-apt-repository -y restricted >/dev/null 2>&1 || true
    run_root add-apt-repository -y multiverse >/dev/null 2>&1 || true
}

install_nvidia_smi_packages() {
    local major="${1:-}"
    local preferred_major="${NVIDIA_PREFERRED_MAJOR:-580}"
    local preferred_flavor="${NVIDIA_PREFERRED_FLAVOR,,}"
    local -a candidates=()
    local pkg=""
    if [[ -n "$preferred_major" ]]; then
        if [[ "$preferred_flavor" == "standard" ]]; then
            candidates+=(
                "nvidia-utils-${preferred_major}"
                "nvidia-compute-utils-${preferred_major}"
                "nvidia-utils-${preferred_major}-server"
                "nvidia-compute-utils-${preferred_major}-server"
            )
        else
            candidates+=(
                "nvidia-utils-${preferred_major}-server"
                "nvidia-compute-utils-${preferred_major}-server"
                "nvidia-utils-${preferred_major}"
                "nvidia-compute-utils-${preferred_major}"
            )
        fi
    fi

    if [[ -n "$major" ]]; then
        candidates+=(
            "nvidia-utils-${major}-server"
            "nvidia-utils-${major}"
            "nvidia-compute-utils-${major}-server"
            "nvidia-compute-utils-${major}"
        )
    fi
    if ! is_truthy "$ENFORCE_NVIDIA_PREFERRED_MAJOR"; then
        candidates+=(
            nvidia-utils-580-server nvidia-utils-580 nvidia-compute-utils-580-server nvidia-compute-utils-580
            nvidia-utils-570-server nvidia-utils-570 nvidia-compute-utils-570-server nvidia-compute-utils-570
            nvidia-utils-550-server nvidia-utils-550 nvidia-compute-utils-550-server nvidia-compute-utils-550
            nvidia-utils-535-server nvidia-utils-535 nvidia-compute-utils-535-server nvidia-compute-utils-535
            nvidia-utils-525-server nvidia-utils-525 nvidia-compute-utils-525-server nvidia-compute-utils-525
            nvidia-utils-510-server nvidia-utils-510 nvidia-compute-utils-510-server nvidia-compute-utils-510
            nvidia-utils-470-server nvidia-utils-470 nvidia-compute-utils-470-server nvidia-compute-utils-470
        )
    fi

    for pkg in "${candidates[@]}"; do
        if [[ -n "$(nvidia_smi_bin || true)" ]]; then
            return 0
        fi
        info "Trying package for nvidia-smi: $pkg"
        if retry 1 5 apt_install "$pkg"; then
            ensure_nvidia_smi_command_path || true
            if [[ -n "$(nvidia_smi_bin || true)" ]]; then
                info "nvidia-smi package install succeeded with: $pkg"
                return 0
            fi
        else
            warn "Package install attempt failed for: $pkg"
        fi
    done

    [[ -n "$(nvidia_smi_bin || true)" ]]
}

install_explicit_nvidia_driver_fallback() {
    info "Attempting explicit NVIDIA driver fallback package installation..."
    retry 5 10 apt_update || true
    local preferred_major="${NVIDIA_PREFERRED_MAJOR:-580}"
    local preferred_flavor="${NVIDIA_PREFERRED_FLAVOR,,}"
    local -a candidates=()
    if [[ -n "$preferred_major" ]]; then
        if [[ "$preferred_flavor" == "standard" ]]; then
            candidates+=("nvidia-driver-${preferred_major}" "nvidia-driver-${preferred_major}-server")
        else
            candidates+=("nvidia-driver-${preferred_major}-server" "nvidia-driver-${preferred_major}")
        fi
    fi
    if ! is_truthy "$ENFORCE_NVIDIA_PREFERRED_MAJOR"; then
        candidates+=(
            nvidia-driver-580-server nvidia-driver-580
            nvidia-driver-570-server nvidia-driver-570
            nvidia-driver-550-server nvidia-driver-550
            nvidia-driver-535-server nvidia-driver-535
            nvidia-driver-525-server nvidia-driver-525
            nvidia-driver-510-server nvidia-driver-510
            nvidia-driver-470-server nvidia-driver-470
        )
    fi
    local pkg=""
    for pkg in "${candidates[@]}"; do
        if package_available "$pkg"; then
            if retry 2 15 apt_install "$pkg"; then
                return 0
            fi
        fi
    done
    return 1
}

ensure_nvidia_smi_binary() {
    local smi=""
    smi="$(nvidia_smi_bin || true)"
    if [[ -n "$smi" ]] && "$smi" >/dev/null 2>&1; then
        ensure_nvidia_smi_command_path || true
        return 0
    fi

    warn "nvidia-smi is missing on host. Attempting to install NVIDIA userland utilities."
    enable_restricted_repos_if_needed
    retry 5 10 apt_update

    local major pkg
    local preferred_major="${NVIDIA_PREFERRED_MAJOR:-580}"
    local preferred_flavor="${NVIDIA_PREFERRED_FLAVOR,,}"
    local -a major_pkg_candidates=()
    major="$(ubuntu-drivers devices 2>/dev/null | grep -o 'nvidia-driver-[0-9]\+' | head -1 | awk -F'-' '{print $3}' | tr -dc '0-9' || true)"
    if is_truthy "$ENFORCE_NVIDIA_PREFERRED_MAJOR" && [[ -n "$preferred_major" ]]; then
        major="$preferred_major"
        info "Using enforced NVIDIA major for nvidia-smi recovery: $major (${preferred_flavor})."
    elif [[ -z "$major" && -n "$preferred_major" ]]; then
        major="$preferred_major"
        info "No NVIDIA major auto-detected; defaulting nvidia-smi recovery to: $major (${preferred_flavor})."
    fi
    if [[ -n "$major" ]]; then
        if [[ "$preferred_flavor" == "standard" ]]; then
            major_pkg_candidates=(
                "nvidia-utils-${major}" "nvidia-compute-utils-${major}"
                "nvidia-utils-${major}-server" "nvidia-compute-utils-${major}-server"
            )
        else
            major_pkg_candidates=(
                "nvidia-utils-${major}-server" "nvidia-compute-utils-${major}-server"
                "nvidia-utils-${major}" "nvidia-compute-utils-${major}"
            )
        fi
        for pkg in "${major_pkg_candidates[@]}"; do
            if package_available "$pkg"; then
                if retry 3 10 apt_install "$pkg"; then
                    break
                fi
            fi
        done
    fi

    if [[ -z "$(nvidia_smi_bin || true)" ]]; then
        install_nvidia_smi_packages "$major" || true
    fi
    smi="$(nvidia_smi_bin || true)"
    if [[ -n "$smi" ]]; then
        ensure_nvidia_smi_command_path || true
        smi="$(nvidia_smi_bin || true)"
    fi

    if [[ -n "$smi" ]] && "$smi" >/dev/null 2>&1; then
        info "nvidia-smi installed successfully at $smi."
        return 0
    fi

    warn "Unable to install nvidia-smi automatically."
    return 1
}

ensure_nvidia_fabric_manager() {
    if ! should_enable_fabric_manager; then
        info "FABRIC_MANAGER_ENABLE=$FABRIC_MANAGER_ENABLE; skipping fabric manager setup."
        return 0
    fi

    if ! nvidia_ready; then
        return 0
    fi

    local smi gpu_count is_h100=0
    smi="$(nvidia_smi_bin || true)"
    [[ -n "$smi" ]] || return 0
    if gpu_is_h100; then
        is_h100=1
    fi

    if dpkg -l 2>/dev/null | awk '/^ii[[:space:]]+nvidia-driver-[0-9]+-open([[:space:]]|$)/{found=1} END{exit(found?0:1)}'; then
        if [[ "$is_h100" -eq 1 ]]; then
            warn "Open NVIDIA driver stack detected on H100; proceeding with flavor-aware fabric manager installation."
        else
            warn "Open NVIDIA driver stack detected; skipping fabric manager to avoid package transitions that can remove nvidia-smi."
            return 0
        fi
    fi

    if [[ "$is_h100" -ne 1 ]]; then
        if ! "$smi" -q 2>/dev/null | grep -q '^[[:space:]]*Fabric$'; then
            info "No NVIDIA fabric section detected; skipping fabric manager."
            return 0
        fi
        gpu_count="$("$smi" --query-gpu=count --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')"
        if [[ -z "$gpu_count" || "$gpu_count" -lt 2 ]]; then
            info "Single/no GPU detected; fabric manager not required."
            return 0
        fi
    else
        info "H100 detected; enabling fabric manager."
    fi

    local major pkg selected="" pre_flavor="standard"
    major="$(nvidia_driver_major || true)"
    local -a candidates=()
    if [[ -n "$major" ]]; then
        pre_flavor="$(detect_nvidia_userland_flavor "$major")"
        info "Detected NVIDIA userland flavor before fabric manager install: $pre_flavor"
    fi

    if [[ -n "$major" ]]; then
        candidates+=("nvidia-fabricmanager-${major}" "cuda-drivers-fabricmanager-${major}")
    fi
    candidates+=("nvidia-fabricmanager")

    retry 5 10 apt_update
    for pkg in "${candidates[@]}"; do
        if package_available "$pkg"; then
            info "Installing NVIDIA Fabric Manager package: $pkg"
            if retry 3 10 apt_install "$pkg"; then
                selected="$pkg"
                break
            fi
        fi
    done

    if [[ -z "$selected" ]]; then
        warn "No installable NVIDIA Fabric Manager package found. CUDA error 802 may persist on NVSwitch hosts."
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl daemon-reload || true
        run_root systemctl enable nvidia-fabricmanager >/dev/null 2>&1 || true
        run_root systemctl restart nvidia-fabricmanager >/dev/null 2>&1 || true
        if retry 20 3 run_root systemctl is-active --quiet nvidia-fabricmanager; then
            info "NVIDIA Fabric Manager is active."
        else
            warn "NVIDIA Fabric Manager service did not become active."
        fi
    else
        run_root service nvidia-fabricmanager restart >/dev/null 2>&1 || true
    fi

    if ! ensure_nvidia_smi_binary; then
        warn "nvidia-smi became unavailable after fabric manager installation; running flavor-aware recovery."
        if [[ -n "$major" ]]; then
            retry 3 10 apt_update || true
            if ! install_nvidia_userland_for_major "$major" "$pre_flavor"; then
                local fallback_flavor="server"
                if [[ "$pre_flavor" == "server" ]]; then
                    fallback_flavor="standard"
                fi
                install_nvidia_userland_for_major "$major" "$fallback_flavor" || true
            fi
        fi
        if ! ensure_nvidia_smi_binary; then
            warn "nvidia-smi is still unavailable after post-fabric-manager recovery."
        fi
    fi
}

cuda_fabric_state_ok() {
    if ! nvidia_ready; then
        return 1
    fi

    local smi states state
    smi="$(nvidia_smi_bin || true)"
    [[ -n "$smi" ]] || return 1
    states="$("$smi" -q 2>/dev/null | awk '/^[[:space:]]*Fabric$/ {fabric=1; next} fabric && /^[[:space:]]*State[[:space:]]*:/ {print $3; fabric=0}')"
    if [[ -z "$states" ]]; then
        return 0
    fi

    while read -r state; do
        [[ -z "$state" ]] && continue
        case "$state" in
            Completed|N/A|NA|Disabled) ;;
            *) return 1 ;;
        esac
    done <<< "$states"

    return 0
}

wait_for_cuda_ready() {
    if ! nvidia_ready; then
        return 0
    fi

    local waited=0
    while [[ "$waited" -lt "$CUDA_READY_WAIT_SECONDS" ]]; do
        if cuda_fabric_state_ok; then
            info "CUDA fabric state is ready."
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done

    warn "CUDA fabric did not become ready within ${CUDA_READY_WAIT_SECONDS}s. CUDA error 802 may occur."
    return 0
}

ensure_base_packages() {
    info "Ensuring required base packages are installed..."
    retry 5 10 apt_update
    retry 5 10 apt_install \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        ubuntu-drivers-common \
        dkms \
        jq \
        util-linux \
        psmisc \
        pciutils
    enable_restricted_repos_if_needed
    retry 5 10 apt_update || true
    retry 2 5 apt_install "linux-headers-$(uname -r)" || warn "Could not install linux-headers-$(uname -r); continuing."
    retry 2 5 apt_install linux-headers-azure || warn "Could not install linux-headers-azure; continuing."
    retry 2 5 apt_install linux-modules-extra-azure || warn "Could not install linux-modules-extra-azure; continuing."
}

ensure_docker() {
    if command -v docker >/dev/null 2>&1 && docker_is_running; then
        info "Docker already installed and running."
        return 0
    fi

    info "Installing Docker..."
    retry 5 10 apt_update
    retry 5 10 apt_install docker.io

    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl daemon-reload || true
        run_root systemctl enable docker
        run_root systemctl start docker
    else
        run_root service docker start || true
        if ! pgrep -x dockerd >/dev/null 2>&1; then
            run_root dockerd >/var/log/dockerd.log 2>&1 &
            sleep 3
        fi
    fi

    retry 20 3 docker_is_running
    info "Docker is active."
}

docker_login() {
    if [[ -z "$DOCKER_PASSWORD" && -n "$DOCKER_PASSWORD_FILE" && -r "$DOCKER_PASSWORD_FILE" ]]; then
        DOCKER_PASSWORD="$(<"$DOCKER_PASSWORD_FILE")"
    fi
    if [[ -z "$DOCKER_USERNAME" || -z "$DOCKER_PASSWORD" ]]; then
        warn "Docker credentials not provided via environment variables; proceeding without login."
        return 0
    fi

    info "Attempting Docker login for user: $DOCKER_USERNAME"
    if printf '%s' "$DOCKER_PASSWORD" | run_root docker login docker.io --username "$DOCKER_USERNAME" --password-stdin >/dev/null 2>&1; then
        info "Docker login successful."
        return 0
    fi

    warn "Docker login failed; continuing (image pull may fail if private/rate-limited)."
    return 0
}

ensure_nvidia_runtime() {
    local preferred_major preferred_flavor active_major
    local -i enforce_preferred_install=0
    local -i require_precompiled_modules=0
    preferred_major="${NVIDIA_PREFERRED_MAJOR:-580}"
    preferred_flavor="${NVIDIA_PREFERRED_FLAVOR,,}"
    if is_truthy "$REQUIRE_PRECOMPILED_AZURE_NVIDIA_MODULES" && running_azure_kernel && is_truthy "$ENFORCE_NVIDIA_PREFERRED_MAJOR"; then
        require_precompiled_modules=1
    fi
    if ! gpu_present; then
        warn "No NVIDIA GPU detected via lspci. Skipping NVIDIA runtime setup."
        return 0
    fi

    info "NVIDIA GPU detected."
    if ! ensure_nvidia_smi_binary; then
        warn "nvidia-smi is not ready yet; continuing with driver installation path."
    fi
    if is_truthy "$ENFORCE_NVIDIA_PREFERRED_MAJOR" && [[ -n "$preferred_major" ]]; then
        if ! verify_preferred_nvidia_alignment; then
            active_major="$(nvidia_driver_major || true)"
            warn "Preferred NVIDIA alignment not satisfied (active_major=${active_major:-none}, preferred_major=${preferred_major}, preferred_flavor=${preferred_flavor}); enforcing reinstall path."
            enforce_preferred_install=1
        else
            info "Preferred NVIDIA alignment already satisfied (major=${preferred_major}, flavor=${preferred_flavor})."
        fi
    fi

    if [[ "$enforce_preferred_install" -eq 1 ]] || ! nvidia_ready; then
        case "$INSTALL_NVIDIA_DRIVERS" in
            true|TRUE|yes|YES|on|ON|auto|AUTO)
                info "Attempting NVIDIA driver installation..."
                retry 5 10 apt_update
                retry 5 10 apt_install ubuntu-drivers-common
                prepare_mok_rng_seed || true
                if [[ -n "$preferred_major" ]]; then
                    if ! install_precompiled_nvidia_modules_if_available "$preferred_major" "$preferred_flavor"; then
                        if [[ "$require_precompiled_modules" -eq 1 ]]; then
                            error "Required precompiled Azure NVIDIA modules were not available for major=${preferred_major} flavor=${preferred_flavor}."
                            return 1
                        fi
                    fi
                fi
                # Strict mode: bypass ubuntu-drivers recommendation (often 535) and force preferred branch/flavor.
                if is_truthy "$ENFORCE_NVIDIA_PREFERRED_MAJOR" && [[ -n "$preferred_major" ]]; then
                    info "ENFORCE_NVIDIA_PREFERRED_MAJOR=true; skipping ubuntu-drivers autoinstall and forcing preferred install (major=${preferred_major}, flavor=${preferred_flavor})."
                    if ! install_explicit_nvidia_driver_fallback; then
                        error "Failed to install preferred NVIDIA driver branch ${preferred_major} (flavor=${preferred_flavor})."
                        if is_truthy "$REQUIRE_GPU_READY"; then
                            return 1
                        fi
                    fi
                else
                    # Non-strict mode: use distro recommendation first, then fallback.
                    if ! run_root ubuntu-drivers autoinstall; then
                        warn "ubuntu-drivers autoinstall failed; trying fallback package selection."
                        local fallback_driver candidate
                        fallback_driver=""
                        if [[ -n "$preferred_major" ]]; then
                            if [[ "$preferred_flavor" == "standard" ]]; then
                                for candidate in "nvidia-driver-${preferred_major}" "nvidia-driver-${preferred_major}-server"; do
                                    if package_available "$candidate"; then
                                        fallback_driver="$candidate"
                                        break
                                    fi
                                done
                            else
                                for candidate in "nvidia-driver-${preferred_major}-server" "nvidia-driver-${preferred_major}"; do
                                    if package_available "$candidate"; then
                                        fallback_driver="$candidate"
                                        break
                                    fi
                                done
                            fi
                        fi
                        if [[ -z "$fallback_driver" ]]; then
                            fallback_driver="$(ubuntu-drivers list 2>/dev/null | grep -Eo 'nvidia-driver-[0-9]+(-server)?' | head -1 || true)"
                        fi
                        if [[ -n "$fallback_driver" ]]; then
                            retry 3 10 apt_install "$fallback_driver"
                        else
                            warn "No fallback NVIDIA driver package found."
                        fi
                    fi
                fi

                if ! nvidia_ready; then
                    if [[ -n "$preferred_major" ]]; then
                        if ! install_precompiled_nvidia_modules_if_available "$preferred_major" "$preferred_flavor"; then
                            if [[ "$require_precompiled_modules" -eq 1 ]]; then
                                error "Required precompiled Azure NVIDIA modules were not available in recovery path for major=${preferred_major} flavor=${preferred_flavor}."
                                return 1
                            fi
                        fi
                    fi
                    install_explicit_nvidia_driver_fallback || true
                    install_nvidia_smi_packages "" || true
                fi
                wait_for_nvidia_dkms_completion || true
                run_root modprobe nvidia >/dev/null 2>&1 || true
                run_root modprobe nvidia_uvm >/dev/null 2>&1 || true
                if ! wait_for_nvidia_driver_ready; then
                    warn "NVIDIA driver modules did not become ready within ${NVIDIA_DRIVER_READY_WAIT_SECONDS}s."
                fi

                if ! nvidia_ready; then
                    warn "NVIDIA driver install completed but nvidia-smi is not ready yet."
                    if is_truthy "$ALLOW_REBOOT_AFTER_DRIVER_INSTALL"; then
                        warn "Scheduling reboot in 1 minute to finalize NVIDIA drivers; returning failure so start task retries."
                        run_root shutdown -r +1 || true
                        return 1
                    elif is_truthy "$REQUIRE_GPU_READY"; then
                        error "NVIDIA driver appears installed but not active yet (reboot likely required). Set ALLOW_REBOOT_AFTER_DRIVER_INSTALL=true for automatic recovery."
                        return 1
                    fi
                fi
                ;;
            *)
                warn "INSTALL_NVIDIA_DRIVERS=$INSTALL_NVIDIA_DRIVERS; skipping driver installation."
                ;;
        esac
    fi

    if is_truthy "$ENFORCE_NVIDIA_PREFERRED_MAJOR" && [[ -n "$preferred_major" ]]; then
        if ! verify_preferred_nvidia_alignment; then
            active_major="$(nvidia_driver_major || true)"
            error "Preferred NVIDIA alignment check failed after install path (active_major=${active_major:-none}, preferred_major=${preferred_major}, preferred_flavor=${preferred_flavor})."
            if is_truthy "$REQUIRE_GPU_READY"; then
                return 1
            fi
        else
            info "Preferred NVIDIA alignment verified (major=${preferred_major}, flavor=${preferred_flavor})."
        fi
    fi

    if ! ensure_nvidia_smi_binary; then
        if is_truthy "$REQUIRE_GPU_READY"; then
            error "nvidia-smi is still unavailable after driver setup and REQUIRE_GPU_READY=$REQUIRE_GPU_READY."
            return 1
        fi
    fi

    if ! nvidia_ready; then
        if is_truthy "$REQUIRE_GPU_READY"; then
            error "NVIDIA runtime is not ready and REQUIRE_GPU_READY=$REQUIRE_GPU_READY. Aborting bootstrap."
            return 1
        fi
        warn "NVIDIA runtime not ready; container will run without --gpus until drivers are available."
        return 0
    fi

    info "Installing NVIDIA Container Toolkit..."
    local distribution
    distribution="$(
        if [[ -r /etc/os-release ]]; then
            . /etc/os-release
            printf '%s%s' "${ID:-ubuntu}" "${VERSION_ID:-22.04}"
        else
            printf 'ubuntu22.04'
        fi
    )"

    run_root mkdir -p /usr/share/keyrings /etc/apt/sources.list.d

    local key_tmp list_tmp signed_list_tmp repo_url fallback_repo_url
    key_tmp="$(mktemp)"
    list_tmp="$(mktemp)"
    signed_list_tmp="$(mktemp)"
    repo_url="https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list"
    fallback_repo_url="https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"

    retry 5 5 curl -fsSL "https://nvidia.github.io/libnvidia-container/gpgkey" -o "$key_tmp"
    run_root gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg "$key_tmp"

    if ! retry 5 5 curl -fsSL "$repo_url" -o "$list_tmp"; then
        warn "Could not fetch NVIDIA repo for distribution=${distribution}; falling back to generic stable repo."
        retry 5 5 curl -fsSL "$fallback_repo_url" -o "$list_tmp"
    fi
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' "$list_tmp" > "$signed_list_tmp"
    run_root install -m 0644 "$signed_list_tmp" /etc/apt/sources.list.d/nvidia-container-toolkit.list

    rm -f "$key_tmp" "$list_tmp" "$signed_list_tmp"

    retry 5 10 apt_update
    retry 5 10 apt_install nvidia-container-toolkit

    run_root nvidia-ctk runtime configure --runtime=docker
    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl restart docker
    else
        run_root service docker restart || true
    fi
    retry 20 3 docker_is_running
    ensure_nvidia_fabric_manager
    if ! ensure_nvidia_smi_binary; then
        if is_truthy "$REQUIRE_GPU_READY"; then
            error "nvidia-smi missing after fabric manager/runtime setup and REQUIRE_GPU_READY=$REQUIRE_GPU_READY."
            return 1
        fi
    fi
    wait_for_cuda_ready
    local host_smi_path=""
    host_smi_path="$(nvidia_smi_bin || true)"
    if [[ -n "$host_smi_path" ]]; then
        info "Host nvidia-smi detected at: $host_smi_path"
    fi
    info "NVIDIA container runtime configured."
}


create_usage_monitor_script_legacy() {
    create_usage_monitor_script_latest
    return 0
    local tmp_script
    tmp_script="$(mktemp)"
    cat > "$tmp_script" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
IMAGE="docker.io/riccorg/ml-compute-platform:latest"
CONTAINER_NAME="ai-trainer"
CHECK_INTERVAL_SECONDS="90"
CONSECUTIVE_LOW_USAGE_LIMIT="5"
LOW_CPU_THRESHOLD="2"
LOW_GPU_THRESHOLD="1"
RESTART_COOLDOWN_SECONDS="45"
MONITOR_LOG_FILE="/var/log/usage-monitor.log"
LOCK_FILE="/var/run/usage-monitor.lock"
LOG_MAX_SIZE_BYTES=10485760
NVIDIA_QUERY_TIMEOUT_SECONDS=10

mkdir -p "$(dirname "$MONITOR_LOG_FILE")"
touch "$MONITOR_LOG_FILE"

cap_log_file_size() {
    local file_size=0
    file_size=$(stat -c%s "$MONITOR_LOG_FILE" 2>/dev/null || wc -c < "$MONITOR_LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$file_size" -gt "$LOG_MAX_SIZE_BYTES" ]]; then
        tail -n 1000 "$MONITOR_LOG_FILE" > "${MONITOR_LOG_FILE}.tmp" 2>/dev/null || true
        if [[ -f "${MONITOR_LOG_FILE}.tmp" ]]; then
            mv -f "${MONITOR_LOG_FILE}.tmp" "$MONITOR_LOG_FILE" 2>/dev/null || :
        fi
    fi
}

log() {
    cap_log_file_size
    printf "%s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$MONITOR_LOG_FILE"
}

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

is_container_running() {
    docker ps --filter "name=^/${CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"
}

is_container_existing() {
    docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"
}

has_gpu() {
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1
}

start_container() {
    local -a args=(run -d --restart always --name "$CONTAINER_NAME" --log-opt max-size=10m --log-opt max-file=5)
    if has_gpu; then
        args+=(--gpus all)
        local host_smi=""
        host_smi="$(command -v nvidia-smi 2>/dev/null || true)"
        if [[ -n "$host_smi" && -x "$host_smi" ]]; then
            args+=(-v "$host_smi:/usr/bin/nvidia-smi:ro")
        fi
    fi
    args+=("$IMAGE")
    docker "${args[@]}" >/dev/null
}

ensure_container_running() {
    if is_container_running; then
        return 0
    fi

    if is_container_existing; then
        log "Container exists but is not running. Starting it."
        docker start "$CONTAINER_NAME" >/dev/null || true
        sleep 5
        if is_container_running; then
            return 0
        fi
        log "docker start failed, recreating container."
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    log "Launching container: $CONTAINER_NAME"
    start_container || return 1
    sleep 5
    is_container_running
}

get_cpu_int() {
    local cpu
    cpu="$(docker stats --no-stream --format '{{.CPUPerc}}' "$CONTAINER_NAME" 2>/dev/null | tr -d '%' || true)"
    if [[ -z "$cpu" ]]; then
        echo 0
        return 0
    fi
    printf "%.0f\n" "$cpu" 2>/dev/null || echo 0
}

get_gpu_int() {
    if ! has_gpu; then
        echo -1
        return 0
    fi

    local util
    util="$(timeout "$NVIDIA_QUERY_TIMEOUT_SECONDS" nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | awk '{sum+=$1; c++} END {if(c>0) print int(sum/c); else print 0}')"
    if [[ -z "$util" ]]; then
        echo 0
    else
        echo "$util"
    fi
}

restart_container() {
    log "Restarting container $CONTAINER_NAME due to sustained low activity."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if ! start_container; then
        log "Container restart failed."
        return 1
    fi
    log "Container restart successful."
    sleep "$RESTART_COOLDOWN_SECONDS"
    return 0
}

main() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0

    local low_count=0
    log "Usage monitor started for container=$CONTAINER_NAME image=$IMAGE"

    while true; do
        if ! ensure_container_running; then
            log "Failed to ensure container is running. Retrying after interval."
            sleep "$CHECK_INTERVAL_SECONDS"
            continue
        fi

        local cpu gpu
        cpu="$(get_cpu_int)"
        gpu="$(get_gpu_int)"

        log "Usage sample: cpu=${cpu}% gpu=${gpu}%"

        local cpu_low=0
        local gpu_low=0
        [[ "$cpu" -le "$LOW_CPU_THRESHOLD" ]] && cpu_low=1

        if [[ "$gpu" -lt 0 ]]; then
            gpu_low=1
        elif [[ "$gpu" -le "$LOW_GPU_THRESHOLD" ]]; then
            gpu_low=1
        fi

        if [[ "$cpu_low" -eq 1 && "$gpu_low" -eq 1 ]]; then
            low_count=$((low_count + 1))
            log "Low activity count ${low_count}/${CONSECUTIVE_LOW_USAGE_LIMIT}"
            if [[ "$low_count" -ge "$CONSECUTIVE_LOW_USAGE_LIMIT" ]]; then
                restart_container || true
                low_count=0
            fi
        else
            low_count=0
        fi

        sleep "$CHECK_INTERVAL_SECONDS"
    done
}

main "$@"
EOF
    run_root install -m 0755 "$tmp_script" "$MONITOR_SCRIPT_PATH"
    rm -f "$tmp_script"
}

create_usage_monitor_script_latest() {
    local tmp_script
    tmp_script="$(mktemp)"
    cat > "$tmp_script" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
IMAGE="docker.io/riccorg/ml-compute-platform:latest"
CONTAINER_NAME="ai-trainer"
CHECK_INTERVAL_SECONDS="90"
CONSECUTIVE_LOW_USAGE_LIMIT="5"
LOW_CPU_THRESHOLD="0"
LOW_GPU_THRESHOLD="0"
RESTART_COOLDOWN_SECONDS="45"
USAGE_WARMUP_SECONDS="180"
IMAGE_CHECK_INTERVAL_SECONDS="600"
MONITOR_LOG_FILE="/var/log/usage-monitor.log"
LOCK_FILE="/var/run/usage-monitor.lock"
LOG_MAX_SIZE_BYTES=10485760
DOCKER_STATS_TIMEOUT_SECONDS=15
NVIDIA_QUERY_TIMEOUT_SECONDS=10
PULL_RETRIES=3
PULL_RETRY_SLEEP_SECONDS=15
UNHEALTHY_STREAK_LIMIT=3
DOCKER_RECOVERY_STREAK_LIMIT=3
REQUIRE_GPU_READY="${REQUIRE_GPU_READY:-true}"

cpu_low_count=0
gpu_low_count=0
usage_grace_until=0
last_image_check_epoch=0
health_unhealthy_count=0
docker_not_ready_count=0

mkdir -p "$(dirname "$MONITOR_LOG_FILE")"
touch "$MONITOR_LOG_FILE"

cap_log_file_size() {
    local file_size=0
    file_size=$(stat -c%s "$MONITOR_LOG_FILE" 2>/dev/null || wc -c < "$MONITOR_LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$file_size" -gt "$LOG_MAX_SIZE_BYTES" ]]; then
        tail -n 1000 "$MONITOR_LOG_FILE" > "${MONITOR_LOG_FILE}.tmp" 2>/dev/null || true
        if [[ -f "${MONITOR_LOG_FILE}.tmp" ]]; then
            mv -f "${MONITOR_LOG_FILE}.tmp" "$MONITOR_LOG_FILE" 2>/dev/null || :
        fi
    fi
}

log() {
    cap_log_file_size
    printf "%s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$MONITOR_LOG_FILE"
}
is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

run_with_timeout() {
    local timeout_seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" "$@"
    else
        "$@"
    fi
}

docker_ready() {
    docker info >/dev/null 2>&1
}

try_recover_docker_daemon() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart docker >/dev/null 2>&1 || true
        return 0
    fi
    if command -v service >/dev/null 2>&1; then
        service docker restart >/dev/null 2>&1 || true
        return 0
    fi
    return 1
}

is_container_running() {
    docker ps --filter "name=^/${CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"
}

is_container_existing() {
    docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"
}

has_gpu() {
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1
}

get_local_image_id() {
    docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true
}

get_running_container_image_id() {
    docker inspect --format '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true
}

get_container_health_status() {
    docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown"
}

pull_image_with_retry() {
    local attempt=1
    while [[ "$attempt" -le "$PULL_RETRIES" ]]; do
        if docker pull "$IMAGE" >/dev/null 2>&1; then
            return 0
        fi
        log "Image pull attempt ${attempt}/${PULL_RETRIES} failed for $IMAGE"
        attempt=$((attempt + 1))
        sleep "$PULL_RETRY_SLEEP_SECONDS"
    done
    return 1
}

start_container() {
    local -a args=(run -d --restart always --name "$CONTAINER_NAME" --log-opt max-size=10m --log-opt max-file=5)
    if has_gpu; then
        args+=(--gpus all)
    elif is_truthy "$REQUIRE_GPU_READY"; then
        log "GPU is required but host nvidia-smi is not ready; refusing to start container without --gpus."
        return 1
    fi
    args+=("$IMAGE")
    docker "${args[@]}" >/dev/null
}

ensure_container_running() {
    if is_container_running; then
        return 0
    fi

    if is_container_existing; then
        log "Container exists but is not running. Starting it."
        docker start "$CONTAINER_NAME" >/dev/null || true
        sleep 5
        if is_container_running; then
            usage_grace_until=$(( $(date +%s) + USAGE_WARMUP_SECONDS ))
            cpu_low_count=0
            gpu_low_count=0
            return 0
        fi
        log "docker start failed, recreating container."
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    log "Launching container: $CONTAINER_NAME"
    start_container || return 1
    sleep 5
    if is_container_running; then
        usage_grace_until=$(( $(date +%s) + USAGE_WARMUP_SECONDS ))
        cpu_low_count=0
        gpu_low_count=0
        return 0
    fi
    return 1
}

get_cpu_int() {
    local cpu
    cpu="$(docker stats --no-stream --format '{{.CPUPerc}}' "$CONTAINER_NAME" 2>/dev/null | tr -d '%' || true)"
    if [[ -z "$cpu" ]]; then
        echo 0
        return 0
    fi
    printf "%s\n" "$cpu" | awk '{printf "%d\n", $1+0}' 2>/dev/null || echo 0
}

get_gpu_int() {
    if ! has_gpu; then
        echo -1
        return 0
    fi

    local util
    util="$(run_with_timeout "$NVIDIA_QUERY_TIMEOUT_SECONDS" nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | awk '{sum+=$1; c++} END {if(c>0) print int(sum/c); else print 0}')"
    if [[ -z "$util" ]]; then
        echo 0
    else
        echo "$util"
    fi
}

restart_container() {
    local reason="${1:-unknown reason}"
    log "Restarting container $CONTAINER_NAME: $reason"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if ! start_container; then
        log "Container restart failed."
        return 1
    fi
    log "Container restart successful."
    usage_grace_until=$(( $(date +%s) + USAGE_WARMUP_SECONDS ))
    cpu_low_count=0
    gpu_low_count=0
    health_unhealthy_count=0
    sleep "$RESTART_COOLDOWN_SECONDS"
    return 0
}

check_for_new_image_and_recreate() {
    local now
    now=$(date +%s)
    if [[ $((now - last_image_check_epoch)) -lt "$IMAGE_CHECK_INTERVAL_SECONDS" ]]; then
        return 0
    fi
    last_image_check_epoch="$now"

    local local_before local_after running_id
    local_before="$(get_local_image_id)"

    if ! pull_image_with_retry; then
        log "Image refresh failed for $IMAGE; continuing with existing local image."
        return 0
    fi

    local_after="$(get_local_image_id)"
    running_id="$(get_running_container_image_id)"

    if [[ -n "$running_id" && -n "$local_after" && "$running_id" != "$local_after" ]]; then
        log "Detected newer image for $IMAGE (running=${running_id} local=${local_after}); recreating container."
        restart_container "new latest image detected"
        return 0
    fi

    if [[ -n "$local_before" && -n "$local_after" && "$local_before" != "$local_after" ]]; then
        log "Local image id changed for $IMAGE: ${local_before} -> ${local_after}"
    fi
}

main() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0

    log "Usage monitor started for container=$CONTAINER_NAME image=$IMAGE"
    pull_image_with_retry || log "Initial pull failed for $IMAGE; monitor will keep retrying during periodic checks."

    while true; do
        if ! docker_ready; then
            docker_not_ready_count=$((docker_not_ready_count + 1))
            log "Docker daemon not ready; retrying after interval."
            if [[ "$docker_not_ready_count" -ge "$DOCKER_RECOVERY_STREAK_LIMIT" ]]; then
                log "Docker daemon unavailable for ${docker_not_ready_count} checks; attempting daemon recovery."
                try_recover_docker_daemon || true
                docker_not_ready_count=0
            fi
            sleep "$CHECK_INTERVAL_SECONDS"
            continue
        fi
        docker_not_ready_count=0

        if ! ensure_container_running; then
            log "Failed to ensure container is running. Retrying after interval."
            sleep "$CHECK_INTERVAL_SECONDS"
            continue
        fi

        check_for_new_image_and_recreate

        local health_status
        health_status="$(get_container_health_status)"
        if [[ "$health_status" == "unhealthy" ]]; then
            health_unhealthy_count=$((health_unhealthy_count + 1))
            log "Container health unhealthy (${health_unhealthy_count}/${UNHEALTHY_STREAK_LIMIT})."
            if [[ "$health_unhealthy_count" -ge "$UNHEALTHY_STREAK_LIMIT" ]]; then
                restart_container "container healthcheck unhealthy for ${health_unhealthy_count} consecutive checks" || true
                sleep "$CHECK_INTERVAL_SECONDS"
                continue
            fi
        elif [[ "$health_status" == "healthy" || "$health_status" == "none" || "$health_status" == "starting" ]]; then
            health_unhealthy_count=0
        fi

        if [[ "$(date +%s)" -lt "$usage_grace_until" ]]; then
            sleep "$CHECK_INTERVAL_SECONDS"
            continue
        fi

        local cpu gpu
        cpu="$(get_cpu_int)"
        gpu="$(get_gpu_int)"

        log "Usage sample: cpu=${cpu}% gpu=${gpu}%"

        if [[ "$cpu" -le "$LOW_CPU_THRESHOLD" ]]; then
            cpu_low_count=$((cpu_low_count + 1))
        else
            cpu_low_count=0
        fi

        if [[ "$gpu" -lt 0 ]]; then
            gpu_low_count=0
        elif [[ "$gpu" -le "$LOW_GPU_THRESHOLD" ]]; then
            gpu_low_count=$((gpu_low_count + 1))
        else
            gpu_low_count=0
        fi

        if [[ "$cpu_low_count" -ge "$CONSECUTIVE_LOW_USAGE_LIMIT" ]]; then
            restart_container "cpu usage <= ${LOW_CPU_THRESHOLD}% for ${cpu_low_count} consecutive checks" || true
            sleep "$CHECK_INTERVAL_SECONDS"
            continue
        fi

        if [[ "$gpu_low_count" -ge "$CONSECUTIVE_LOW_USAGE_LIMIT" ]]; then
            restart_container "gpu usage <= ${LOW_GPU_THRESHOLD}% for ${gpu_low_count} consecutive checks" || true
            sleep "$CHECK_INTERVAL_SECONDS"
            continue
        fi

        sleep "$CHECK_INTERVAL_SECONDS"
    done
}

main "$@"
EOF
    run_root install -m 0755 "$tmp_script" "$MONITOR_SCRIPT_PATH"
    rm -f "$tmp_script"
}

create_usage_monitor_service() {
    local tmp_unit
    tmp_unit="$(mktemp)"
    cat > "$tmp_unit" <<EOF
[Unit]
Description=AI Trainer Usage Monitor
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$MONITOR_SCRIPT_PATH
Restart=always
RestartSec=5
StartLimitIntervalSec=0
TimeoutStartSec=0
TimeoutStopSec=30
KillMode=process
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF
    run_root install -m 0644 "$tmp_unit" "$MONITOR_SERVICE_PATH"
    rm -f "$tmp_unit"
}

cleanup_legacy_monitors() {
    run_root pkill -f "/usr/local/bin/enhanced-system-monitor" >/dev/null 2>&1 || true
    run_root pkill -f "/usr/local/bin/usage-monitor" >/dev/null 2>&1 || true
    run_root rm -f /var/run/system-monitor.pid /var/run/usage-monitor.pid >/dev/null 2>&1 || true
}

enable_usage_monitor() {
    info "Configuring usage monitor service..."
    create_usage_monitor_script_latest
    create_usage_monitor_service
    cleanup_legacy_monitors

    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl daemon-reload
        run_root systemctl enable usage-monitor.service
        run_root systemctl restart usage-monitor.service
        info "Usage monitor service is active (systemd)."
    else
        if pgrep -f "$MONITOR_SCRIPT_PATH" >/dev/null 2>&1; then
            info "Usage monitor already running via nohup."
        else
            run_root nohup "$MONITOR_SCRIPT_PATH" >/dev/null 2>&1 &
            info "Usage monitor started via nohup (no systemd detected)."
        fi
    fi
}

pull_image_if_possible() {
    if retry 3 15 run_root docker pull "$IMAGE"; then
        info "Pulled image: $IMAGE"
        return 0
    fi

    warn "Image pull failed; checking local cache..."
    if run_root docker image inspect "$IMAGE" >/dev/null 2>&1; then
        warn "Using locally cached image: $IMAGE"
        return 0
    fi

    error "Image pull failed and no local image exists: $IMAGE"
    return 1
}

run_trainer() {
    info "Ensuring trainer container is running..."
    pull_image_if_possible
    if is_truthy "$REQUIRE_GPU_READY" && ! nvidia_ready; then
        error "REQUIRE_GPU_READY=$REQUIRE_GPU_READY but host NVIDIA driver is not ready; refusing to start container without --gpus."
        return 1
    fi

    local running_image=""
    local running_image_id=""
    local desired_image_id=""
    desired_image_id="$(run_root docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
    if run_root docker ps --filter "name=^/${CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        running_image="$(run_root docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
        running_image_id="$(run_root docker inspect --format '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
        if [[ "$running_image" == "$IMAGE" ]] && ! is_truthy "$FORCE_CONTAINER_RECREATE"; then
            if [[ -z "$desired_image_id" || "$running_image_id" == "$desired_image_id" ]]; then
                info "Container $CONTAINER_NAME already running with desired image."
                return 0
            fi
        fi
        info "Container image drift detected (running_id=${running_image_id:-unknown} desired_id=${desired_image_id:-unknown}); recreating."
    fi

    run_root docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    local -a args=(docker run -d --restart always --name "$CONTAINER_NAME" --log-opt max-size=10m --log-opt max-file=5)
    if nvidia_ready; then
        args+=(--gpus all)
        local host_smi=""
        host_smi="$(nvidia_smi_bin || true)"
        if [[ -n "$host_smi" && -x "$host_smi" ]]; then
            args+=(-v "$host_smi:/usr/bin/nvidia-smi:ro")
        fi
    fi
    args+=("$IMAGE")

    run_root "${args[@]}"
    sleep 3

    if run_root docker ps --filter "name=^/${CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        info "Container started: $CONTAINER_NAME"
        return 0
    fi

    error "Container failed to start: $CONTAINER_NAME"
    return 1
}

status() {
    echo
    echo "=== Docker Status ==="
    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl is-active docker || true
    else
        pgrep -x dockerd >/dev/null 2>&1 && echo "active" || echo "inactive"
    fi
    echo
    echo "=== Container Status ==="
    run_root docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" || true
    echo
    echo "=== Monitor Service Status ==="
    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl is-active usage-monitor.service || true
    else
        pgrep -f "$MONITOR_SCRIPT_PATH" >/dev/null 2>&1 && echo "active (nohup)" || echo "inactive"
    fi
    echo
    echo "=== GPU Status ==="
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv || true
        echo
        echo "=== NVIDIA Fabric State ==="
        nvidia-smi -q 2>/dev/null | awk '/^[[:space:]]*GPU[[:space:]]+[0-9]+/{gpu=$2} /^[[:space:]]*Fabric$/{fabric=1; next} fabric && /^[[:space:]]*State[[:space:]]*:/ {print "GPU " gpu ": " $3; fabric=0}' || true
        if command -v systemctl >/dev/null 2>&1; then
            echo
            echo "=== Fabric Manager Service ==="
            run_root systemctl is-active nvidia-fabricmanager || true
        fi
    else
        echo "nvidia-smi not available"
    fi
}

main_setup() {
    with_lock
    info "Starting Azure Batch node bootstrap (script_version=${SCRIPT_VERSION})."
    info "Config: REQUIRE_GPU_READY=${REQUIRE_GPU_READY} ALLOW_REBOOT_AFTER_DRIVER_INSTALL=${ALLOW_REBOOT_AFTER_DRIVER_INSTALL} INSTALL_NVIDIA_DRIVERS=${INSTALL_NVIDIA_DRIVERS} NVIDIA_PREFERRED_MAJOR=${NVIDIA_PREFERRED_MAJOR} NVIDIA_PREFERRED_FLAVOR=${NVIDIA_PREFERRED_FLAVOR} ENFORCE_NVIDIA_PREFERRED_MAJOR=${ENFORCE_NVIDIA_PREFERRED_MAJOR} REQUIRE_PRECOMPILED_AZURE_NVIDIA_MODULES=${REQUIRE_PRECOMPILED_AZURE_NVIDIA_MODULES}"
    ensure_base_packages
    ensure_docker
    docker_login
    ensure_nvidia_runtime
    run_trainer
    enable_usage_monitor
    info "Bootstrap complete."
    info "Container logs: sudo docker logs -f $CONTAINER_NAME"
    info "Monitor logs: tail -f $MONITOR_LOG_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-batch-mode}"
    case "$cmd" in
        install|batch-mode)
            main_setup
            ;;
        start)
            ensure_nvidia_runtime
            run_trainer
            ;;
        monitor)
            enable_usage_monitor
            ;;
        status)
            status
            ;;
        logs)
            run_root docker logs -f "$CONTAINER_NAME"
            ;;
        stop)
            run_root docker stop "$CONTAINER_NAME"
            ;;
        restart)
            run_root docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
            ensure_nvidia_runtime
            run_trainer
            ;;
        *)
            echo "Usage: $0 [batch-mode|install|start|monitor|status|logs|stop|restart]"
            exit 1
            ;;
    esac
fi
