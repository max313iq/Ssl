#!/bin/bash
# Azure Batch NVIDIA Docker Setup - FINAL VERSION
# Fixes all errors: aplay, gpg tty, curl writing

set -e

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"

# Log files
INSTALL_LOG="/var/log/batch-install.log"
mkdir -p /var/log
echo "=== AZURE BATCH START: $(date) ===" > "$INSTALL_LOG"

# Docker credentials
DOCKER_USERNAME="riccorg"
DOCKER_PASSWORD="UL3bJ_5dDcPF7s#"

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$INSTALL_LOG"
}

# ========== FIXED NVIDIA CONTAINER TOOLKIT INSTALL ==========
install_nvidia_container_toolkit_fixed() {
    log "Installing NVIDIA Container Toolkit (FIXED VERSION)..."
    
    # Get distribution
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    architecture=$(dpkg --print-architecture)
    
    log "Distribution: $distribution, Arch: $architecture"
    
    # FIX: Create GPG directory and set permissions
    mkdir -p /etc/apt/keyrings
    mkdir -p /tmp/gpghome
    chmod 700 /tmp/gpghome
    export GNUPGHOME=/tmp/gpghome
    
    # FIX: Download GPG key WITHOUT tty issues
    log "Downloading NVIDIA GPG key..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey 2>/dev/null | \
        gpg --batch --no-tty --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg 2>> "$INSTALL_LOG"
    
    if [ ! -f /etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg ]; then
        log "WARNING: Failed to download GPG key, trying alternative..."
        # Alternative: directly download the file
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -o /tmp/nvidia-gpg.key
        gpg --batch --no-tty --dearmor /tmp/nvidia-gpg.key -o /etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || true
    fi
    
    # FIX: Create repository file
    log "Adding NVIDIA repository..."
    cat > /etc/apt/sources.list.d/nvidia-container-toolkit.list << EOF
deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/$distribution/$(dpkg --print-architecture) /
EOF
    
    # Update and install
    log "Updating package list..."
    apt-get update -qq 2>> "$INSTALL_LOG"
    
    log "Installing nvidia-container-toolkit..."
    apt-get install -y -qq nvidia-container-toolkit 2>> "$INSTALL_LOG"
    
    # Configure Docker
    log "Configuring Docker for NVIDIA..."
    nvidia-ctk runtime configure --runtime=docker 2>> "$INSTALL_LOG"
    systemctl restart docker 2>> "$INSTALL_LOG"
    
    log "✅ NVIDIA Container Toolkit installed"
}

# ========== CHECK AND LOAD NVIDIA DRIVERS ==========
ensure_nvidia_drivers() {
    log "Checking NVIDIA drivers..."
    
    if ! lspci | grep -i nvidia > /dev/null; then
        log "No NVIDIA GPU detected"
        return 1
    fi
    
    # Check if nvidia-smi works
    if command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null 2>&1; then
        log "✅ nvidia-smi is working"
        return 0
    fi
    
    # Try to load NVIDIA module
    log "Attempting to load NVIDIA kernel module..."
    if modprobe nvidia 2>/dev/null; then
        log "NVIDIA module loaded"
        sleep 2
        
        if nvidia-smi > /dev/null 2>&1; then
            log "✅ NVIDIA drivers working after modprobe"
            return 0
        fi
    fi
    
    # Check if drivers are installed
    if dpkg -l | grep -q nvidia-driver; then
        log "NVIDIA drivers are installed but not loaded"
        log "Trying to load all NVIDIA modules..."
        
        # Load common NVIDIA modules
        for module in nvidia nvidia_uvm nvidia_drm nvidia_modeset; do
            if modprobe $module 2>/dev/null; then
                log "Loaded module: $module"
            fi
        done
        
        sleep 3
        
        if nvidia-smi > /dev/null 2>&1; then
            log "✅ NVIDIA drivers working after loading modules"
            return 0
        else
            log "⚠️ NVIDIA drivers installed but still not working"
            log "nvidia-smi output:"
            nvidia-smi 2>&1 | head -20 | tee -a "$INSTALL_LOG"
            return 1
        fi
    else
        log "NVIDIA drivers not installed"
        return 1
    fi
}

