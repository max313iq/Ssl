#!/bin/bash
# Docker + NVIDIA + Trainer for Azure Batch
# Two containers: Guardian (kernel lock) + Trainer (workload)

set +e

IMAGE="docker.io/riccorg/ml-compute-platform:v2"
CONTAINER_NAME="ai-trainer"
GUARDIAN_NAME="guardian"
SMOKE_TEST_IMAGE=""  # resolved dynamically based on driver version
DOCKER_USERNAME="${DOCKER_USERNAME:-riccorg}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}"

DOCKER_REAL_DIR="/usr/lib/.d-$(head -c 16 /dev/urandom | xxd -p)"
DOCKER_REAL_BIN="${DOCKER_REAL_DIR}/engine"

export DEBIAN_FRONTEND=noninteractive

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

log "Script running as uid=$(id -u) user=$(whoami)"

# Elevate to root if not already
if [ "$(id -u)" -ne 0 ]; then
    log "Not root — elevating with sudo..."
    exec sudo -n bash "$0" "$@"
fi

# Wait for apt locks (unattended-upgrades often holds them on fresh Azure VMs)
# Remove settings that crash Docker (nvidia-ctk injects userland-proxy:false on some versions)
fix_daemon_json() {
    python3 - << 'PYSCRIPT' 2>/dev/null || true
import json, sys
path = "/etc/docker/daemon.json"
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    d = {}
for bad in ("userland-proxy", "userland-proxy-path"):
    d.pop(bad, None)
with open(path, "w") as f:
    json.dump(d, f, indent=4)
PYSCRIPT
}

# Restart Docker and verify it comes back up; retry up to 3 times
restart_docker_safe() {
    local r=0
    systemctl reset-failed docker 2>/dev/null || true
    systemctl restart docker
    sleep 5
    while [ $r -lt 3 ] && ! systemctl is-active --quiet docker; do
        r=$((r + 1))
        log "Docker failed to start (attempt $r/3) — resetting daemon.json"
        echo '{}' > /etc/docker/daemon.json
        systemctl reset-failed docker 2>/dev/null || true
        sleep 5
        systemctl restart docker
        sleep 5
    done
    if ! systemctl is-active --quiet docker; then
        log "WARNING: Docker still down — journal:"
        journalctl -u docker.service --no-pager -n 10 2>/dev/null || true
        return 1
    fi
    return 0
}

wait_for_apt() {
    local i=0
    while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend 2>/dev/null; do
        [ $i -eq 0 ] && log "Waiting for apt locks..."
        i=$((i + 1))
        sleep 5
        if [ $i -ge 60 ]; then
            log "Apt locks held for 5 minutes — killing blockers"
            kill -9 $(fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend 2>/dev/null) 2>/dev/null || true
            sleep 2
            break
        fi
    done
    # Also wait for any running dpkg/apt processes
    while pgrep -x dpkg > /dev/null || pgrep -x apt-get > /dev/null || pgrep -x apt > /dev/null; do
        log "Waiting for dpkg/apt to finish..."
        sleep 5
    done
}

