#!/bin/bash
# Complete Docker + NVIDIA + trainer Installation - NON-INTERACTIVE VERSION
# For Azure Batch account start task - FULLY AUTOMATED, NO INTERACTION

set -e # Exit on any error

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"
MONITOR_LOG="/var/log/system-status.log"

# Docker credentials - MUST be set as environment variables in Azure Batch
DOCKER_USERNAME="${DOCKER_USERNAME:-}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}"
DOCKER_REGISTRY="docker.io"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ========== DOCKER LOGIN FUNCTION ==========
docker_login() {
    print_info "Attempting Docker login..."
    
    if [[ -n "$DOCKER_USERNAME" && -n "$DOCKER_PASSWORD" ]]; then
        print_info "Logging in to Docker Hub..."
        echo "$DOCKER_PASSWORD" | sudo docker login "$DOCKER_REGISTRY" \
            --username "$DOCKER_USERNAME" \
            --password-stdin > /dev/null 2>&1 && print_info "Docker login successful" || print_warning "Docker login failed"
    fi
}

# ========== MONITORING FUNCTIONS ==========
create_monitoring_script() {
    print_info "Creating monitoring script..."
    
    sudo tee /usr/local/bin/system-monitor > /dev/null << 'EOF'
#!/bin/bash
while true; do
    sleep 600
    echo ""
    echo "=== 10-MINUTE STATUS REPORT ==="
    echo "Time: $(date)"
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    echo "CPU: ${CPU_USAGE}%"
    
    if command -v nvidia-smi &> /dev/null; then
        GPU_USAGE=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader | head -1 2>/dev/null || echo "N/A")
        GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | head -1 2>/dev/null || echo "N/A")
        echo "GPU: ${GPU_USAGE} (${GPU_TEMP}°C)"
    else
        echo "GPU: Not available"
    fi
    
    if docker ps --format 'table {{.Names}}' | grep -q ai-trainer; then
        echo "Container: RUNNING"
        CONTAINER_STATS=$(docker stats ai-trainer --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" 2>/dev/null || echo "N/A")
        echo "Container Stats: ${CONTAINER_STATS}"
    else
        echo "Container: STOPPED"
    fi
    echo "==============================="
done
EOF
    
    sudo chmod +x /usr/local/bin/system-monitor
}

start_monitoring() {
    print_info "Starting system monitor..."
    create_monitoring_script
    nohup /usr/local/bin/system-monitor >> "$MONITOR_LOG" 2>&1 &
    MONITOR_PID=$!
    echo $MONITOR_PID | sudo tee /var/run/system-monitor.pid > /dev/null
}

# ========== NVIDIA DRIVER INSTALLATION ==========
install_nvidia_drivers() {
    print_info "Installing NVIDIA drivers..."
    
    echo "debconf debconf/frontend select noninteractive" | sudo debconf-set-selections
    sudo ubuntu-drivers autoinstall
    
    if [ $? -ne 0 ]; then
        print_warning "ubuntu-drivers autoinstall failed, trying manual method..."
        RECOMMENDED=$(ubuntu-drivers list | grep -o "nvidia-driver-[0-9]\+" | head -1)
        
        if [ -n "$RECOMMENDED" ]; then
            sudo apt-get install -yq "$RECOMMENDED"
        else
            print_error "Could not determine NVIDIA driver to install"
            return 1
        fi
    fi
    
    if modinfo nvidia > /dev/null 2>&1; then
        print_info "NVIDIA drivers installed successfully"
        return 0
    else
        print_error "NVIDIA driver installation may have failed"
        return 1
    fi
}

