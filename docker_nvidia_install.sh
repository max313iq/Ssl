#!/bin/bash
# Azure Batch Docker + NVIDIA Installation - BATCH OPTIMIZED VERSION
# All output goes to log files, no console output needed
export DOCKER_USERNAME="riccorg"
export DOCKER_PASSWORD="UL3bJ_5dDcPF7s#"
set -e

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"

# Log files for Azure Batch
INSTALL_LOG="/var/log/batch-install.log"
CONTAINER_LOG="/var/log/container-status.log"
MONITOR_LOG="/var/log/system-monitor.log"
BATCH_STATUS_FILE="/var/log/batch-task.status"

# Docker credentials - Set in Azure Batch environment
DOCKER_USERNAME="${DOCKER_USERNAME:-}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}"

# Initialize log files
mkdir -p /var/log
echo "=== AZURE BATCH START TASK STARTED: $(date) ===" > "$INSTALL_LOG"
echo "=== CONTAINER STATUS ===" > "$CONTAINER_LOG"
echo "READY" > "$BATCH_STATUS_FILE"

# Log function for Azure Batch
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$INSTALL_LOG"
}

log_warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $1" | tee -a "$INSTALL_LOG"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$INSTALL_LOG"
    echo "FAILED: $1" > "$BATCH_STATUS_FILE"
}

update_container_status() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$CONTAINER_LOG"
}

# ========== ERROR HANDLING ==========
handle_error() {
    log_error "Script failed: $1"
    exit 1
}

trap 'handle_error "Unexpected termination"' ERR

# ========== DOCKER LOGIN ==========
docker_login() {
    log_info "Attempting Docker login..."
    
    if [[ -n "$DOCKER_USERNAME" && -n "$DOCKER_PASSWORD" ]]; then
        if echo "$DOCKER_PASSWORD" | sudo docker login docker.io \
            --username "$DOCKER_USERNAME" \
            --password-stdin >> "$INSTALL_LOG" 2>&1; then
            log_info "Docker login successful"
            return 0
        else
            log_warning "Docker login failed, continuing without auth"
            return 1
        fi
    else
        log_warning "No Docker credentials provided"
        return 1
    fi
}

# ========== DOCKER PULL ==========
docker_pull() {
    log_info "Pulling image: $IMAGE"
    
    for i in {1..3}; do
        if sudo docker pull "$IMAGE" >> "$INSTALL_LOG" 2>&1; then
            log_info "Image pulled successfully (attempt $i)"
            return 0
        else
            log_warning "Pull failed attempt $i, retrying in 10s..."
            sleep 10
        fi
    done
    
    log_error "Failed to pull image after 3 attempts"
    return 1
}

# ========== BATCH MONITORING SERVICE ==========
create_batch_monitor() {
    cat > /usr/local/bin/batch-monitor << 'EOF'
#!/bin/bash
# Azure Batch Monitor Service - Logs to files only

INSTALL_LOG="/var/log/batch-install.log"
CONTAINER_LOG="/var/log/container-status.log"
MONITOR_LOG="/var/log/system-monitor.log"

log_monitor() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$MONITOR_LOG"
}

while true; do
    # Log system status every 30 seconds
    echo "=== SYSTEM STATUS: $(date) ===" >> "$MONITOR_LOG"
    
    # CPU
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    echo "CPU: ${CPU_USAGE}%" >> "$MONITOR_LOG"
    
    # Memory
    MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    MEM_USED=$(free -m | awk '/^Mem:/{print $3}')
    MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    echo "Memory: ${MEM_PERCENT}% (${MEM_USED}MB/${MEM_TOTAL}MB)" >> "$MONITOR_LOG"
    
    # GPU if available
    if command -v nvidia-smi &> /dev/null; then
        GPU_USAGE=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
        GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1)
        GPU_MEM=$(nvidia-smi --query-gpu=utilization.memory --format=csv,noheader,nounits 2>/dev/null | head -1)
        echo "GPU: ${GPU_USAGE}% (Memory: ${GPU_MEM}%, Temp: ${GPU_TEMP}°C)" >> "$MONITOR_LOG"
    fi
    
    # Container status
    if docker ps --format '{{.Names}}' | grep -q ai-trainer; then
        CONTAINER_CPU=$(docker stats ai-trainer --no-stream --format "{{.CPUPerc}}" 2>/dev/null || echo "N/A")
        CONTAINER_MEM=$(docker stats ai-trainer --no-stream --format "{{.MemUsage}}" 2>/dev/null || echo "N/A")
        echo "Container: RUNNING (CPU: $CONTAINER_CPU, MEM: $CONTAINER_MEM)" >> "$MONITOR_LOG"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Container RUNNING - CPU: $CONTAINER_CPU, MEM: $CONTAINER_MEM" >> "$CONTAINER_LOG"
    else
        echo "Container: STOPPED" >> "$MONITOR_LOG"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Container STOPPED" >> "$CONTAINER_LOG"
    fi
    
    echo "---" >> "$MONITOR_LOG"
    
    # Wait 30 seconds
    sleep 30
