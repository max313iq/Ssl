#!/bin/bash
# Complete Docker + NVIDIA + trainer Installation - PERFECT FINAL VERSION
# For Azure Batch account start task
# ALWAYS INSTALL - No checks for existing installations

set -e # Exit on any error

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"
MONITOR_LOG="/var/log/system-status.log"

# Docker credentials - Set in Azure Batch environment variables
DOCKER_USERNAME="${DOCKER_USERNAME:-riccorg}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-UL3bJ_5dDcPF7s#}"

# Colors (DISABLED for Azure Batch)
print_info() { echo "[INFO] $1"; }
print_warning() { echo "[WARNING] $1"; }
print_error() { echo "[ERROR] $1"; }
print_monitor() { echo "[MONITOR] $1"; }

# ========== ENHANCED MONITORING WITH REAL-TIME LOOP ==========
create_enhanced_monitoring_script() {
    print_info "Creating enhanced monitoring script..."
    
    sudo tee /usr/local/bin/enhanced-system-monitor > /dev/null << 'EOF'
#!/bin/bash
# Simple monitor without colors for Azure Batch
LOG_FILE="/var/log/system-monitor.log"

while true; do
    echo "=== SYSTEM STATUS: $(date) ===" >> "$LOG_FILE"
    
    # CPU Usage
    CPU_PERCENT=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    echo "CPU: ${CPU_PERCENT}%" >> "$LOG_FILE"
    
    # Memory Usage
    MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    MEM_USED=$(free -m | awk '/^Mem:/{print $3}')
    MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    echo "Memory: ${MEM_USED}MB/${MEM_TOTAL}MB (${MEM_PERCENT}%)" >> "$LOG_FILE"
    
    # GPU Status (if available)
    if command -v nvidia-smi &> /dev/null; then
        GPU_UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
        GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 || echo "N/A")
        GPU_MEM=$(nvidia-smi --query-gpu=utilization.memory --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
        
        echo "GPU Utilization: ${GPU_UTIL}%" >> "$LOG_FILE"
        echo "GPU Memory: ${GPU_MEM}%" >> "$LOG_FILE"
        echo "GPU Temperature: ${GPU_TEMP}°C" >> "$LOG_FILE"
    else
        echo "GPU: Not available" >> "$LOG_FILE"
    fi
    
    # Container Status
    if docker ps --format 'table {{.Names}}' | grep -q ai-trainer; then
        CONTAINER_STATS=$(docker stats ai-trainer --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" 2>/dev/null || echo "N/A N/A")
        echo "Container: RUNNING - ${CONTAINER_STATS}" >> "$LOG_FILE"
    else
        echo "Container: STOPPED" >> "$LOG_FILE"
    fi
    
    echo "---" >> "$LOG_FILE"
    
    # Wait 30 seconds
    sleep 30
done
EOF
    
    sudo chmod +x /usr/local/bin/enhanced-system-monitor
}

start_enhanced_monitoring() {
    print_info "Starting enhanced system monitor..."
    
    # Kill any existing monitor
    if [ -f /var/run/system-monitor.pid ]; then
        sudo kill $(cat /var/run/system-monitor.pid) 2>/dev/null || true
        sudo rm -f /var/run/system-monitor.pid
    fi
    
    create_enhanced_monitoring_script
    
    # Start monitoring in background
    nohup /usr/local/bin/enhanced-system-monitor > /dev/null 2>&1 &
    MONITOR_PID=$!
    echo $MONITOR_PID | sudo tee /var/run/system-monitor.pid > /dev/null
    
    print_info "Enhanced monitor started (PID: $MONITOR_PID)"
    print_info "Monitor logs: tail -f /var/log/system-monitor.log"
}

# ========== DOCKER LOGIN FUNCTION ==========
docker_login() {
    print_info "Attempting Docker login..."
    
    if [[ -n "$DOCKER_USERNAME" && -n "$DOCKER_PASSWORD" ]]; then
        print_info "Logging in to Docker Hub as $DOCKER_USERNAME..."
        
        # First, logout to clear any existing sessions
        sudo docker logout docker.io 2>/dev/null || true
        
        # Login to Docker using credentials
        if echo "$DOCKER_PASSWORD" | sudo docker login docker.io \
            --username "$DOCKER_USERNAME" \
            --password-stdin > /dev/null 2>&1; then
            print_info "Docker login successful!"
            return 0
        else
            print_warning "Docker login failed. Continuing without authenticated pull..."
            return 1
        fi
    else
        print_warning "No Docker credentials provided."
        return 1
    fi
}

# ========== CLEANUP EXISTING INSTALLATIONS ==========
cleanup_existing_installations() {
    print_info "Cleaning up existing installations..."
    
    # Stop and remove existing containers
    sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
    sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Remove any dangling images
    sudo docker image prune -f 2>/dev/null || true
    
    # Kill existing monitoring
    if [ -f /var/run/system-monitor.pid ]; then
        sudo kill $(cat /var/run/system-monitor.pid) 2>/dev/null || true
        sudo rm -f /var/run/system-monitor.pid
    fi
    
    # Clean up any NVIDIA modules
    sudo rmmod nvidia_drm 2>/dev/null || true
    sudo rmmod nvidia_uvm 2>/dev/null || true
    sudo rmmod nvidia_modeset 2>/dev/null || true
    sudo rmmod nvidia 2>/dev/null || true
    
    print_info "Cleanup completed"
}

# ========== NVIDIA DRIVER INSTALLATION (ALWAYS INSTALL) ==========
install_nvidia_drivers() {
    print_info "Installing NVIDIA drivers..."
    
    # Always remove existing NVIDIA packages first
    print_info "Removing existing NVIDIA packages..."
    sudo apt-get remove --purge -yq "nvidia*" "cuda*" "libnvidia*" 2>/dev/null || true
    sudo apt-get autoremove -yq 2>/dev/null || true
    
    # Update package list
    sudo apt-get update -yq
    
    # Install ubuntu-drivers-common if not present
    sudo apt-get install -yq ubuntu-drivers-common
    
    # Method 1: Use ubuntu-drivers (non-interactive)
    print_info "Using ubuntu-drivers to auto-install NVIDIA drivers..."
    
    # For non-interactive installation, we need to use debconf preseed
    echo "debconf debconf/frontend select noninteractive" | sudo debconf-set-selections
    
    # Install recommended drivers
    sudo ubuntu-drivers autoinstall
    
    # Alternative method if autoinstall doesn't work
    if [ $? -ne 0 ]; then
        print_warning "ubuntu-drivers autoinstall failed, trying manual method..."
        
        # Get recommended driver
        RECOMMENDED=$(ubuntu-drivers list | grep -o "nvidia-driver-[0-9]\+" | head -1)
        
        if [ -n "$RECOMMENDED" ]; then
            print_info "Installing $RECOMMENDED..."
            sudo apt-get install -yq "$RECOMMENDED"
        else
            # Try a common driver version
            print_info "Trying common driver: nvidia-driver-535"
            sudo apt-get install -yq nvidia-driver-535
        fi
    fi
    
    # Verify installation
    if modinfo nvidia > /dev/null 2>&1; then
        print_info "NVIDIA drivers installed successfully"
        return 0
    else
        print_error "NVIDIA driver installation may have failed"
        return 1
    fi
}

# ========== NVIDIA CONTAINER TOOLKIT INSTALLATION (ALWAYS INSTALL) ==========
install_nvidia_container_toolkit() {
    print_info "Installing NVIDIA Container Toolkit..."
    
    # Remove existing NVIDIA container toolkit
    sudo apt-get remove --purge -yq nvidia-container-toolkit nvidia-docker2 2>/dev/null || true
    sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list 2>/dev/null || true
    
    # Add NVIDIA repository
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    
    print_info "Detected distribution: $distribution"
    
    # Download and add NVIDIA GPG key
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    # Download and configure the repository list
    curl -s -L "https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list" | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    
    # Update and install
    sudo apt-get update -yq
    sudo apt-get install -yq nvidia-container-toolkit
    
    print_info "Configuring Docker for NVIDIA..."
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    
    print_info "NVIDIA Container Toolkit installed and configured successfully"
    return 0
}

# ========== DOCKER INSTALLATION (ALWAYS INSTALL) ==========
install_docker() {
    print_info "Installing Docker..."
    
    # Remove existing Docker installations
    sudo apt-get remove --purge -yq docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Update package list
    sudo apt-get update -yq
    sudo apt-get upgrade -yq
    
    # Install Docker
    sudo apt-get install -yq docker.io docker-compose-v2
    
    # Start and enable Docker
    sudo systemctl start docker
    sudo systemctl enable docker
    
    print_info "Docker installed successfully"
}

# ========== ALWAYS INSTALL EVERYTHING (NO CHECKS) ==========
install_everything() {
    print_info "=== ALWAYS INSTALLING EVERYTHING ==="
    
    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive
    
    # Clean up first
    cleanup_existing_installations
    
    # Step 1: Always install Docker
    print_info "=== STEP 1: INSTALLING DOCKER ==="
    install_docker
    
    # Step 2: Docker login
    docker_login
    
    # Step 3: Check for NVIDIA GPU and install if present
    if lspci | grep -i nvidia > /dev/null; then
        print_info "NVIDIA GPU detected"
        
        print_info "=== STEP 2: INSTALLING NVIDIA DRIVERS ==="
        if install_nvidia_drivers; then
            print_info "=== STEP 3: INSTALLING NVIDIA CONTAINER TOOLKIT ==="
            if install_nvidia_container_toolkit; then
                REBOOT_NEEDED=true
                print_info "NVIDIA installation complete - REBOOT REQUIRED"
            else
                print_warning "NVIDIA Container Toolkit installation failed"
                REBOOT_NEEDED=true  # Still need reboot for drivers
            fi
        else
            print_warning "NVIDIA driver installation failed. Continuing without GPU support."
            REBOOT_NEEDED=false
        fi
    else
        print_warning "No NVIDIA GPU detected. Skipping NVIDIA driver installation."
        REBOOT_NEEDED=false
    fi
    
    print_info "✅ All base tools installed."
    
    # Start enhanced monitoring
    start_enhanced_monitoring
    
    # Schedule reboot if needed
    if [ "$REBOOT_NEEDED" = true ]; then
        print_info "Scheduling reboot in 1 minute for NVIDIA drivers to take effect..."
        
        # Create a flag file to indicate post-reboot should run
        sudo touch /var/run/azure-batch-reboot.flag
        
        # Create post-reboot script
        sudo tee /usr/local/bin/post-reboot-setup > /dev/null << 'EOF'
#!/bin/bash
sleep 30
cd /tmp
curl -O https://raw.githubusercontent.com/max313iq/Ssl/main/docker_nvidia_install.sh
bash docker_nvidia_install.sh post-reboot
EOF
        sudo chmod +x /usr/local/bin/post-reboot-setup
        
        print_info "System will reboot in 1 minute. After reboot, the trainer will start automatically."
        shutdown -r +1
        
        # Keep the script alive briefly to show messages
        sleep 65
        exit 0
    else
        # If no reboot needed, proceed directly to running trainer
        run_trainer
    fi
}

# ========== POST-REBOOT SETUP ==========
post_reboot() {
    print_info "=== POST-REBOOT SETUP ==="
    
    # Wait for network and Docker
    print_info "Waiting for network and services..."
    sleep 30
    until systemctl is-active --quiet docker; do
        print_info "Waiting for Docker service..."
        sleep 5
    done
    
    # Docker login again after reboot
    docker_login
    
    # Check if NVIDIA drivers are loaded
    if command -v nvidia-smi &> /dev/null && nvidia-smi > /dev/null 2>&1; then
        print_info "NVIDIA drivers working after reboot!"
    else
        print_warning "NVIDIA drivers not working after reboot"
    fi
    
    # Re-start enhanced monitoring
    start_enhanced_monitoring
    
    run_trainer
    
    # Clean up reboot flag
    sudo rm -f /var/run/azure-batch-reboot.flag 2>/dev/null || true
}

# ========== RUN TRAINER CONTAINER ==========
run_trainer() {
    print_info "=== STARTING TRAINER CONTAINER ==="
    
    # Pull the image (always pull latest)
    print_info "Pulling latest image..."
    sudo docker pull "$IMAGE" || print_warning "Failed to pull image, using local if available"
    
    # Remove existing container if present
    sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
    sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Run container with appropriate GPU support
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
    
    print_info "Trainer container started!"
    
    # Show status
    sleep 3
    print_info "Container status:"
    sudo docker ps --format "table {{.Names}}\t{{.Status}}" | grep "$CONTAINER_NAME"
    
    # Clean up reboot flag if it exists
    sudo rm -f /var/run/azure-batch-reboot.flag 2>/dev/null || true
}

# ========== MAIN EXECUTION FOR AZURE BATCH ==========
main() {
    print_info "Starting Azure Batch ALWAYS INSTALL script..."
    
    # Check if we're in post-reboot phase
    if [ -f /var/run/azure-batch-reboot.flag ] || [ "$1" = "post-reboot" ]; then
        post_reboot
        exit 0
    fi
    
    # ALWAYS do fresh installation - NO CHECKS for existing installations
    install_everything
    
    print_info "Setup complete. Enhanced monitoring is active."
    print_info "Container logs: sudo docker logs -f $CONTAINER_NAME"
    print_info "Monitor logs: tail -f /var/log/system-monitor.log"
    
    # Keep script alive for Azure Batch
    print_info "Running in Azure Batch mode - keeping script alive..."
    while true; do
        sleep 3600
    done
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
            start_enhanced_monitoring
            ;;
        "logs")
            sudo docker logs -f "$CONTAINER_NAME"
            ;;
        "status")
            sudo docker ps -a | grep "$CONTAINER_NAME"
            echo ""
            echo "GPU Status:"
            if command -v nvidia-smi > /dev/null; then
                nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu --format=csv
            else
                echo "NVIDIA drivers not loaded"
            fi
            ;;
        "stop")
            sudo docker stop "$CONTAINER_NAME"
            ;;
        "batch-mode")
            # Run in Azure Batch mode
            main "batch-mode"
            ;;
        "clean")
            cleanup_existing_installations
            ;;
        *)
            # Default: run main
            main "$@"
            ;;
    esac
fi