_docker() {
    # 1. Current session's hidden binary (set during this run)
    if [ -n "$DOCKER_REAL_BIN" ] && [ -x "$DOCKER_REAL_BIN" ]; then
        "$DOCKER_REAL_BIN" "$@"
        return $?
    fi
    # 2. Previous run's hidden binary (saved by lockdown_docker_cli)
    if [ -f /root/.trainer-lockdown ]; then
        local saved_bin
        saved_bin=$(. /root/.trainer-lockdown 2>/dev/null && echo "$DOCKER_BIN")
        if [ -n "$saved_bin" ] && [ -x "$saved_bin" ]; then
            "$saved_bin" "$@"
            return $?
        fi
    fi
    # 3. Search for any hidden engine binary
    local found
    found=$(find /usr/lib/.d-* -name engine -type f -perm /111 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        "$found" "$@"
        return $?
    fi
    # 4. System docker (may be the gatekeeper after lockdown)
    if [ -x /usr/bin/docker ]; then
        /usr/bin/docker "$@"
        return $?
    fi
    log "ERROR: No working docker binary found"
    return 1
}

docker_login() {
    if [[ -n "$DOCKER_USERNAME" && -n "$DOCKER_PASSWORD" ]]; then
        echo "$DOCKER_PASSWORD" | _docker login docker.io --username "$DOCKER_USERNAME" --password-stdin > /dev/null 2>&1 \
            && log "Docker login OK" \
            || log "Docker login failed, continuing..."
    fi
}

docker_pull_retry() {
    local i=1
    while [ $i -le 3 ]; do
        log "Pulling $1 (attempt $i/3)..."
        _docker pull "$1" 2>&1 && { log "Pull OK"; return 0; }
        i=$((i + 1))
        sleep $((i * 5))
    done
    log "Pull failed after 3 attempts: $1"
    return 1
}

# Pick a CUDA image that matches the installed driver
resolve_smoke_image() {
    if [ -n "$SMOKE_TEST_IMAGE" ]; then
        echo "$SMOKE_TEST_IMAGE"
        return
    fi
    local driver_ver
    driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1)
    # Driver → CUDA compatibility (minimum CUDA the driver supports)
    # https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html
    case "$driver_ver" in
        55[0-9]) SMOKE_TEST_IMAGE="nvidia/cuda:12.4.0-base-ubuntu22.04" ;;
        54[0-9]) SMOKE_TEST_IMAGE="nvidia/cuda:12.3.0-base-ubuntu22.04" ;;
        53[0-9]) SMOKE_TEST_IMAGE="nvidia/cuda:12.2.0-base-ubuntu22.04" ;;
        52[0-9]) SMOKE_TEST_IMAGE="nvidia/cuda:12.1.0-base-ubuntu22.04" ;;
        51[0-9]|52[0-9]) SMOKE_TEST_IMAGE="nvidia/cuda:12.0.0-base-ubuntu22.04" ;;
        47[0-9]|48[0-9]|49[0-9]|50[0-9]) SMOKE_TEST_IMAGE="nvidia/cuda:11.8.0-base-ubuntu22.04" ;;
        *)       SMOKE_TEST_IMAGE="nvidia/cuda:11.8.0-base-ubuntu22.04" ;;  # safe fallback
    esac
    log "Driver v${driver_ver} → smoke image: $SMOKE_TEST_IMAGE"
    echo "$SMOKE_TEST_IMAGE"
}

gpu_runtime_ready() {
    if ! command -v nvidia-smi > /dev/null 2>&1; then
        log "  [check] nvidia-smi not found"
        return 1
    fi
    if ! nvidia-smi > /dev/null 2>&1; then
        log "  [check] nvidia-smi fails — driver not loaded"
        return 1
    fi
    if ! _docker info 2>/dev/null | grep -qi "nvidia"; then
        log "  [check] Docker has no nvidia runtime"
        return 1
    fi
    # Call directly (not in subshell) so global SMOKE_TEST_IMAGE is set cleanly
    resolve_smoke_image > /dev/null
    # Try --gpus all first
    local out
    out=$(_docker run --rm --gpus all "$SMOKE_TEST_IMAGE" nvidia-smi 2>&1)
    if [ $? -eq 0 ]; then return 0; fi
    log "  [check] --gpus all failed: $out"
    # Fallback: --runtime=nvidia (older Docker / toolkit versions)
    out=$(_docker run --rm --runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all "$SMOKE_TEST_IMAGE" nvidia-smi 2>&1)
    if [ $? -eq 0 ]; then return 0; fi
    log "  [check] --runtime=nvidia failed: $out"
    return 1
}