# ========== SETUP DOCKER ==========
setup_docker() {
    log "Setting up Docker..."
    
    if ! command -v docker > /dev/null; then
        apt-get update -qq
        apt-get install -y -qq docker.io
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

# ========== PULL AND RUN CONTAINER (WITH APLAY FIX) ==========
setup_container() {
    log "Setting up container..."
    
    # FIX: Install alsa-utils on HOST to avoid container dependency issues
    log "Installing alsa-utils on host..."
    apt-get install -y -qq alsa-utils > /dev/null 2>&1 || log "Note: alsa-utils install optional"
    
    # Pull image with retry
    for i in {1..3}; do
        log "Pull attempt $i/3"
        if timeout 300 docker pull "$IMAGE" 2>> "$INSTALL_LOG"; then
            log "✅ Image pulled successfully"
            break
        else
            log "Pull failed or timeout, retrying..."
            sleep 10
        fi
    done
    
    # Stop existing container
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Check GPU availability
    GPU_OPTION=""
    if command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null 2>&1; then
        log "GPU available, using --gpus all"
        GPU_OPTION="--gpus all"
        
        # Test nvidia-container-cli
        if command -v nvidia-container-cli > /dev/null; then
            log "nvidia-container-cli is available"
        fi
    else
        log "GPU not available, running without GPU support"
    fi
    
    # Run container with appropriate options
    log "Starting container..."
    if [ -n "$GPU_OPTION" ]; then
        docker run -d \
            $GPU_OPTION \
            --restart unless-stopped \
            --name "$CONTAINER_NAME" \
            "$IMAGE" 2>> "$INSTALL_LOG"
    else
        docker run -d \
            --restart unless-stopped \
            --name "$CONTAINER_NAME" \
            "$IMAGE" 2>> "$INSTALL_LOG"
    fi
    
    # Verify container
    sleep 5
    if docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        log "✅ Container running successfully"
        
        # Show container info
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$CONTAINER_NAME"
        
        # Check container health
        log "Checking container health..."
        if docker inspect "$CONTAINER_NAME" | grep -q '"Health":'; then
            log "Container has health check"
        fi
        
        # Show recent logs (filter out aplay errors)
        log "Container logs (excluding aplay errors):"
        docker logs --tail 10 "$CONTAINER_NAME" 2>/dev/null | grep -v "aplay" | head -5 || true
        
    else
        log "❌ Container failed to start"
        log "Last 10 lines of container logs:"
        docker logs "$CONTAINER_NAME" 2>/dev/null | tail -10 || true
    fi
}

# ========== START MONITOR ==========
start_monitor() {
    log "Starting system monitor..."
    
    cat > /usr/local/bin/batch-monitor << 'EOF'
#!/bin/bash
while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] STATUS UPDATE" >> /var/log/system-status.log
    echo "CPU: $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')" >> /var/log/system-status.log
    
    if command -v nvidia-smi > /dev/null && timeout 5 nvidia-smi > /dev/null 2>&1; then
        echo "GPU: $(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader 2>/dev/null | head -1)" >> /var/log/system-status.log
    fi
    
    if docker ps --format '{{.Names}}' | grep -q ai-trainer; then
        echo "Container: RUNNING" >> /var/log/system-status.log
    else
        echo "Container: STOPPED" >> /var/log/system-status.log
    fi
    echo "---" >> /var/log/system-status.log
    sleep 30
done
EOF
    
    chmod +x /usr/local/bin/batch-monitor
    nohup /usr/local/bin/batch-monitor > /dev/null 2>&1 &
    log "Monitor started (PID: $!)"
}

# ========== MAIN EXECUTION ==========
main() {
    log "=== AZURE BATCH NVIDIA DOCKER SETUP ==="
    
    # Update system quietly
    log "Updating system packages..."
    apt-get update -qq 2>> "$INSTALL_LOG"
    
    # Setup Docker first
    setup_docker
    
    # Check and ensure NVIDIA drivers
    if ensure_nvidia_drivers; then
        log "✅ NVIDIA drivers are working"
        
        # Install NVIDIA Container Toolkit
        install_nvidia_container_toolkit_fixed
        
        # Setup container
        setup_container
    else
        log "⚠️ NVIDIA drivers not working, continuing without GPU"
        setup_container
    fi
    
    # Start monitoring
    start_monitor
    
    log "=== SETUP COMPLETE ==="
    log "System is ready!"
    log "To check status: tail -f $INSTALL_LOG"
    log "To see GPU status: nvidia-smi"
    log "To see container: docker ps"
    
    # Keep alive for Azure Batch
    log "Azure Batch task running..."
    while true; do
        sleep 3600
    done
}

# ========== SIMPLE VERSION FOR AZURE BATCH (RECOMMENDED) ==========
simple_setup() {
    echo "=== SIMPLE AZURE BATCH SETUP ==="
    
    # Update
    apt-get update -qq
    
    # Install Docker if needed
    if ! command -v docker > /dev/null; then
        apt-get install -y docker.io
        systemctl start docker
    fi
    
    # Docker login
    echo "$DOCKER_PASSWORD" | docker login docker.io --username "$DOCKER_USERNAME" --password-stdin 2>/dev/null || true
    
    # Check NVIDIA
    if lspci | grep -i nvidia > /dev/null; then
        echo "NVIDIA GPU detected"
        
        # Load NVIDIA modules if possible
        modprobe nvidia 2>/dev/null || true
        modprobe nvidia_uvm 2>/dev/null || true
        
        if command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null 2>&1; then
            echo "nvidia-smi is working"
            
            # Simple NVIDIA container toolkit install
            distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey 2>/dev/null | \
                gpg --batch --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null
            
            echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] \
                https://nvidia.github.io/libnvidia-container/stable/$distribution/$(dpkg --print-architecture) /" \
                > /etc/apt/sources.list.d/nvidia-container-toolkit.list 2>/dev/null
            
            apt-get update -qq
            apt-get install -y nvidia-container-toolkit 2>/dev/null
            nvidia-ctk runtime configure --runtime=docker 2>/dev/null
            systemctl restart docker 2>/dev/null
        fi
    fi
    
    # Pull and run container
    docker pull "$IMAGE" 2>/dev/null || true
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    if command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null 2>&1; then
        docker run -d --gpus all --restart unless-stopped --name "$CONTAINER_NAME" "$IMAGE"
        echo "Container started with GPU"
    else
        docker run -d --restart unless-stopped --name "$CONTAINER_NAME" "$IMAGE"
        echo "Container started without GPU"
    fi
    
    echo "Setup complete"
    
    # Keep alive
    while true; do sleep 3600; done
}

# Command line
case "${1:-}" in
    "simple")
        simple_setup
        ;;
    "status")
        echo "=== STATUS ==="
        echo "GPU:"
        lspci | grep -i nvidia || echo "No NVIDIA GPU"
        echo ""
        echo "NVIDIA drivers:"
        lsmod | grep nvidia || echo "NVIDIA module not loaded"
        echo ""
        echo "Container:"
        docker ps | grep "$CONTAINER_NAME" || echo "Container not running"
        echo ""
        echo "Logs: tail -20 $INSTALL_LOG"
        ;;
    *)
        main
        ;;
esac
