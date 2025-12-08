#!/bin/bash
# Azure Batch Docker + NVIDIA Installation - FIXED VERSION
# No GPG tty issues, no at command needed, continues after reboot

set -e

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"

# Log files
INSTALL_LOG="/var/log/batch-install.log"
BATCH_STATUS_FILE="/var/log/batch-task.status"

# Docker credentials
DOCKER_USERNAME="riccorg"
DOCKER_PASSWORD="UL3bJ_5dDcPF7s#"

# Initialize
mkdir -p /var/log
echo "=== AZURE BATCH START: $(date) ===" > "$INSTALL_LOG"
echo "READY" > "$BATCH_STATUS_FILE"

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$INSTALL_LOG"
}

# ========== FIXED FUNCTIONS ==========

docker_login() {
    log "Docker login..."
    # Use --batch to avoid tty issues
    echo "$DOCKER_PASSWORD" | docker login docker.io \
        --username "$DOCKER_USERNAME" \
        --password-stdin > /dev/null 2>&1 && log "Login OK" || log "Login failed, continuing"
}

install_nvidia_fixed() {
    log "Installing NVIDIA drivers (non-interactive)..."
    
    # Fix GPG tty issue
    export GPG_TTY=$(tty) 2>/dev/null || true
    export GNUPGHOME=/tmp/gnupg
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    
    # Install without interactive prompts
    export DEBIAN_FRONTEND=noninteractive
    
    # Install ubuntu-drivers and nvidia drivers
    apt-get install -yq ubuntu-drivers-common >> "$INSTALL_LOG" 2>&1
    
    # Get recommended driver
    DRIVER=$(ubuntu-drivers list | grep -o "nvidia-driver-[0-9]\+" | head -1)
    if [ -n "$DRIVER" ]; then
        log "Installing driver: $DRIVER"
        apt-get install -yq "$DRIVER" >> "$INSTALL_LOG" 2>&1
    else
        ubuntu-drivers autoinstall >> "$INSTALL_LOG" 2>&1
    fi
    
    # Wait for drivers to load
    sleep 5
    
    if modinfo nvidia > /dev/null 2>&1; then
        log "NVIDIA drivers OK"
        
        # Install NVIDIA container toolkit WITHOUT GPG tty issues
        log "Installing NVIDIA container toolkit..."
        
        distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
        
        # Download GPG key without interactive prompts
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            gpg --batch --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>> "$INSTALL_LOG"
        
        # Add repository
        echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/\$distribution/\$(arch) /" | \
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
        
        apt-get update -yq >> "$INSTALL_LOG" 2>&1
        apt-get install -yq nvidia-container-toolkit >> "$INSTALL_LOG" 2>&1
        
        # Configure Docker
        nvidia-ctk runtime configure --runtime=docker >> "$INSTALL_LOG" 2>&1
        systemctl restart docker >> "$INSTALL_LOG" 2>&1
        
        log "NVIDIA toolkit installed"
        return 0
    else
        log "NVIDIA drivers not loaded"
        return 1
    fi
}

# ========== SIMPLIFIED INSTALL ==========
install_all() {
    log "=== AZURE BATCH INSTALLATION ==="
    
    # Update system
    log "Updating system..."
    apt-get update -yq >> "$INSTALL_LOG" 2>&1
    
    # Install Docker if not present
    if ! command -v docker > /dev/null; then
        log "Installing Docker..."
        apt-get install -yq docker.io >> "$INSTALL_LOG" 2>&1
        systemctl start docker
        systemctl enable docker
    else
        log "Docker already installed"
    fi
    
    # Docker login
    docker_login
    
    # Check for NVIDIA GPU
    if lspci | grep -i nvidia > /dev/null; then
        log "NVIDIA GPU detected"
        
        # Install NVIDIA
        if install_nvidia_fixed; then
            log "NVIDIA installed successfully"
            
            # Instead of using 'at' (which isn't installed), create a systemd service for reboot
            log "Creating reboot service..."
            
            cat > /etc/systemd/system/post-reboot.service << EOF
[Unit]
Description=Post-Reboot Setup
After=network.target docker.service

[Service]
Type=simple
ExecStart=/bin/bash -c "curl -s https://raw.githubusercontent.com/max313iq/Ssl/refs/heads/main/docker_nvidia_install.sh | bash -s post-reboot"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
            
            # Enable and start the service
            systemctl daemon-reload
            systemctl enable post-reboot.service
            
            log "Rebooting in 30 seconds for NVIDIA drivers..."
            echo "COMPLETE_WITH_REBOOT" > "$BATCH_STATUS_FILE"
            
            # Schedule reboot with systemd instead of 'at'
            shutdown -r +1 "Azure Batch NVIDIA driver reboot"
            exit 0
        else
            log "NVIDIA installation failed, continuing without GPU"
        fi
    else
        log "No NVIDIA GPU detected"
    fi
    
    # Pull and run container
    run_container_setup
    
    log "=== INSTALLATION COMPLETE ==="
    echo "COMPLETE" > "$BATCH_STATUS_FILE"
}