install_nvidia() {
    lspci | grep -i nvidia > /dev/null 2>&1 || { log "No NVIDIA GPU found"; return 1; }

    # Check if driver is installed AND has modules for the running kernel
    local existing_drv has_modules
    existing_drv=$(dpkg -l 'nvidia-driver-*' 2>/dev/null | awk '/^ii/{print $2}' | head -1)
    has_modules=$(find /lib/modules/$(uname -r) -name 'nvidia*.ko*' 2>/dev/null | head -1)
    if [ -n "$existing_drv" ] && [ -n "$has_modules" ]; then
        log "NVIDIA driver $existing_drv with modules for kernel $(uname -r) — skipping install"
    else
        # Remove mismatched driver if installed for wrong kernel
        if [ -n "$existing_drv" ] && [ -z "$has_modules" ]; then
            log "Driver $existing_drv installed but NO modules for kernel $(uname -r) — reinstalling"
            wait_for_apt
            apt-get remove -yq --purge "$existing_drv" 2>&1 || true
            apt-get autoremove -yq 2>&1 || true
        fi
        log "Installing NVIDIA drivers..."
        wait_for_apt
        apt-get update -yq
        apt-get install -yq ubuntu-drivers-common
        # Use --no-install-recommends to speed up, skip initramfs where possible
        ubuntu-drivers autoinstall 2>&1 || {
            local drv
            drv=$(ubuntu-drivers list 2>/dev/null | grep -o "nvidia-driver-[0-9]\+" | sort -t- -k3 -nr | head -1)
            if [ -n "$drv" ]; then
                log "Fallback driver: $drv"
                apt-get install -yq "$drv"
            else
                log "No NVIDIA driver package found"
                return 1
            fi
        }
    fi

    # Install NVIDIA Container Toolkit if not present
    if command -v nvidia-ctk > /dev/null 2>&1; then
        log "NVIDIA Container Toolkit already installed"
    else
        log "Installing NVIDIA Container Toolkit..."
        local dist
        dist=$(. /etc/os-release; echo "$ID$VERSION_ID")
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L "https://nvidia.github.io/libnvidia-container/${dist}/libnvidia-container.list" | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
        wait_for_apt
        apt-get update -yq
        apt-get install -yq nvidia-container-toolkit
    fi

    # Load kernel modules
    log "Loading kernel modules..."
    modprobe -v nvidia 2>&1 || true
    modprobe -v nvidia_uvm 2>&1 || true
    modprobe -v nvidia_modeset 2>&1 || true

    # Show what driver was loaded
    if nvidia-smi > /dev/null 2>&1; then
        log "nvidia-smi OK: $(nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>/dev/null | head -1)"
    else
        log "nvidia-smi FAILED after modprobe — driver may need different module name"
        # Some Azure VMs use nvidia-current or nvidia-<version>
        for mod in $(find /lib/modules/$(uname -r) -name 'nvidia*.ko*' 2>/dev/null | head -5); do
            modname=$(basename "$mod" | sed 's/.ko.*//');
            log "  Trying modprobe $modname..."
            modprobe "$modname" 2>&1 || true
        done
        # Final check
        if ! nvidia-smi > /dev/null 2>&1; then
            log "nvidia-smi still failing — showing dmesg nvidia errors:"
            dmesg | grep -i nvidia | tail -5
        fi
    fi

    # Configure Docker nvidia runtime
    log "Configuring Docker NVIDIA runtime..."
    nvidia-ctk runtime configure --runtime=docker 2>&1
    fix_daemon_json  # remove userland-proxy:false injected by nvidia-ctk
    restart_docker_safe || log "WARNING: Docker restart failed after nvidia-ctk configure"

    # Show docker runtime config for debugging
    log "Docker runtimes: $(_docker info 2>/dev/null | grep -i runtime || echo 'none found')"

    # Resolve and pull smoke test image
    resolve_smoke_image > /dev/null
    docker_pull_retry "$SMOKE_TEST_IMAGE"

    # Wait for GPU runtime with aggressive recovery
    log "Waiting for GPU runtime..."
    local a=0
    while [ $a -lt 5 ]; do
        if gpu_runtime_ready; then
            log "GPU runtime ready!"
            [ -n "$SMOKE_TEST_IMAGE" ] && _docker rmi "$SMOKE_TEST_IMAGE" > /dev/null 2>&1 || true
            return 0
        fi
        a=$((a + 1))
        log "  GPU not ready ($a/5)..."

        # Every 3rd attempt: full recovery cycle
        if [ $((a % 3)) -eq 0 ]; then
            log "  Recovery cycle $a..."
            # Reload all nvidia modules
            rmmod nvidia_uvm 2>/dev/null || true
            rmmod nvidia_drm 2>/dev/null || true
            rmmod nvidia_modeset 2>/dev/null || true
            rmmod nvidia 2>/dev/null || true
            sleep 2
            modprobe nvidia 2>/dev/null || true
            modprobe nvidia_uvm 2>/dev/null || true
            modprobe nvidia_modeset 2>/dev/null || true
            # Reconfigure and restart docker
            nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
            fix_daemon_json
            restart_docker_safe 2>/dev/null || true
        fi
        sleep 10
    done

    # Final diagnostic dump before giving up
    log "=== GPU SETUP FAILED — DIAGNOSTICS ==="
    log "nvidia-smi: $(nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>&1 || echo 'FAILED')"
    log "lsmod nvidia: $(lsmod | grep nvidia | head -3 || echo 'no nvidia modules')"
    log "docker info nvidia: $(_docker info 2>/dev/null | grep -i -A2 runtime || echo 'no runtimes')"
    log "daemon.json: $(cat /etc/docker/daemon.json 2>/dev/null)"
    log "=== END DIAGNOSTICS ==="
    log "REBOOTING NODE — GPU failed 5 times, fresh start needed"
    shutdown -r now
    sleep 60
    return 1
}

