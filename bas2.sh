#!/bin/bash
# Azure Batch NVIDIA + Docker GPU Setup with Enhanced Monitoring
# Optimized for Azure Batch Pool Start Task
# FIXED VERSION: Pins specific package versions to resolve dependency conflicts

set -e # Exit on any error

# ---------------------------
# Configuration
# ---------------------------
IMAGE="riccorg/ml-compute-platform:latest"
CONTAINER_NAME="ai-trainer"
MONITOR_LOG="/var/log/system-monitor.log"
FLAG_FILE="/var/tmp/nvidia_ready"
NVIDIA_CONTAINER_VERSION="1.18.1-1"  # Pinned version to avoid conflicts

# Docker credentials - Set in Azure Batch environment variables
DOCKER_USERNAME="${DOCKER_USERNAME:-riccorg}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-UL3bJ_5dDcPF7s#}"

# Set non-interactive mode
export DEBIAN_FRONTEND=noninteractive

# ---------------------------
# Logging Functions
# ---------------------------
print_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"; }
print_warning() { echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') $1"; }
print_error() { echo "[ERROR] $(date '+%m-%d %H:%M:%S') $1"; }

# ---------------------------
# Clean Microsoft Repository Issues
# ---------------------------
clean_microsoft_repos() {
    print_info "Cleaning up problematic Microsoft repositories..."
    
    # Backup and remove problematic files
    for repo_file in /etc/apt/sources.list.d/amlfs.list /etc/apt/sources.list.d/slurm.list; do
        if [ -f "$repo_file" ]; then
            sudo mv "$repo_file" "${repo_file}.backup" 2>/dev/null || true
            print_info "Backed up $repo_file to ${repo_file}.backup"
        fi
    done
    
    # Fix any malformed entries that might exist
    sudo rm -f /etc/apt/sources.list.d/amlfs.list /etc/apt/sources.list.d/slurm.list 2>/dev/null || true
}

# ---------------------------
# Docker Login
# ---------------------------
docker_login() {
    print_info "Attempting Docker login..."
    
    if [[ -n "$DOCKER_USERNAME" && -n "$DOCKER_PASSWORD" ]]; then
        print_info "Logging in to Docker Hub as $DOCKER_USERNAME..."
        
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

# ---------------------------
# Install NVIDIA Drivers
# ---------------------------
install_nvidia_drivers() {
    print_info "Installing NVIDIA drivers..."
    
    # Method 1: Use ubuntu-drivers (non-interactive)
    print_info "Using ubuntu-drivers to auto-install NVIDIA drivers..."
    
    # For non-interactive installation
    echo "debconf debconf/frontend select noninteractive" | sudo debconf-set-selections
    
    # Install ubuntu-drivers-common first
    sudo apt-get install -yq ubuntu-drivers-common
    
    # Install recommended drivers
    sudo ubuntu-drivers autoinstall
    
    # Verify installation
    if modinfo nvidia > /dev/null 2>&1; then
        print_info "NVIDIA drivers installed successfully"
        return 0
    else
        print_error "NVIDIA driver installation failed"
        return 1
    fi
}

# ---------------------------
# Install NVIDIA Container Toolkit (FIXED VERSION)
# ---------------------------
install_nvidia_container_toolkit() {
    print_info "Installing NVIDIA Container Toolkit (version-pinned)..."
    
    # Add NVIDIA Container Toolkit repository
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    
    # Add NVIDIA GPG key
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    # Create repository file
    curl -s -L "https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list" | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    
    sudo apt-get update -yq
    
    # FIX: Install specific versions to avoid dependency conflicts
    print_info "Installing version-pinned packages: $NVIDIA_CONTAINER_VERSION"
    
    # First, check what's available
    print_info "Available versions of nvidia-container-toolkit:"
    apt-cache policy nvidia-container-toolkit | grep -E "Candidate|Installed"
    
    print_info "Available versions of libnvidia-container-tools:"
    apt-cache policy libnvidia-container-tools | grep -E "Candidate|Installed"
    
    # Try to install with specific version first
    if sudo apt-get install -yq \
        nvidia-container-toolkit=$NVIDIA_CONTAINER_VERSION \
        nvidia-container-toolkit-base=$NVIDIA_CONTAINER_VERSION \
        libnvidia-container-tools=$NVIDIA_CONTAINER_VERSION \
        libnvidia-container1=$NVIDIA_CONTAINER_VERSION; then
        print_info "✅ Successfully installed version-pinned NVIDIA Container Toolkit"
    else
        print_warning "Version $NVIDIA_CONTAINER_VERSION not available, trying latest compatible version..."
        
        # If specific version fails, install latest with dependency fixing
        sudo apt-get install -yq nvidia-container-toolkit || {
            print_warning "Standard installation failed, attempting dependency fix..."
            
            # Try to fix broken packages
            sudo apt-get -f install -yq
            
            # Try alternative installation approach
            sudo apt-get install -yq \
                nvidia-container-toolkit \
                nvidia-container-toolkit-base \
                libnvidia-container-tools \
                libnvidia-container1
        }
    fi
    
    # Configure Docker for NVIDIA
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    
    print_info "NVIDIA Container Toolkit installed and configured"
}

# ---------------------------
# Enhanced Monitoring
# ---------------------------
create_monitoring_script() {
    print_info "Creating enhanced monitoring script..."
    
    sudo tee /usr/local/bin/system-monitor > /dev/null << 'EOF'
#!/bin/bash
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
    sleep 30
done
EOF
    
    sudo chmod +x /usr/local/bin/system-monitor
}

start_monitoring() {
    print_info "Starting system monitor..."
    create_monitoring_script
    
    # Stop any existing monitor
    if [ -f /var/run/system-monitor.pid ]; then
        sudo kill -9 $(cat /var/run/system-monitor.pid) 2>/dev/null || true
    fi
    
    # Start monitoring in background
    nohup /usr/local/bin/system-monitor > /dev/null 2>&1 &
    MONITOR_PID=$!
    echo $MONITOR_PID | sudo tee /var/run/system-monitor.pid > /dev/null
    
    print_info "System monitor started (PID: $MONITOR_PID)"
    print_info "Monitor logs: tail -f $MONITOR_LOG"
}

# ---------------------------
# Cleanup Old NVIDIA Packages
# ---------------------------
cleanup_nvidia_packages() {
    print_info "Cleaning up old or conflicting NVIDIA packages..."
    
    # Remove any existing nvidia-container packages to avoid conflicts
    sudo apt-get remove -yq nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1 2>/dev/null || true
    
    # Clean up any partial installations
    sudo apt-get autoremove -yq
    sudo apt-get autoclean -yq
}

# ---------------------------
# Install Everything
# ---------------------------
install_everything() {
    print_info "=== STEP 1: CLEANING REPOSITORIES ==="
    clean_microsoft_repos
    
    print_info "=== STEP 2: UPDATING SYSTEM ==="
    sudo apt-get update -yq
    sudo apt-get upgrade -yq
    
    print_info "=== STEP 3: CLEANING OLD PACKAGES ==="
    cleanup_nvidia_packages
    
    print_info "=== STEP 4: INSTALLING DOCKER ==="
    sudo apt-get install -yq docker.io docker-compose-v2
    sudo systemctl start docker
    sudo systemctl enable docker
    
    # Docker login
    docker_login
    
    print_info "=== STEP 5: CHECKING FOR NVIDIA GPU ==="
    if lspci | grep -i nvidia > /dev/null; then
        print_info "NVIDIA GPU detected. Installing drivers..."
        
        # Install NVIDIA drivers
        if install_nvidia_drivers; then
            # Install NVIDIA Container Toolkit
            install_nvidia_container_toolkit
            
            # Mark that reboot is needed
            REBOOT_NEEDED=true
        else
            print_warning "NVIDIA driver installation failed. Continuing without GPU support."
            REBOOT_NEEDED=false
        fi
    else
        print_warning "No NVIDIA GPU detected. Skipping NVIDIA driver installation."
        REBOOT_NEEDED=false
    fi
    
    # Start monitoring
    start_monitoring
    
    # Schedule reboot if needed
    if [ "$REBOOT_NEEDED" = true ]; then
        print_info "Scheduling reboot in 1 minute for NVIDIA drivers to take effect..."
        print_info "System will reboot in 1 minute. After reboot, the trainer will start automatically."
        
        # Create a script to run after reboot
        sudo tee /usr/local/bin/post-reboot.sh > /dev/null << 'EOF'
#!/bin/bash
sleep 30
/usr/local/bin/run-trainer
EOF
        sudo chmod +x /usr/local/bin/post-reboot.sh
        
        # Schedule reboot
        shutdown -r +1
        sleep 65
        exit 0
    fi
    
    print_info "✅ All installations completed successfully"
}

# ---------------------------
# Run Trainer Container
# ---------------------------
run_trainer() {
    print_info "=== STARTING TRAINER CONTAINER ==="
    
    # Docker login again (in case credentials were lost)
    docker_login
    
    # Pull the image
    print_info "Pulling image: $IMAGE"
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
    
    print_info "✅ Trainer container started!"
    
    # Show container status
    sleep 3
    print_info "Container status:"
    sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$CONTAINER_NAME" || true
}

# ---------------------------
# Post-Reboot Setup
# ---------------------------
post_reboot() {
    print_info "=== POST-REBOOT SETUP ==="
    
    # Wait for network and Docker
    print_info "Waiting for network and services..."
    sleep 30
    
    # Wait for Docker service
    until systemctl is-active --quiet docker; do
        print_info "Waiting for Docker service..."
        sleep 5
    done
    
    # Check if NVIDIA drivers are loaded
    if command -v nvidia-smi &> /dev/null && nvidia-smi > /dev/null 2>&1; then
        print_info "✅ NVIDIA drivers working after reboot!"
    else
        print_warning "NVIDIA drivers not working after reboot"
    fi
    
    # Start monitoring
    start_monitoring
    
    # Run trainer
    run_trainer
}

# ---------------------------
# Status Check
# ---------------------------
check_status() {
    echo "=== SYSTEM STATUS ==="
    echo "Time: $(date)"
    echo ""
    
    echo "=== DOCKER STATUS ==="
    sudo docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | grep -E "(ai-trainer|CONTAINER)"
    echo ""
    
    echo "=== GPU STATUS ==="
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi --query-gpu=name,driver_version,temperature.gpu,utilization.gpu,utilization.memory --format=csv
    else
        echo "NVIDIA drivers not loaded"
    fi
    echo ""
    
    echo "=== RESOURCE USAGE ==="
    echo "CPU: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}')"
    echo "Memory: $(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
    echo ""
    
    echo "=== MONITOR LOGS ==="
    tail -5 "$MONITOR_LOG" 2>/dev/null || echo "No monitor logs found"
}

# ---------------------------
# Main Execution
# ---------------------------
main() {
    print_info "Starting Azure Batch NVIDIA + Docker setup..."
    
    # Check for post-reboot flag
    if [ "$1" = "post-reboot" ]; then
        post_reboot
        exit 0
    fi
    
    # Check if already installed
    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        print_info "Docker already installed and running."
        
        # Check if NVIDIA is installed
        if [ ! -f "$FLAG_FILE" ]; then
            print_info "Fresh installation detected. Running full setup..."
            install_everything
        else
            print_info "System already configured. Starting trainer..."
        fi
        
        # Run trainer
        run_trainer
        
        # Start monitoring
        start_monitoring
        
        # Check status
        check_status
    else
        # Fresh installation
        install_everything
        
        # If no reboot was needed, run trainer immediately
        if [ "$REBOOT_NEEDED" = false ]; then
            run_trainer
        fi
    fi
    
    print_info "Setup complete!"
    print_info "Container logs: sudo docker logs -f $CONTAINER_NAME"
    print_info "Monitor logs: tail -f $MONITOR_LOG"
    print_info "Check status: sudo $0 status"
    
    # Keep script alive for Azure Batch
    print_info "Running in Azure Batch mode - script will remain active..."
    while true; do
        sleep 3600
    done
}

# ---------------------------
# Command Line Handler
# ---------------------------
case "${1:-}" in
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
    "status")
        check_status
        ;;
    "logs")
        sudo docker logs -f "$CONTAINER_NAME"
        ;;
    "stop")
        sudo docker stop "$CONTAINER_NAME"
        ;;
    "restart")
        sudo docker restart "$CONTAINER_NAME"
        ;;
    "fix-deps")
        # Special command to fix dependency issues
        print_info "Fixing NVIDIA Container Toolkit dependencies..."
        cleanup_nvidia_packages
        install_nvidia_container_toolkit
        ;;
    *)
        # Default: run main
        main "$@"
        ;;
esac
