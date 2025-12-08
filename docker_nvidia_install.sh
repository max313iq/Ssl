#!/bin/bash
# Azure Batch NVIDIA Docker Setup - PROPER NVIDIA INSTALLATION
# Fixes driver loading and aplay error

set -e

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"

# Log files
INSTALL_LOG="/var/log/batch-install.log"
REBOOT_FLAG="/var/run/batch-nvidia-reboot.flag"

# Docker credentials
DOCKER_USERNAME="riccorg"
DOCKER_PASSWORD="UL3bJ_5dDcPF7s#"

# Initialize
mkdir -p /var/log /var/run
echo "=== AZURE BATCH START: $(date) ===" > "$INSTALL_LOG"

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$INSTALL_LOG"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$INSTALL_LOG"
}

# ========== CHECK POST-REBOOT ==========
is_post_reboot() {
    if [ -f "$REBOOT_FLAG" ]; then
        REASON=$(cat "$REBOOT_FLAG")
        log "Post-reboot detected: $REASON"
        rm -f "$REBOOT_FLAG"
        return 0
    fi
    return 1
}

# ========== INSTALL NVIDIA DRIVERS (WITH REBOOT) ==========
install_nvidia_with_reboot() {
    log "Checking for NVIDIA GPU..."
    
    if ! lspci | grep -i nvidia > /dev/null; then
        log "No NVIDIA GPU detected"
        return 1
    fi
    
    log "NVIDIA GPU detected, installing drivers..."
    
    # Set non-interactive
    export DEBIAN_FRONTEND=noninteractive
    
    # Install ubuntu-drivers
    apt-get install -y ubuntu-drivers-common
    
    # Install recommended NVIDIA driver
    log "Installing NVIDIA driver..."
    ubuntu-drivers autoinstall
    
    # Alternative: Get specific driver
    # DRIVER=$(ubuntu-drivers list | grep -o "nvidia-driver-[0-9]\+" | head -1)
    # if [ -n "$DRIVER" ]; then
    #     apt-get install -y "$DRIVER"
    # fi
    
    # Check if driver modules exist
    if modprobe -n nvidia 2>/dev/null; then
        log "NVIDIA driver modules found"
    else
        error "NVIDIA driver modules not found"
        return 1
    fi
    
    # Try to load the driver
    if modprobe nvidia 2>/dev/null && lsmod | grep -q nvidia; then
        log "NVIDIA driver loaded successfully"
        return 0
    else
        log "NVIDIA driver installed but needs reboot to load"
        
        # Mark for reboot
        echo "NVIDIA_DRIVER_INSTALLED" > "$REBOOT_FLAG"
        
        # Schedule immediate reboot
        log "Rebooting for NVIDIA drivers..."
        shutdown -r now
        exit 0
    fi
}

# ========== INSTALL NVIDIA CONTAINER TOOLKIT ==========
install_nvidia_container_toolkit() {
    log "Installing NVIDIA Container Toolkit..."
    
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    
    # Install prerequisites
    apt-get install -y curl gpg
    
    # Setup GPG without tty
    export GNUPGHOME=/tmp/gnupg
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    
    # Download and install GPG key
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        gpg --batch --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    # Add repository
    echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] \
        https://nvidia.github.io/libnvidia-container/stable/\$distribution/\$(arch) /" | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    
    # Update and install
    apt-get update
    apt-get install -y nvidia-container-toolkit
    
    # Configure Docker
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    
    log "NVIDIA Container Toolkit installed"
}

# ========== DOCKER SETUP ==========
setup_docker() {
    log "Setting up Docker..."
    
    if ! command -v docker > /dev/null; then
        apt-get update
        apt-get install -y docker.io
        systemctl start docker
        systemctl enable docker
        log "Docker installed"
    else
        log "Docker already installed"
    fi
    
    # Docker login
    log "Docker login..."
    echo "$DOCKER_PASSWORD" | docker login docker.io \
        --username "$DOCKER_USERNAME" \
        --password-stdin > /dev/null 2>&1 && log "Login OK" || log "Login skipped"
}