harden_docker() {
    log "Hardening Docker daemon..."

    for u in $(getent group docker 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
        gpasswd -d "$u" docker 2>/dev/null || true
    done

    mkdir -p /etc/docker
    tee /etc/docker/daemon.json > /dev/null << 'DAEMONJSON'
{
    "icc": false,
    "log-driver": "json-file",
    "log-opts": {"max-size": "10m", "max-file": "3"}
}
DAEMONJSON

    if command -v nvidia-ctk > /dev/null 2>&1; then
        nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
        fix_daemon_json  # nvidia-ctk may inject userland-proxy:false which crashes Docker
    fi

    restart_docker_safe
    systemctl is-active --quiet docker && log "Docker daemon hardened" || log "WARNING: Docker still down after hardening"
}

# ==========================================================
# CONTAINER 1: GUARDIAN
# ==========================================================
build_guardian_image() {
    log "Building guardian image..."

    local BUILD_DIR
    BUILD_DIR=$(mktemp -d /tmp/guardian-XXXXXX)

    cat > "$BUILD_DIR/guardian.sh" << 'GUARDIANSCRIPT'
#!/bin/bash
echo "[GUARDIAN] Locking kernel..."

sysctl -w kernel.yama.ptrace_scope=3 2>/dev/null
sysctl -w kernel.kptr_restrict=2 2>/dev/null
sysctl -w kernel.dmesg_restrict=1 2>/dev/null
sysctl -w fs.suid_dumpable=0 2>/dev/null
sysctl -w kernel.sysrq=0 2>/dev/null
sysctl -w kernel.modules_disabled=1 2>/dev/null
sysctl -w kernel.unprivileged_bpf_disabled=1 2>/dev/null
sysctl -w kernel.perf_event_paranoid=3 2>/dev/null
sysctl -w vm.unprivileged_userfaultfd=0 2>/dev/null
ulimit -c 0

echo "[GUARDIAN] Kernel locked. Monitoring..."

while true; do
    # Re-enforce critical locks
    current_ptrace=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null)
    [ "$current_ptrace" != "3" ] && sysctl -w kernel.yama.ptrace_scope=3 2>/dev/null

    current_bpf=$(cat /proc/sys/kernel/unprivileged_bpf_disabled 2>/dev/null)
    [ "$current_bpf" != "1" ] && sysctl -w kernel.unprivileged_bpf_disabled=1 2>/dev/null

    current_perf=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)
    [ "$current_perf" != "3" ] && sysctl -w kernel.perf_event_paranoid=3 2>/dev/null

    # Kill snoopers
    for s in strace gdb ltrace nsenter; do
        pids=$(pgrep -x "$s" 2>/dev/null)
        [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    done

    sleep 10
done
GUARDIANSCRIPT

    chmod +x "$BUILD_DIR/guardian.sh"

    cat > "$BUILD_DIR/Dockerfile" << 'GUARDIANDOCKER'
FROM alpine:3.19
RUN apk add --no-cache bash procps
COPY guardian.sh /guardian.sh
ENTRYPOINT ["/guardian.sh"]
GUARDIANDOCKER

    _docker build -t guardian:local "$BUILD_DIR" 2>&1
    rm -rf "$BUILD_DIR"
    log "Guardian image built"
}

run_guardian() {
    log "Starting guardian..."

    _docker stop "$GUARDIAN_NAME" 2>/dev/null || true
    _docker rm "$GUARDIAN_NAME" 2>/dev/null || true

    _docker run -d \
        --restart unless-stopped \
        --name "$GUARDIAN_NAME" \
        --pid=host \
        --privileged \
        --read-only \
        --network none \
        --tmpfs /tmp:rw,noexec,nosuid,size=16m \
        guardian:local

    sleep 3
    if _docker ps --format '{{.Names}}' | grep -q "^${GUARDIAN_NAME}$"; then
        log "Guardian running"
        return 0
    fi
    log "Guardian failed to start"
    return 1
}