# ========== CONTAINER SETUP ==========
run_container_setup() {
    log "Setting up container..."
    
    # Pull image with retry
    for i in {1..3}; do
        log "Pull attempt $i/3"
        if docker pull "$IMAGE" >> "$INSTALL_LOG" 2>&1; then
            log "Image pulled"
            break
        fi
        sleep 10
    done
    
    # Stop existing container
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Start container
    if command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null 2>&1; then
        log "Starting with GPU"
        docker run -d \
            --gpus all \
            --restart unless-stopped \
            --name "$CONTAINER_NAME" \
            "$IMAGE" >> "$INSTALL_LOG" 2>&1
    else
        log "Starting without GPU"
        docker run -d \
            --restart unless-stopped \
            --name "$CONTAINER_NAME" \
            "$IMAGE" >> "$INSTALL_LOG" 2>&1
    fi
    
    # Verify
    sleep 3
    if docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        log "Container running"
        docker ps --format "table {{.Names}}\t{{.Status}}" | grep "$CONTAINER_NAME" | tee -a "$INSTALL_LOG"
    else
        log "Container failed"
    fi
    
    # Start simple monitor
    start_simple_monitor
}

# ========== SIMPLE MONITOR ==========
start_simple_monitor() {
    log "Starting monitor..."
    
    cat > /usr/local/bin/simple-monitor << 'EOF'
#!/bin/bash
while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CPU: $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')" >> /var/log/system-monitor.log
    if command -v nvidia-smi > /dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] GPU: $(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null || echo 'N/A')%" >> /var/log/system-monitor.log
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Container: $(docker ps --format '{{.Names}} {{.Status}}' | grep ai-trainer || echo 'Not running')" >> /var/log/system-monitor.log
    sleep 30
done
EOF
    
    chmod +x /usr/local/bin/simple-monitor
    nohup /usr/local/bin/simple-monitor > /dev/null 2>&1 &
    log "Monitor started"
}

# ========== POST-REBOOT ==========
post_reboot() {
    log "=== POST-REBOOT SETUP ==="
    
    # Wait for network and Docker
    sleep 20
    until systemctl is-active --quiet docker; do
        sleep 5
    done
    
    # Login again
    docker_login
    
    # Run container setup
    run_container_setup
    
    log "=== POST-REBOOT COMPLETE ==="
    echo "POST_REBOOT_COMPLETE" > "$BATCH_STATUS_FILE"
    
    # Remove the reboot service
    systemctl disable post-reboot.service 2>/dev/null || true
    rm -f /etc/systemd/system/post-reboot.service
}

# ========== MAIN ==========
main() {
    case "$1" in
        "post-reboot")
            post_reboot
            ;;
        "status")
            echo "=== STATUS ==="
            echo "Install log: $INSTALL_LOG"
            tail -20 "$INSTALL_LOG"
            echo ""
            echo "Container:"
            docker ps | grep "$CONTAINER_NAME" || echo "Not running"
            echo ""
            echo "GPU:"
            command -v nvidia-smi && nvidia-smi --query-gpu=name,utilization.gpu --format=csv || echo "Not available"
            ;;
        "logs")
            tail -f "$INSTALL_LOG"
            ;;
        "container-logs")
            docker logs -f "$CONTAINER_NAME"
            ;;
        "monitor-logs")
            tail -f /var/log/system-monitor.log
            ;;
        *)
            # Default: full installation
            install_all
            
            # Keep alive for Azure Batch
            log "Azure Batch task running..."
            while true; do
                sleep 3600
            done
            ;;
    esac
}

# Run
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    main "$@"
fi
