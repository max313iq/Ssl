#!/bin/bash
# Azure Batch NVIDIA Docker Setup - FINAL WORKING VERSION
# For Azure Batch Account Start Task

set -e

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"

# Docker credentials
DOCKER_USERNAME="riccorg"
DOCKER_PASSWORD="UL3bJ_5dDcPF7s#"

# Log file
LOG_FILE="/var/log/azure-batch.log"
echo "=== AZURE BATCH STARTUP - $(date) ===" > "$LOG_FILE"

# Simple logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ========== MAIN SETUP FUNCTION ==========
setup() {
    log "Starting Azure Batch setup..."
    
    # Update system
    log "Updating packages..."
    apt-get update -y >> "$LOG_FILE" 2>&1
    
    # Install Docker if not present
    if ! command -v docker > /dev/null; then
        log "Installing Docker..."
        apt-get install -y docker.io >> "$LOG_FILE" 2>&1
        systemctl start docker
        systemctl enable docker
        log "Docker installed"
    else
        log "Docker already installed"
    fi
    
    # Docker login
    log "Logging into Docker Hub..."
    echo "$DOCKER_PASSWORD" | docker login docker.io \
        --username "$DOCKER_USERNAME" \
        --password-stdin >> "$LOG_FILE" 2>&1 || log "Docker login failed or skipped"
    
    # Check for NVIDIA GPU
    if lspci | grep -i nvidia > /dev/null; then
        log "NVIDIA GPU detected"
        
        # Try to load NVIDIA drivers if already installed
        log "Checking NVIDIA drivers..."
        
        # Load NVIDIA modules
        for module in nvidia nvidia_uvm nvidia_drm nvidia_modeset; do
            if modprobe "$module" 2>/dev/null; then
                log "Loaded module: $module"
            fi
        done
        
        # Check if nvidia-smi works
        sleep 2
        if command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null 2>&1; then
            log "nvidia-smi is working"
            
            # INSTALL NVIDIA CONTAINER TOOLKIT (FIXED VERSION)
            log "Installing NVIDIA Container Toolkit..."
            
            # Get actual distribution and architecture (FIXED HERE)
            DISTRIBUTION=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
            VERSION=$(lsb_release -rs | tr -d '.')
            ARCH=$(dpkg --print-architecture)
            
            log "Detected: OS=$DISTRIBUTION, Version=$VERSION, Arch=$ARCH"
            
            # For Ubuntu 20.04/22.04, use appropriate version
            if [ "$DISTRIBUTION" = "ubuntu" ]; then
                case "$VERSION" in
                    "2004") DIST_CODENAME="ubuntu20.04" ;;
                    "2204") DIST_CODENAME="ubuntu22.04" ;;
                    "2404") DIST_CODENAME="ubuntu24.04" ;;
                    *) DIST_CODENAME="ubuntu${VERSION:0:2}.${VERSION:2:2}" ;;
                esac
            else
                DIST_CODENAME="${DISTRIBUTION}${VERSION}"
            fi
            
            log "Using distribution code: $DIST_CODENAME"
            
            # Download GPG key
            log "Downloading NVIDIA GPG key..."
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || \
                log "GPG key download failed, continuing..."
            
            # Create repository file with CORRECT URL
            REPO_FILE="/etc/apt/sources.list.d/nvidia-container-toolkit.list"
            cat > "$REPO_FILE" << EOF
deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] \
https://nvidia.github.io/libnvidia-container/stable/$DIST_CODENAME/$(dpkg --print-architecture) /
EOF
            
            log "Repository file created:"
            cat "$REPO_FILE" >> "$LOG_FILE"
            
            # Update and install
            apt-get update -y >> "$LOG_FILE" 2>&1
            
            # Install NVIDIA container toolkit
            if apt-get install -y nvidia-container-toolkit >> "$LOG_FILE" 2>&1; then
                log "NVIDIA Container Toolkit installed"
                
                # Configure Docker
                nvidia-ctk runtime configure --runtime=docker >> "$LOG_FILE" 2>&1
                systemctl restart docker >> "$LOG_FILE" 2>&1
                log "Docker configured for NVIDIA"
            else
                log "Failed to install NVIDIA Container Toolkit"
            fi
        else
            log "nvidia-smi not working, skipping NVIDIA Container Toolkit"
        fi
    else
        log "No NVIDIA GPU detected"
    fi
    
    # Pull Docker image
    log "Pulling Docker image..."
    for i in {1..3}; do
        if docker pull "$IMAGE" >> "$LOG_FILE" 2>&1; then
            log "Image pulled successfully"
            break
        else
            log "Pull attempt $i failed, retrying..."
            sleep 10
        fi
    done
    
    # Stop existing container
    log "Stopping existing container if any..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Start container with GPU if available
    if command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null 2>&1; then
        log "Starting container with GPU support..."
        docker run -d \
            --gpus all \
            --restart unless-stopped \
            --name "$CONTAINER_NAME" \
            "$IMAGE" >> "$LOG_FILE" 2>&1
        log "Container started with GPU"
    else
        log "Starting container without GPU..."
        docker run -d \
            --restart unless-stopped \
            --name "$CONTAINER_NAME" \
            "$IMAGE" >> "$LOG_FILE" 2>&1
        log "Container started without GPU"
    fi
    
    # Verify container
    sleep 5
    if docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        log "✅ Container is running"
        log "Container status:"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$CONTAINER_NAME" | tee -a "$LOG_FILE"
    else
        log "❌ Container failed to start"
        log "Container logs:"
        docker logs "$CONTAINER_NAME" 2>/dev/null | tail -20 | tee -a "$LOG_FILE" || true
    fi
    
    # Start simple monitoring
    start_monitoring
    
    log "=== AZURE BATCH SETUP COMPLETE ==="
    log "Check logs: tail -f $LOG_FILE"
    log "Check container: docker ps | grep $CONTAINER_NAME"
    log "Check GPU: nvidia-smi 2>/dev/null || echo 'No GPU'"
}

# ========== START MONITORING ==========
start_monitoring() {
    log "Starting system monitor..."
    
    # Create monitoring script
    cat > /usr/local/bin/azure-batch-monitor << 'EOF'
#!/bin/bash
while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] STATUS" >> /var/log/azure-batch-status.log
    echo "CPU: $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')" >> /var/log/azure-batch-status.log
    
    if command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null 2>&1; then
        nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader 2>/dev/null | \
            while read line; do
                echo "GPU: $line" >> /var/log/azure-batch-status.log
            done || echo "GPU: Error" >> /var/log/azure-batch-status.log
    else
        echo "GPU: Not available" >> /var/log/azure-batch-status.log
    fi
    
    if docker ps --format '{{.Names}}' | grep -q ai-trainer; then
        echo "Container: RUNNING" >> /var/log/azure-batch-status.log
    else
        echo "Container: STOPPED" >> /var/log/azure-batch-status.log
    fi
    echo "---" >> /var/log/azure-batch-status.log
    sleep 30
done
EOF
    
    chmod +x /usr/local/bin/azure-batch-monitor
    nohup /usr/local/bin/azure-batch-monitor > /dev/null 2>&1 &
    log "Monitor started (PID: $!)"
}

# ========== COMMAND HANDLER ==========
case "${1:-}" in
    "status")
        echo "=== AZURE BATCH STATUS ==="
        echo "Time: $(date)"
        echo ""
        echo "GPU Status:"
        lspci | grep -i nvidia || echo "No NVIDIA GPU"
        echo ""
        echo "NVIDIA Drivers:"
        if command -v nvidia-smi > /dev/null; then
            nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu --format=csv
        else
            echo "nvidia-smi not available"
        fi
        echo ""
        echo "Container Status:"
        docker ps | grep "$CONTAINER_NAME" || echo "Container not running"
        echo ""
        echo "Logs: tail -20 $LOG_FILE"
        ;;
    "logs")
        tail -f "$LOG_FILE"
        ;;
    "container-logs")
        docker logs -f "$CONTAINER_NAME"
        ;;
    "monitor-logs")
        tail -f /var/log/azure-batch-status.log
        ;;
    *)
        # Main setup
        setup
        
        # Keep script alive for Azure Batch
        log "Azure Batch start task running..."
        while true; do
            sleep 3600
        done
        ;;
esac