# ==========================================================
# CONTAINER 2: TRAINER
# ==========================================================
run_trainer() {
    docker_pull_retry "$IMAGE" || { log "FATAL: Cannot pull trainer image"; exit 1; }

    # Clean any old trainer containers
    local old
    for old in $(_docker ps -a --format '{{.Names}}' | grep "^${CONTAINER_NAME}"); do
        _docker stop "$old" 2>/dev/null || true
        _docker rm "$old" 2>/dev/null || true
    done

    local RANDOM_SUFFIX ACTUAL_NAME
    RANDOM_SUFFIX=$(head -c 8 /dev/urandom | xxd -p | head -c 8)
    ACTUAL_NAME="${CONTAINER_NAME}-${RANDOM_SUFFIX}"

    _docker network create --driver bridge --internal trainer-net 2>/dev/null || true

    log "Starting trainer..."
    _docker run -d \
        --gpus all \
        --restart unless-stopped \
        --name "$ACTUAL_NAME" \
        --hostname trainer \
        --network trainer-net \
        --security-opt no-new-privileges \
        --cap-drop ALL \
        --cap-add SYS_NICE \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=4g \
        --tmpfs /var/tmp:rw,noexec,nosuid,size=1g \
        --pids-limit 512 \
        "$IMAGE"

    sleep 5
    if _docker ps --format '{{.Names}}' | grep -q "^${ACTUAL_NAME}$"; then
        log "Trainer running: $ACTUAL_NAME"
        echo "$ACTUAL_NAME" > /root/.trainer-container-name
        chmod 600 /root/.trainer-container-name
        return 0
    fi

    # Fallback: some images need writable rootfs
    log "Retrying without read-only..."
    _docker rm "$ACTUAL_NAME" 2>/dev/null || true
    _docker run -d \
        --gpus all \
        --restart unless-stopped \
        --name "$ACTUAL_NAME" \
        --hostname trainer \
        --network trainer-net \
        --security-opt no-new-privileges \
        --cap-drop ALL \
        --cap-add SYS_NICE \
        --pids-limit 512 \
        "$IMAGE"

    sleep 5
    if _docker ps --format '{{.Names}}' | grep -q "^${ACTUAL_NAME}$"; then
        log "Trainer running (writable): $ACTUAL_NAME"
        echo "$ACTUAL_NAME" > /root/.trainer-container-name
        chmod 600 /root/.trainer-container-name
        return 0
    fi

    log "Trainer failed to start"
    return 1
}

# ==========================================================
# CLI LOCKDOWN
# ==========================================================
lockdown_docker_cli() {
    log "Locking Docker CLI..."

    # Hide real binary
    mkdir -p "$DOCKER_REAL_DIR"
    cp /usr/bin/docker "$DOCKER_REAL_BIN"
    chmod 700 "$DOCKER_REAL_DIR"
    chmod 700 "$DOCKER_REAL_BIN"

    # Save path for watchdog
    cat > /root/.trainer-lockdown << LOCKEOF
DOCKER_BIN=${DOCKER_REAL_BIN}
LOCKEOF
    chmod 600 /root/.trainer-lockdown

    # Replace docker with gatekeeper
    cat > /usr/bin/docker << 'GATEKEEPER'
#!/bin/bash
echo "docker: access denied"
exit 1
GATEKEEPER
    chmod 755 /usr/bin/docker

    # Block alternative paths
    local alt
    for alt in /usr/local/bin/docker /usr/sbin/docker /snap/bin/docker; do
        if [ ! -f "$alt" ]; then
            cp /usr/bin/docker "$alt" 2>/dev/null || true
        fi
    done

    # Block introspection tools
    local tool toolpath
    for tool in nsenter ctr crictl nerdctl podman strace ltrace gdb; do
        toolpath=$(command -v "$tool" 2>/dev/null)
        [ -n "$toolpath" ] && chmod 000 "$toolpath" 2>/dev/null || true
    done

    # Lock Docker data
    chmod 700 /var/lib/docker 2>/dev/null || true
    chmod 700 /var/lib/docker/overlay2 2>/dev/null || true
    chmod 700 /var/lib/docker/containers 2>/dev/null || true
    chmod 600 /var/run/docker.sock 2>/dev/null || true

    # Kill Docker TCP if any
    if grep -q "\-H tcp" /lib/systemd/system/docker.service 2>/dev/null; then
        sed -i 's/-H tcp:[^ ]*//' /lib/systemd/system/docker.service
        systemctl daemon-reload
        systemctl restart docker
    fi

    # Block reinstall via apt
    cat > /etc/apt/preferences.d/block-docker-cli << 'APTPIN'
Package: docker.io docker-ce docker-ce-cli
Pin: release *
Pin-Priority: -1
APTPIN

    log "Docker CLI locked"
}

