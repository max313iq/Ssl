#!/bin/bash
# Accessible Docker + NVIDIA + Trainer setup for Azure Batch
# Uses the standard Docker CLI and keeps the trainer container manageable.

set -euo pipefail

IMAGE="${IMAGE:-docker.io/riccorg/ml-compute-platform:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-ai-trainer}"
SMOKE_TEST_IMAGE="${SMOKE_TEST_IMAGE:-}"
DOCKER_USERNAME="${DOCKER_USERNAME:-riccorg}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-UL3bJ_5dDcPF7s#}"
KEEP_ALIVE="${KEEP_ALIVE:-1}"
STATE_DIR="${STATE_DIR:-/var/lib/azure-batch-trainer}"
GPU_REBOOT_MARKER="${GPU_REBOOT_MARKER:-${STATE_DIR}/gpu-driver-reboot-requested}"
HEALTHCHECK_START_DELAY_SECONDS="${HEALTHCHECK_START_DELAY_SECONDS:-1800}"
USAGE_PRINT_INTERVAL_SECONDS="${USAGE_PRINT_INTERVAL_SECONDS:-600}"
USAGE_SAMPLE_INTERVAL_SECONDS="${USAGE_SAMPLE_INTERVAL_SECONDS:-60}"

export DEBIAN_FRONTEND=noninteractive

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

clear_gpu_reboot_marker() {
    rm -f "$GPU_REBOOT_MARKER" 2>/dev/null || true
}

reboot_once_for_gpu_driver() {
    mkdir -p "$STATE_DIR"
    date '+%Y-%m-%d %H:%M:%S' > "$GPU_REBOOT_MARKER"
    sync

    log "NVIDIA driver is installed but not active yet - rebooting once to load the kernel driver"

    if command -v systemctl > /dev/null 2>&1; then
        systemctl reboot || true
    fi
    shutdown -r now || reboot || true

    log "Reboot command was issued; exiting so the node can come back cleanly"
    exit 0
}

log "Script running as uid=$(id -u) user=$(whoami)"

if [ "$(id -u)" -ne 0 ]; then
    log "Not root - elevating with sudo..."
    exec sudo -n bash "$0" "$@"
fi

wait_for_apt() {
    local i=0
    while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend 2>/dev/null; do
        [ $i -eq 0 ] && log "Waiting for apt locks..."
        i=$((i + 1))
        sleep 5
    done

    while pgrep -x dpkg > /dev/null || pgrep -x apt-get > /dev/null || pgrep -x apt > /dev/null; do
        log "Waiting for dpkg/apt to finish..."
        sleep 5
    done
}

fix_daemon_json() {
    python3 - << 'PYSCRIPT' 2>/dev/null || true
import json

path = "/etc/docker/daemon.json"
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {}

for bad in ("userland-proxy", "userland-proxy-path"):
    data.pop(bad, None)

with open(path, "w") as f:
    json.dump(data, f, indent=4)
PYSCRIPT
}

restart_docker_safe() {
    local retries=0
    systemctl reset-failed docker 2>/dev/null || true
    systemctl restart docker
    sleep 5

    while [ $retries -lt 3 ] && ! systemctl is-active --quiet docker; do
        retries=$((retries + 1))
        log "Docker failed to start (attempt $retries/3) - resetting daemon.json"
        echo '{}' > /etc/docker/daemon.json
        systemctl reset-failed docker 2>/dev/null || true
        sleep 5
        systemctl restart docker
        sleep 5
    done

    if ! systemctl is-active --quiet docker; then
        log "WARNING: Docker is still down - recent journal output:"
        journalctl -u docker.service --no-pager -n 10 2>/dev/null || true
        return 1
    fi

    return 0
}

ensure_docker() {
    if ! command -v docker > /dev/null 2>&1 || ! systemctl is-active --quiet docker; then
        log "Installing Docker..."
        wait_for_apt
        apt-get update -yq
        apt-get install -yq docker.io
        systemctl enable docker
        systemctl start docker
    fi

    log "Docker ready: $(docker --version 2>/dev/null || echo unavailable)"
}