done
EOF
    
    chmod +x /usr/local/bin/batch-monitor
}

start_batch_monitor() {
    log_info "Starting Azure Batch monitor service..."
    create_batch_monitor
    nohup /usr/local/bin/batch-monitor >> "$INSTALL_LOG" 2>&1 &
    echo $! > /var/run/batch-monitor.pid
    log_info "Batch monitor started (PID: $(cat /var/run/batch-monitor.pid))"
}

# ========== NVIDIA INSTALLATION ==========
install_nvidia() {
    log_info "Installing NVIDIA drivers..."
    
    export DEBIAN_FRONTEND=noninteractive
    echo "debconf debconf/frontend select noninteractive" | sudo debconf-set-selections
    
    if ! sudo ubuntu-drivers autoinstall >> "$INSTALL_LOG" 2>&1; then
        log_warning "Autoinstall failed, trying manual..."
        DRIVER=$(ubuntu-drivers list | grep -o "nvidia-driver-[0-9]\+" | head -1)
        if [ -n "$DRIVER" ]; then
            sudo apt-get install -yq "$DRIVER" >> "$INSTALL_LOG" 2>&1
        fi
    fi
    
    if modinfo nvidia > /dev/null 2>&1; then
        log_info "NVIDIA drivers installed"
        
        # Install NVIDIA container toolkit
        distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L "https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list" | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
        
        sudo apt-get update -yq >> "$INSTALL_LOG" 2>&1
        sudo apt-get install -yq nvidia-container-toolkit >> "$INSTALL_LOG" 2>&1
        sudo nvidia-ctk runtime configure --runtime=docker >> "$INSTALL_LOG" 2>&1
        sudo systemctl restart docker >> "$INSTALL_LOG" 2>&1
        
        return 0
    else
        log_warning "NVIDIA drivers not detected"
        return 1
    fi
}

# ========== MAIN INSTALLATION ==========
install_all() {
    log_info "=== STARTING AZURE BATCH INSTALLATION ==="
    
    # Install Docker
    log_info "Installing Docker..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -yq >> "$INSTALL_LOG" 2>&1
    sudo apt-get install -yq docker.io >> "$INSTALL_LOG" 2>&1
    sudo systemctl start docker >> "$INSTALL_LOG" 2>&1
    sudo systemctl enable docker >> "$INSTALL_LOG" 2>&1
    
    # Docker login
    docker_login
    
    # Check for GPU and install drivers
    if lspci | grep -i nvidia >> "$INSTALL_LOG" 2>&1; then
        log_info "NVIDIA GPU detected, installing drivers..."
        sudo apt-get install -yq ubuntu-drivers-common >> "$INSTALL_LOG" 2>&1
        if install_nvidia; then
            log_info "NVIDIA installation complete, scheduling reboot..."
            echo "curl -s https://raw.githubusercontent.com/max313iq/Ssl/refs/heads/main/docker_nvidia_install.sh | sudo bash -s post-reboot" | sudo at now + 1 minute
            log_info "Reboot scheduled in 1 minute"
            exit 0
        fi
    else
        log_info "No NVIDIA GPU detected"
    fi
    
    # Start monitoring
    start_batch_monitor
    
    # Pull and run container
    if docker_pull; then
        run_container
    fi
    
    log_info "=== INSTALLATION COMPLETE ==="
    echo "COMPLETE" > "$BATCH_STATUS_FILE"
}