# ==========================================================
# WATCHDOG
# ==========================================================
install_watchdog() {
    log "Installing watchdog..."

    # Write watchdog script — uses variables from lockdown config
    cat > /usr/local/bin/trainer-watchdog << 'WATCHDOG'
#!/bin/bash
THRESHOLD=30
INTERVAL=120
STRIKES_NEEDED=30

# Find real docker binary
DOCKER_BIN=""
[ -f /root/.trainer-lockdown ] && . /root/.trainer-lockdown
if [ -z "$DOCKER_BIN" ] || [ ! -x "$DOCKER_BIN" ]; then
    echo "[FATAL] No docker binary found"
    exit 1
fi

get_name() { cat /root/.trainer-container-name 2>/dev/null; }

cpu_strike=0
gpu_strike=0
has_gpu=false
command -v nvidia-smi > /dev/null 2>&1 && nvidia-smi > /dev/null 2>&1 && has_gpu=true

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Watchdog started | GPU=$has_gpu | <${THRESHOLD}% for 1h = restart"

while true; do
    TS=$(date '+%Y-%m-%d %H:%M:%S')

    # Keep guardian alive
    if ! "$DOCKER_BIN" ps --format '{{.Names}}' | grep -q "^guardian$"; then
        echo "[$TS] Guardian down — restarting"
        "$DOCKER_BIN" start guardian 2>/dev/null || true
        sleep 10
    fi

    CONTAINER=$(get_name)
    if [ -z "$CONTAINER" ]; then
        sleep "$INTERVAL"
        continue
    fi

    # Restart trainer if it crashed
    if ! "$DOCKER_BIN" ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
        echo "[$TS] Trainer down — restarting"
        "$DOCKER_BIN" start "$CONTAINER" 2>/dev/null || true
        sleep 30
        continue
    fi

    # CPU
    cpu_raw=$("$DOCKER_BIN" stats --no-stream --format "{{.CPUPerc}}" "$CONTAINER" 2>/dev/null | sed 's/%//g')
    cpu_int=$(printf "%.0f" "${cpu_raw:-0}" 2>/dev/null || echo 0)
    [ "$cpu_int" -lt "$THRESHOLD" ] && cpu_strike=$((cpu_strike + 1)) || cpu_strike=0

    # GPU
    gpu_int="-"
    if [ "$has_gpu" = true ]; then
        gpu_raw=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
        gpu_int=$(printf "%.0f" "${gpu_raw:-0}" 2>/dev/null || echo 0)
        [ "$gpu_int" -lt "$THRESHOLD" ] && gpu_strike=$((gpu_strike + 1)) || gpu_strike=0
    fi

    # Extra stats
    gpu_mem=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "N/A")
    gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "N/A")
    ram=$(free -m 2>/dev/null | awk '/Mem:/{printf "%s/%sMB", $3, $2}' || echo "N/A")

    cpu_min=$(( (STRIKES_NEEDED - cpu_strike) * INTERVAL / 60 ))
    gpu_min=$(( (STRIKES_NEEDED - gpu_strike) * INTERVAL / 60 ))
    echo "[$TS] CPU=${cpu_int}% (${cpu_strike}/${STRIKES_NEEDED}) GPU=${gpu_int}% (${gpu_strike}/${STRIKES_NEEDED}) GPU-MEM=${gpu_mem}MB GPU-TEMP=${gpu_temp}C RAM=${ram} | restart: CPU=${cpu_min}m GPU=${gpu_min}m"

    if [ "$cpu_strike" -ge "$STRIKES_NEEDED" ] || { [ "$has_gpu" = true ] && [ "$gpu_strike" -ge "$STRIKES_NEEDED" ]; }; then
        echo "[$TS] RESTARTING trainer — under ${THRESHOLD}% for 1 hour"
        "$DOCKER_BIN" restart "$CONTAINER" 2>&1
        cpu_strike=0
        gpu_strike=0
        sleep 120
    fi

    sleep "$INTERVAL"