docker_login() {
    if [[ -n "$DOCKER_USERNAME" && -n "$DOCKER_PASSWORD" ]]; then
        echo "$DOCKER_PASSWORD" | docker login docker.io --username "$DOCKER_USERNAME" --password-stdin > /dev/null 2>&1 \
            && log "Docker login OK" \
            || log "Docker login failed, continuing without cached auth"
    else
        log "Docker login skipped - set DOCKER_USERNAME and DOCKER_PASSWORD to enable registry auth"
    fi
}

docker_pull_retry() {
    local attempt=1
    while [ $attempt -le 3 ]; do
        log "Pulling $1 (attempt $attempt/3)..."
        if docker pull "$1"; then
            log "Pull OK"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep $((attempt * 5))
    done

    log "Pull failed after 3 attempts: $1"
    return 1
}

resolve_smoke_image() {
    if [ -n "$SMOKE_TEST_IMAGE" ]; then
        echo "$SMOKE_TEST_IMAGE"
        return
    fi

    local driver_major
    driver_major=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1 || true)
    [ -z "$driver_major" ] && driver_major="unknown"
    case "$driver_major" in
        55[0-9]) SMOKE_TEST_IMAGE="nvidia/cuda:12.4.0-base-ubuntu22.04" ;;
        54[0-9]) SMOKE_TEST_IMAGE="nvidia/cuda:12.3.0-base-ubuntu22.04" ;;
        53[0-9]) SMOKE_TEST_IMAGE="nvidia/cuda:12.2.0-base-ubuntu22.04" ;;
        52[0-9]) SMOKE_TEST_IMAGE="nvidia/cuda:12.1.0-base-ubuntu22.04" ;;
        51[0-9]) SMOKE_TEST_IMAGE="nvidia/cuda:12.0.0-base-ubuntu22.04" ;;
        47[0-9]|48[0-9]|49[0-9]|50[0-9]) SMOKE_TEST_IMAGE="nvidia/cuda:11.8.0-base-ubuntu22.04" ;;
        *) SMOKE_TEST_IMAGE="nvidia/cuda:11.8.0-base-ubuntu22.04" ;;
    esac

    log "Driver v${driver_major} -> smoke image: $SMOKE_TEST_IMAGE"
    echo "$SMOKE_TEST_IMAGE"
}

gpu_runtime_ready() {
    if ! command -v nvidia-smi > /dev/null 2>&1; then
        log "  [check] nvidia-smi not found"
        return 1
    fi

    if ! nvidia-smi > /dev/null 2>&1; then
        log "  [check] nvidia-smi failed - driver not loaded"
        return 1
    fi

    if ! docker info 2>/dev/null | grep -qi "nvidia"; then
        log "  [check] Docker has no nvidia runtime"
        return 1
    fi

    resolve_smoke_image > /dev/null

    local out
    if out=$(docker run --rm --net=host --gpus all "$SMOKE_TEST_IMAGE" nvidia-smi 2>&1); then
        return 0
    fi

    log "  [check] --gpus all failed: $out"

    if out=$(docker run --rm --net=host --runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all "$SMOKE_TEST_IMAGE" nvidia-smi 2>&1); then
        return 0
    fi

    log "  [check] --runtime=nvidia failed: $out"
    return 1
}