# ========== RUN CONTAINER ==========
run_container() {
    log_info "Starting container: $CONTAINER_NAME"
    update_container_status "Starting container..."
    
    # Stop existing container
    sudo docker stop "$CONTAINER_NAME" >> "$INSTALL_LOG" 2>&1 || true
    sudo docker rm "$CONTAINER_NAME" >> "$INSTALL_LOG" 2>&1 || true
    
    # Run with GPU if available
    if command -v nvidia-smi &> /dev/null && nvidia-smi >> "$INSTALL_LOG" 2>&1; then
        log_info "Starting with GPU support"
        sudo docker run -d \
            --gpus all \
            --restart unless-stopped \
            --name "$CONTAINER_NAME" \
            "$IMAGE" >> "$INSTALL_LOG" 2>&1
    else
        log_info "Starting without GPU support"
        sudo docker run -d \
            --restart unless-stopped \
            --name "$CONTAINER_NAME" \
            "$IMAGE" >> "$INSTALL_LOG" 2>&1
    fi
    
    # Verify container
    sleep 5
    if sudo docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        log_info "Container started successfully"
        update_container_status "Container RUNNING - $(date)"
        echo "CONTAINER_RUNNING" >> "$BATCH_STATUS_FILE"
    else
        log_error "Container failed to start"
        update_container_status "Container FAILED - $(date)"
    fi
}

# ========== POST-REBOOT ==========
post_reboot() {
    log_info "=== POST-REBOOT SETUP ==="
    
    # Wait for services
    sleep 30
    until systemctl is-active --quiet docker; do
        sleep 5
    done
    
    # Login again
    docker_login
    
    # Start monitoring
    if [ ! -f /var/run/batch-monitor.pid ] || ! ps -p $(cat /var/run/batch-monitor.pid) > /dev/null 2>&1; then
        start_batch_monitor
    fi
    
    # Run container
    if docker_pull; then
        run_container
    fi
    
    log_info "=== POST-REBOOT COMPLETE ==="
    echo "COMPLETE" > "$BATCH_STATUS_FILE"
}

# ========== STATUS COMMANDS ==========
# These commands can be run via Azure Batch job manager tasks

check_status() {
    echo "=== AZURE BATCH STATUS CHECK: $(date) ==="
    echo "Install Log: $INSTALL_LOG"
    echo "Container Log: $CONTAINER_LOG"
    echo "Monitor Log: $MONITOR_LOG"
    echo ""
    
    # Overall status
    if [ -f "$BATCH_STATUS_FILE" ]; then
        echo "Task Status: $(cat "$BATCH_STATUS_FILE")"
    else
        echo "Task Status: UNKNOWN"
    fi
    echo ""
    
    # Container status
    if sudo docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        echo "Container: RUNNING"
        sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$CONTAINER_NAME"
    else
        echo "Container: NOT RUNNING"
    fi
    echo ""
    
    # GPU status
    if command -v nvidia-smi &> /dev/null; then
        echo "GPU Status:"
        nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu --format=csv
    else
        echo "GPU: Not available"
    fi
    echo ""
    
    # Recent logs
    echo "=== RECENT INSTALL LOG (last 10 lines) ==="
    tail -10 "$INSTALL_LOG"
    echo ""
    echo "=== RECENT MONITOR LOG (last 5 entries) ==="
    tail -20 "$MONITOR_LOG" | grep -A 1 "SYSTEM STATUS" | tail -10
}

show_logs() {
    case "$1" in
        install)
            tail -f "$INSTALL_LOG"
            ;;
        container)
            tail -f "$CONTAINER_LOG"
            ;;
        monitor)
            tail -f "$MONITOR_LOG"
            ;;
        docker)
            sudo docker logs -f "$CONTAINER_NAME"
            ;;
        *)
            echo "Usage: $0 logs {install|container|monitor|docker}"
            ;;
    esac
}

# ========== MAIN ==========
main() {
    case "$1" in
        "post-reboot")
            post_reboot
            ;;
        "status")
            check_status
            ;;
        "logs")
            show_logs "$2"
            ;;
        "install-only")
            install_all
            ;;
        "start-only")
            docker_login
            docker_pull
            run_container
            ;;
        "batch-mode")
            # Main Azure Batch mode - run everything
            install_all
            
            # Keep running for Azure Batch
            log_info "Azure Batch start task running..."
            while true; do
                sleep 3600
            done
            ;;
        *)
            # Default: run in batch mode
            install_all
            while true; do
                sleep 3600
            done
            ;;
    esac
}

# Run main
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    main "$@"
fi