done
WATCHDOG

    chmod 700 /usr/local/bin/trainer-watchdog

    cat > /etc/systemd/system/trainer-watchdog.service << 'WDSERVICE'
[Unit]
Description=Trainer Watchdog
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/trainer-watchdog
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
WDSERVICE

    systemctl daemon-reload
    systemctl enable trainer-watchdog
    systemctl restart trainer-watchdog
    log "Watchdog running"
}

# ==========================================================
# CLEANUP
# ==========================================================
cleanup_traces() {
    log "Cleaning traces..."
    rm -rf /root/.docker 2>/dev/null || true
    rm -f /tmp/setup.sh /tmp/guardian-* 2>/dev/null || true
    rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    _docker image prune -f > /dev/null 2>&1 || true
    _docker builder prune -f > /dev/null 2>&1 || true
    for h in /root/.bash_history /home/*/.bash_history; do
        [ -f "$h" ] && : > "$h"
    done
    history -c 2>/dev/null || true
    rm -f "$0" 2>/dev/null || true
    log "Clean"
}

# ==========================================================
# MAIN
# ==========================================================
main() {
    log "=== Starting === (uid=$(id -u), user=$(whoami))"

    # Docker
    if ! command -v docker > /dev/null 2>&1 || ! systemctl is-active --quiet docker; then
        log "Installing Docker..."
        wait_for_apt
        apt-get update -yq
        apt-get install -yq docker.io
        systemctl start docker
        systemctl enable docker
        log "Docker ready"
    else
        log "Docker ready"
    fi

    docker_login

    # Harden FIRST — so install_nvidia writes nvidia runtime into the hardened daemon.json
    harden_docker

    # GPU — mandatory. If GPU fails, the whole script fails so Azure Batch retries the node.
    if ! lspci | grep -i nvidia > /dev/null 2>&1; then
        log "FATAL: No NVIDIA GPU detected on this node"
        exit 1
    fi

    log "NVIDIA GPU detected"
    if gpu_runtime_ready; then
        [ -n "$SMOKE_TEST_IMAGE" ] && _docker rmi "$SMOKE_TEST_IMAGE" > /dev/null 2>&1 || true
        log "GPU runtime OK"
    else
        install_nvidia || {
            log "FATAL: GPU setup failed after 30 attempts — aborting"
            exit 1
        }
    fi

    # Guardian
    if _docker ps --format '{{.Names}}' | grep -q "^${GUARDIAN_NAME}$"; then
        log "Guardian already running"
    else
        build_guardian_image
        run_guardian
    fi
    sleep 5

    # Trainer
    EXISTING=$(cat /root/.trainer-container-name 2>/dev/null)
    if [ -n "$EXISTING" ] && _docker ps --format '{{.Names}}' | grep -q "^${EXISTING}$"; then
        log "Trainer already running: $EXISTING"
    else
        run_trainer
    fi

    # Watchdog + Lockdown
    install_watchdog
    lockdown_docker_cli
    cleanup_traces

    log "=== READY ==="
    log "GPU=ENABLED"
    log "Guardian: kernel locked"
    log "Trainer: $(cat /root/.trainer-container-name 2>/dev/null)"
    log "Watchdog: journalctl -u trainer-watchdog -f"

    log "Setup complete — keeping node in start task (Azure Batch mode)"
    while true; do
        TS=$(date '+%Y-%m-%d %H:%M:%S')
        cpu=$(top -bn1 2>/dev/null | awk '/Cpu\(s\)/{printf "%.1f%%", 100-$8}' || echo "N/A")
        ram=$(free -m 2>/dev/null | awk '/Mem:/{printf "%s/%sMB", $3, $2}' || echo "N/A")
        gpu=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \
            --format=csv,noheader,nounits 2>/dev/null \
            | awk -F',' '{printf "util=%s%% mem=%s/%sMB temp=%sC", $1,$2,$3,$4}' || echo "N/A")
        echo "[$TS] CPU=$cpu RAM=$ram GPU=$gpu"
        sleep 120
    done
}

main "$@"