install_nvidia() {
    lspci | grep -i nvidia > /dev/null 2>&1 || {
        log "No NVIDIA GPU found"
        return 1
    }

    local existing_drv
    local has_modules
    existing_drv=$(dpkg -l 'nvidia-driver-*' 2>/dev/null | awk '/^ii/{print $2}' | head -1)
    has_modules=$(find /lib/modules/"$(uname -r)" -name 'nvidia*.ko*' 2>/dev/null | head -1)

    if [ -n "$existing_drv" ] && [ -n "$has_modules" ]; then
        log "NVIDIA driver $existing_drv with modules for kernel $(uname -r) - skipping install"
    else
        if [ -n "$existing_drv" ] && [ -z "$has_modules" ]; then
            log "Driver $existing_drv installed without modules for kernel $(uname -r) - reinstalling"
            wait_for_apt
            apt-get remove -yq --purge "$existing_drv" 2>&1 || true
            apt-get autoremove -yq 2>&1 || true
        fi

        log "Installing NVIDIA drivers..."
        wait_for_apt
        apt-get update -yq
        apt-get install -yq ubuntu-drivers-common
        ubuntu-drivers autoinstall 2>&1 || {
            local drv
            drv=$(ubuntu-drivers list 2>/dev/null | grep -o 'nvidia-driver-[0-9]\+' | sort -t- -k3 -nr | head -1)
            if [ -n "$drv" ]; then
                log "Fallback driver: $drv"
                apt-get install -yq "$drv"
            else
                log "No NVIDIA driver package found"
                return 1
            fi
        }
    fi

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

    log "Loading kernel modules..."
    modprobe -v nvidia 2>&1 || true
    modprobe -v nvidia_uvm 2>&1 || true
    modprobe -v nvidia_modeset 2>&1 || true

    python3 << 'PYRUNTIME' 2>/dev/null || true
import json
import os

path = "/etc/docker/daemon.json"
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {}

runtime_path = "nvidia-container-runtime"
for candidate in (
    "/usr/bin/nvidia-container-runtime",
    "/usr/local/bin/nvidia-container-runtime",
    "/usr/lib/nvidia-container-runtime",
):
    if os.path.isfile(candidate):
        runtime_path = candidate
        break

data["runtimes"] = {"nvidia": {"path": runtime_path, "runtimeArgs": []}}
for bad in ("userland-proxy", "userland-proxy-path"):
    data.pop(bad, None)

with open(path, "w") as f:
    json.dump(data, f, indent=4)
PYRUNTIME

    fix_daemon_json
    restart_docker_safe || log "WARNING: Docker restart failed after runtime configuration"

    if ! nvidia-smi > /dev/null 2>&1; then
        if [ ! -f "$GPU_REBOOT_MARKER" ]; then
            reboot_once_for_gpu_driver
        fi
        log "NVIDIA driver is still not active after the reboot attempt"
    fi

    resolve_smoke_image > /dev/null
    docker_pull_retry "$SMOKE_TEST_IMAGE"

    if gpu_runtime_ready; then
        log "GPU runtime ready"
        docker rmi "$SMOKE_TEST_IMAGE" > /dev/null 2>&1 || true
        clear_gpu_reboot_marker
        return 0
    fi

    log "GPU setup diagnostics:"
    log "nvidia-smi: $(nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>&1 || echo FAILED)"
    log "docker runtimes: $(docker info 2>/dev/null | grep -i -A2 runtime || echo none)"
    log "daemon.json: $(cat /etc/docker/daemon.json 2>/dev/null || echo missing)"
    return 1
}

run_trainer() {
    docker_pull_retry "$IMAGE"

    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log "Removing existing container: $CONTAINER_NAME"
        docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
    fi

    log "Starting trainer container: $CONTAINER_NAME"
    docker run -d \
        --gpus all \
        --restart unless-stopped \
        --name "$CONTAINER_NAME" \
        --net=host \
        "$IMAGE" > /dev/null

    sleep 5
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log "Trainer running: $CONTAINER_NAME"
        return 0
    fi

    log "Trainer failed to start - recent logs:"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -20 || true
    return 1
}

