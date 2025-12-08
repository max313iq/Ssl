#!/bin/bash
# Azure Batch NVIDIA Docker Setup - PROPER REBOOT HANDLING
# Ensures NVIDIA drivers load after reboot

set -e

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"

# Log files
INSTALL_LOG="/var/log/batch-install.log"
REBOOT_FLAG="/var/run/batch-reboot.flag"

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

# ========== CHECK IF WE'RE POST-REBOOT ==========
check_post_reboot() {
    if [ -f "$REBOOT_FLAG" ]; then
        log "Detected post-reboot state"
        POST_REBOOT=true
        REASON=$(cat "$REBOOT_FLAG")
        log "Reboot reason: $REASON"
        rm -f "$REBOOT_FLAG"
        return 0
    fi
    return 1
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
        --password-stdin > /dev/null 2>&1 && log "Login OK" || log "Login failed, continuing"
}

# ========== NVIDIA DRIVER INSTALLATION ==========
install_nvidia_drivers() {
    log "Checking for NVIDIA GPU..."
    
    if ! lspci | grep -i nvidia > /dev/null; then
        log "No NVIDIA GPU detected"
        return 1
    fi
    
    log "NVIDIA GPU detected, installing drivers..."
    
    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive
    
    # Install required packages
    apt-get install -y ubuntu-drivers-common
    
    # Get recommended driver
    DRIVER=$(ubuntu-drivers list | grep -o "nvidia-driver-[0-9]\+" | head -1)
    
    if [ -z "$DRIVER" ]; then
        log "No driver found via ubuntu-drivers"
        return 1
    fi
    
    log "Installing driver: $DRIVER"
    
    # Install driver
    apt-get install -y "$DRIVER"
    
    # Wait a moment
    sleep 5
    
    # Check if driver loaded
    if lsmod | grep -q nvidia; then
        log "NVIDIA driver loaded successfully"
        return 0
    else
        log "NVIDIA driver installed but not loaded (needs reboot)"
        
        # Mark for reboot
        echo "NVIDIA_DRIVER_INSTALL" > "$REBOOT_FLAG"
        
        # Schedule reboot
        log "Scheduling reboot for NVIDIA drivers..."
        shutdown -r +1 "Azure Batch NVIDIA driver reboot"
        
        # Exit script (node will reboot)
        exit 0
    fi
}

# ========== NVIDIA CONTAINER TOOLKIT ==========
install_nvidia_toolkit() {
    log "Installing NVIDIA container toolkit..."
    
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    
    # Download and install GPG key
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    # Add repository
    echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/\$distribution/\$(arch) /" | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    
    apt-get update
    apt-get install -y nvidia-container-toolkit
    
    # Configure Docker
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    
    log "NVIDIA container toolkit installed"
}

# ========== PULL AND RUN CONTAINER ==========
setup_container() {
    log "Setting up container..."
    
    # Pull image with retry
    for i in {1..3}; do
        log "Pull attempt $i/3"
        if docker pull "$IMAGE"; then
            log "Image pulled successfully"
            break
        fi
        sleep 10
    done
    
    # Stop existing container
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Check GPU status
    if command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null 2>&1; then
        log "GPU available, starting with GPU support"
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
    sleep 3
    if docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        log "✅ Container running successfully"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$CONTAINER_NAME"
    else
        log "❌ Container failed to start"
        docker logs "$CONTAINER_NAME" 2>/dev/null || true
    fi
}

# ========== START MONITOR ==========
start_monitor() {
    log "Starting system monitor..."
    
    cat > /usr/local/bin/batch-monitor << 'EOF'
#!/bin/bash
while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] STATUS - CPU: $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')" >> /var/log/system-status.log
    if command -v nvidia-smi > /dev/null; then
        nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv 2>/dev/null | while read line; do
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] GPU: $line" >> /var/log/system-status.log
        done
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Container: $(docker ps --format '{{.Names}}' | grep ai-trainer || echo 'Not running')" >> /var/log/system-status.log
    sleep 30
done
EOF
    
    chmod +x /usr/local/bin/batch-monitor
    nohup /usr/local/bin/batch-monitor > /dev/null 2>&1 &
    log "Monitor started"
}

# ========== MAIN FLOW ==========
main() {
    log "=== AZURE BATCH SETUP STARTED ==="
    
    # Check if we're after a reboot
    if check_post_reboot; then
        log "=== POST-REBOOT SETUP ==="
        
        # Wait for Docker
        until systemctl is-active --quiet docker; do
            sleep 5
        done
        
        # Now NVIDIA drivers should be loaded
        log "Checking NVIDIA drivers after reboot..."
        if lsmod | grep -q nvidia; then
            log "✅ NVIDIA drivers loaded after reboot"
            
            # Install NVIDIA container toolkit
            install_nvidia_toolkit
            
            # Setup Docker login
            echo "$DOCKER_PASSWORD" | docker login docker.io \
                --username "$DOCKER_USERNAME" \
                --password-stdin > /dev/null 2>&1 || log "Login failed, continuing"
            
            # Setup container
            setup_container
        else
            log "❌ NVIDIA drivers still not loaded after reboot"
            log "Continuing without GPU support"
            setup_docker
            setup_container
        fi
    else
        log "=== FRESH INSTALLATION ==="
        
        # Setup Docker
        setup_docker
        
        # Install NVIDIA drivers (will reboot if needed)
        if install_nvidia_drivers; then
            # Drivers loaded without reboot
            log "NVIDIA drivers loaded without reboot"
            install_nvidia_toolkit
            setup_container
        else
            # Either no GPU or reboot scheduled
            if [ ! -f "$REBOOT_FLAG" ]; then
                # No GPU or installation failed without reboot
                log "Setting up without NVIDIA"
                setup_container
            fi
            # If reboot flag exists, script will exit and node will reboot
        fi
    fi
    
    # Start monitoring
    start_monitor
    
    log "=== SETUP COMPLETE ==="
    log "Check logs: tail -f $INSTALL_LOG"
    log "System status: tail -f /var/log/system-status.log"
    log "Container logs: docker logs -f $CONTAINER_NAME"
    
    # Keep alive for Azure Batch
    log "Azure Batch task running..."
    while true; do
        sleep 3600
    done
}

# Handle command line arguments
case "${1:-}" in
    "status")
        echo "=== STATUS ==="
        echo "Install log: $INSTALL_LOG"
        tail -20 "$INSTALL_LOG"
        echo ""
        echo "Container:"
        docker ps | grep "$CONTAINER_NAME" || echo "Not running"
        echo ""
        echo "GPU:"
        if command -v nvidia-smi > /dev/null; then
            nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu --format=csv
        else
            echo "Not available"
        fi
        ;;
    "logs")
        tail -f "$INSTALL_LOG"
        ;;
    "container-logs")
        docker logs -f "$CONTAINER_NAME"
        ;;
    "monitor-logs")
        tail -f /var/log/system-status.log
        ;;
    *)
        main
        ;;
esac