# ========== ALWAYS INSTALL EVERYTHING ==========
install_everything() {
    print_info "=== STEP 1: INSTALLING DOCKER ==="
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -yq
    sudo apt-get upgrade -yq
    sudo apt-get install -yq docker.io docker-compose-v2
    sudo systemctl start docker
    sudo systemctl enable docker
    
    docker_login
    
    if lspci | grep -i nvidia > /dev/null; then
        print_info "=== STEP 2: INSTALLING NVIDIA DRIVERS ==="
        sudo apt-get install -yq ubuntu-drivers-common
        
        if install_nvidia_drivers; then
            print_info "=== STEP 3: INSTALLING NVIDIA CONTAINER TOOLKIT ==="
            distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
            curl -s -L "https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list" | \
                sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
                sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
            
            sudo apt-get update -yq
            sudo apt-get install -yq nvidia-container-toolkit
            
            print_info "=== STEP 4: CONFIGURING DOCKER FOR NVIDIA ==="
            sudo nvidia-ctk runtime configure --runtime=docker
            sudo systemctl restart docker
            
            REBOOT_NEEDED=true
        else
            print_warning "NVIDIA driver installation failed. Continuing without GPU support."
            REBOOT_NEEDED=false
        fi
    else
        print_warning "No NVIDIA GPU detected. Skipping NVIDIA driver installation."
        REBOOT_NEEDED=false
    fi
    
    print_info "All tools installed."
    start_monitoring
    
    if [ "$REBOOT_NEEDED" = true ]; then
        print_info "Scheduling reboot in 1 minute for NVIDIA drivers..."
        echo "sudo /bin/bash $0 post-reboot" | sudo at now + 1 minute
        print_info "System will reboot in 1 minute."
    else
        run_trainer
    fi
    exit 0
}

# ========== POST-REBOOT ==========
post_reboot() {
    print_info "=== POST-REBOOT SETUP ==="
    sleep 30
    until systemctl is-active --quiet docker; do
        sleep 5
    done
    
    docker_login
    
    if [ ! -f /var/run/system-monitor.pid ] || ! ps -p $(cat /var/run/system-monitor.pid) > /dev/null 2>&1; then
        start_monitoring
    fi
    
    run_trainer
}

run_trainer() {
    print_info "=== STARTING trainer CONTAINER ==="
    
    print_info "Pulling image: $IMAGE"
    MAX_RETRIES=3
    RETRY_COUNT=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if sudo docker pull "$IMAGE"; then
            print_info "Image pulled successfully!"
            break
        else
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                print_warning "Pull failed. Retry $RETRY_COUNT of $MAX_RETRIES..."
                sleep 10
            else
                print_warning "Failed to pull image. Using local if available..."
            fi
        fi
    done
    
    sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
    sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    if command -v nvidia-smi &> /dev/null && nvidia-smi > /dev/null 2>&1; then
        print_info "Starting with NVIDIA GPU support..."
        sudo docker run -d \
          --gpus all \
          --restart unless-stopped \
          --name "$CONTAINER_NAME" \
          "$IMAGE"
    else
        print_info "Starting without GPU support..."
        sudo docker run -d \
          --restart unless-stopped \
          --name "$CONTAINER_NAME" \
          "$IMAGE"
    fi
    
    print_info "trainer container started!"
    sleep 3
    sudo docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
    sudo docker logs --tail 10 "$CONTAINER_NAME"
}

# ========== CLEANUP ==========
cleanup() {
    print_info "Cleaning up..."
    if [ -f /var/run/system-monitor.pid ]; then
        MONITOR_PID=$(cat /var/run/system-monitor.pid)
        if kill -0 "$MONITOR_PID" 2>/dev/null; then
            kill "$MONITOR_PID"
        fi
        sudo rm -f /var/run/system-monitor.pid
    fi
    unset DOCKER_USERNAME
    unset DOCKER_PASSWORD
}

trap cleanup EXIT

# ========== MAIN EXECUTION FOR AZURE BATCH ==========
main() {
    print_info "Starting Azure Batch setup script..."
    
    if [ "$1" = "post-reboot" ]; then
        post_reboot
        exit 0
    fi
    
    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        print_info "Docker already installed and running."
        docker_login
        
        if sudo docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
            print_info "Container $CONTAINER_NAME is already running."
        else
            print_info "Starting trainer container..."
            run_trainer
        fi
        
        start_monitoring
    else
        install_everything
    fi
    
    print_info "Setup complete. Monitoring is active."
    
    if [ "$1" = "batch-mode" ] || [ -z "$1" ]; then
        print_info "Running in Azure Batch mode - keeping script alive..."
        while true; do
            sleep 3600
        done
    fi
}

# ========== COMMAND LINE HANDLER ==========
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    case "$1" in
        "install")
            install_everything
            ;;
        "start")
            run_trainer
            ;;
        "post-reboot")
            post_reboot
            ;;
        "monitor")
            start_monitoring
            ;;
        "logs")
            sudo docker logs -f "$CONTAINER_NAME"
            ;;
        "status")
            sudo docker ps -a | grep "$CONTAINER_NAME"
            ;;
        "stop")
            sudo docker stop "$CONTAINER_NAME"
            ;;
        "batch-mode")
            main "batch-mode"
            ;;
        *)
            main "$@"
            ;;
    esac
fi