container_is_running() {
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

is_numeric() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_zero_usage() {
    awk -v value="$1" 'BEGIN { exit !(value <= 0.01) }'
}

sum_numbers() {
    awk -v left="$1" -v right="$2" 'BEGIN { printf "%.4f", left + right }'
}

format_percent() {
    awk -v value="$1" 'BEGIN { printf "%.2f%%", value }'
}

average_percent() {
    local total="$1"
    local count="$2"

    if [ "$count" -le 0 ]; then
        echo "N/A"
        return
    fi

    awk -v total="$total" -v count="$count" 'BEGIN { printf "%.2f%%", total / count }'
}

get_container_cpu_usage() {
    docker stats --no-stream --format '{{.CPUPerc}}' "$CONTAINER_NAME" 2>/dev/null | head -1 | tr -d '%' | xargs
}

get_gpu_usage() {
    nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | \
        awk 'NF {sum += $1; count += 1} END {if (count > 0) printf "%.2f", sum / count}'
}

restart_trainer_container() {
    log "Restarting trainer container: $CONTAINER_NAME"
    run_trainer
}

wait_for_healthcheck_delay() {
    local remaining="$HEALTHCHECK_START_DELAY_SECONDS"

    log "Health checks will begin after a $((HEALTHCHECK_START_DELAY_SECONDS / 60))-minute startup delay"

    while [ "$remaining" -gt 0 ]; do
        local sleep_for="$USAGE_SAMPLE_INTERVAL_SECONDS"

        if ! container_is_running; then
            log "Trainer container stopped during the startup delay"
            return 1
        fi

        if [ "$remaining" -lt "$sleep_for" ]; then
            sleep_for="$remaining"
        fi

        sleep "$sleep_for"
        remaining=$((remaining - sleep_for))
    done

    return 0
}

monitor_trainer_health() {
    while true; do
        if ! wait_for_healthcheck_delay; then
            restart_trainer_container || {
                log "Trainer restart failed during the startup delay check; retrying in 60 seconds"
                sleep 60
            }
            continue
        fi

        while true; do
            local remaining="$USAGE_PRINT_INTERVAL_SECONDS"
            local sample_count=0
            local cpu_sum="0"
            local gpu_sum="0"
            local cpu_zero_for_window=1
            local gpu_zero_for_window=1
            local cpu_usage
            local gpu_usage
            local avg_cpu
            local avg_gpu

            while [ "$remaining" -gt 0 ]; do
                local sleep_for="$USAGE_SAMPLE_INTERVAL_SECONDS"

                if ! container_is_running; then
                    log "Trainer container is not running anymore"
                    break
                fi

                cpu_usage=$(get_container_cpu_usage)
                gpu_usage=$(get_gpu_usage)

                if is_numeric "$cpu_usage"; then
                    cpu_sum=$(sum_numbers "$cpu_sum" "$cpu_usage")
                    if ! is_zero_usage "$cpu_usage"; then
                        cpu_zero_for_window=0
                    fi
                else
                    cpu_zero_for_window=0
                fi

                if is_numeric "$gpu_usage"; then
                    gpu_sum=$(sum_numbers "$gpu_sum" "$gpu_usage")
                    if ! is_zero_usage "$gpu_usage"; then
                        gpu_zero_for_window=0
                    fi
                else
                    gpu_zero_for_window=0
                fi

                sample_count=$((sample_count + 1))

                if [ "$remaining" -lt "$sleep_for" ]; then
                    sleep_for="$remaining"
                fi

                sleep "$sleep_for"
                remaining=$((remaining - sleep_for))
            done

            if ! container_is_running; then
                restart_trainer_container || {
                    log "Trainer restart failed after container stop; retrying in 60 seconds"
                    sleep 60
                }
                break
            fi

            avg_cpu=$(average_percent "$cpu_sum" "$sample_count")
            avg_gpu=$(average_percent "$gpu_sum" "$sample_count")
            log "Usage over the last $((USAGE_PRINT_INTERVAL_SECONDS / 60)) minutes: CPU=$avg_cpu GPU=$avg_gpu"

            if [ "$cpu_zero_for_window" -eq 1 ] || [ "$gpu_zero_for_window" -eq 1 ]; then
                log "CPU or GPU stayed at 0% for $((USAGE_PRINT_INTERVAL_SECONDS / 60)) minutes - restarting the trainer container"
                restart_trainer_container || {
                    log "Trainer restart failed after idle detection; retrying in 60 seconds"
                    sleep 60
                }
                break
            fi
        done
    done
}

main() {
    log "=== Starting === (uid=$(id -u), user=$(whoami))"

    ensure_docker
    docker_login

    if ! lspci | grep -i nvidia > /dev/null 2>&1; then
        log "FATAL: No NVIDIA GPU detected on this node"
        exit 1
    fi

    log "NVIDIA GPU detected"
    if gpu_runtime_ready; then
        docker rmi "$SMOKE_TEST_IMAGE" > /dev/null 2>&1 || true
        clear_gpu_reboot_marker
        log "GPU runtime OK"
    else
        install_nvidia || {
            log "FATAL: GPU setup failed"
            exit 1
        }
    fi

    run_trainer

    log "=== READY ==="
    log "Docker CLI remains available: $(command -v docker)"
    log "Trainer container: $CONTAINER_NAME"
    log "Useful commands:"
    log "  docker ps"
    log "  docker logs -f $CONTAINER_NAME"
    log "  docker exec -it $CONTAINER_NAME bash"

    if [ "$KEEP_ALIVE" = "1" ]; then
        log "KEEP_ALIVE=1, starting container health monitoring"
        monitor_trainer_health
    fi
}

main "$@"