# ========== PULL AND RUN CONTAINER ==========
setup_container() {
    log "Setting up container..."
    
    # Install aplay to fix container error
    log "Installing aplay (alsa-utils)..."
    apt-get install -y alsa-utils > /dev/null 2>&1 || log "aplay install failed, continuing"
    
    # Pull image
    for i in {1..3}; do
        log "Pull attempt $i/3"
        if docker pull "$IMAGE"; then
            log "Image pulled"
            break
        fi
        sleep 10
    done
    
    # Stop existing
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Check GPU
    if command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null 2>&1; then
        log "GPU available, starting with --gpus all"
        docker run -d \
            --gpus all \
            --restart unless-stopped \
            --name "$CONTAINER_NAME" \
            "$IMAGE"
    else
        log "GPU not available, starting without GPU"
        docker run -d \
            --restart unless-stopped \
            --name "$CONTAINER_NAME" \
            "$IMAGE"
    fi
    
    # Verify
    sleep 5
    if docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        log "✅ Container running"
        docker ps --format "table {{.Names}}\t{{.Status}}" | grep "$CONTAINER_NAME"
        
        # Check container health
        log "Container logs (first few lines):"
        docker logs --tail 5 "$CONTAINER_NAME" 2>/dev/null || true
    else
        error "Container failed to start"
    fi
}

# ========== START MONITOR ==========
start_monitor() {
    log "Starting monitor..."
    
    cat > /usr/local/bin/batch-monitor << 'EOF'
#!/bin/bash
LOG="/var/log/system-status.log"
while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CPU: $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')" >> "$LOG"
    
    if command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null 2>&1; then
        GPU_INFO=$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader 2>/dev/null | head -1)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] GPU: $GPU_INFO" >> "$LOG"
    fi
    
    if docker ps --format '{{.Names}}' | grep -q ai-trainer; then
        CONTAINER_STATS=$(docker stats ai-trainer --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" 2>/dev/null || echo "N/A")
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Container: RUNNING $CONTAINER_STATS" >> "$LOG"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Container: STOPPED" >> "$LOG"
    fi
    sleep 30
done
EOF
    
    chmod +x /usr/local/bin/batch-monitor
    nohup /usr/local/bin/batch-monitor > /dev/null 2>&1 &
    log "Monitor started"
}

# ========== MAIN FLOW ==========
main() {
    log "=== AZURE BATCH SETUP ==="
    
    # Update system
    apt-get update
    
    # Check if post-reboot
    if is_post_reboot; then
        log "=== POST-REBOOT: NVIDIA DRIVERS SHOULD BE LOADED ==="
        
        # Wait for services
        sleep 10
        until systemctl is-active --quiet docker; do
            sleep 5
        done
        
        # Check if NVIDIA drivers loaded
        if lsmod | grep -q nvidia || command -v nvidia-smi > /dev/null; then
            log "✅ NVIDIA drivers loaded after reboot"
            
            # Setup Docker
            setup_docker
            
            # Install NVIDIA Container Toolkit
            install_nvidia_container_toolkit
            
            # Setup container
            setup_container
        else
            log "⚠️ NVIDIA drivers not loaded after reboot, continuing without GPU"
            setup_docker
            setup_container
        fi
    else
        log "=== FRESH INSTALLATION ==="
        
        # Setup Docker first
        setup_docker
        
        # Check for NVIDIA GPU
        if lspci | grep -i nvidia > /dev/null; then
            log "NVIDIA GPU detected, attempting driver installation..."
            
            # Install NVIDIA drivers (will reboot if successful)
            if install_nvidia_with_reboot; then
                # If we get here, drivers loaded without reboot
                log "NVIDIA drivers loaded without reboot"
                install_nvidia_container_toolkit
                setup_container
            else
                # Driver installation failed or reboot scheduled
                if [ -f "$REBOOT_FLAG" ]; then
                    # Reboot was scheduled, script will exit
                    log "Reboot scheduled for NVIDIA drivers"
                    exit 0
                else
                    # Installation failed, continue without GPU
                    log "NVIDIA installation failed, continuing without GPU"
                    setup_container
                fi
            fi
        else
            log "No NVIDIA GPU detected, skipping NVIDIA installation"
            setup_container
        fi
    fi
    
    # Start monitoring
    start_monitor
    
    log "=== SETUP COMPLETE ==="
    log "Logs: tail -f $INSTALL_LOG"
    log "Status: tail -f /var/log/system-status.log"
    
    # Keep alive
    while true; do
        sleep 3600
    done
}

# Command line options
case "${1:-}" in
    "status")
        echo "=== STATUS ==="
        echo "Install log: $INSTALL_LOG"
        tail -20 "$INSTALL_LOG"
        echo ""
        echo "Container:"
        docker ps | grep "$CONTAINER_NAME" || echo "Not running"
        echo ""
        echo "GPU Status:"
        if command -v nvidia-smi > /dev/null; then
            nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu --format=csv
        else
            echo "GPU not available"
        fi
        ;;
    "logs")
        tail -f "$INSTALL_LOG"
        ;;
    "container-logs")
        docker logs -f "$CONTAINER_NAME"
        ;;
    "restart-container")
        docker restart "$CONTAINER_NAME"
        echo "Container restarted"
        ;;
    *)
        main
        ;;
esac
