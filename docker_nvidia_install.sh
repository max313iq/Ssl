#!/bin/bash
# Complete Docker + NVIDIA + trainer Installation - PERFECT FINAL VERSION
# For Azure Batch account start task

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

# ========== NVIDIA DRIVER INSTALLATION ==========
install_nvidia_drivers() {
    print_info "Installing NVIDIA drivers..."
    
    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive
    echo "debconf debconf/frontend select noninteractive" | sudo debconf-set-selections
    
    # Install ubuntu-drivers if not present
    sudo apt-get install -yq ubuntu-drivers-common
    
    # Install recommended drivers
    print_info "Using ubuntu-drivers to auto-install NVIDIA drivers..."
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
            print_error "Could not determine NVIDIA driver to install"
            return 1
        fi
    fi
    
    # Try to load the NVIDIA module
    print_info "Attempting to load NVIDIA kernel module..."
    if sudo modprobe nvidia 2>/dev/null; then
        print_info "NVIDIA module loaded successfully"
        
        # Load other required NVIDIA modules
        sudo modprobe nvidia_uvm 2>/dev/null || true
        sudo modprobe nvidia_drm 2>/dev/null || true
        sudo modprobe nvidia_modeset 2>/dev/null || true
        
        # Test with nvidia-smi
        sleep 2
        if nvidia-smi > /dev/null 2>&1; then
            print_info "nvidia-smi is working"
            return 0
        fi
    fi
    
    print_info "NVIDIA drivers installed but require reboot to activate"
    return 2  # Special code for "needs reboot"
}

# ========== NVIDIA CONTAINER TOOLKIT INSTALLATION ==========
install_nvidia_container_toolkit() {
    print_info "Installing NVIDIA Container Toolkit..."
    
    # Get distribution info
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRIBUTION=$(echo $ID | tr '[:upper:]' '[:lower:]')
        VERSION=$VERSION_ID
    else
        DISTRIBUTION="ubuntu"
        VERSION="22.04"
    fi
    
    # Fix GPG tty issue
    export GNUPGHOME=/tmp/gnupg
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    
    # Download GPG key
    print_info "Downloading NVIDIA GPG key..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        sudo gpg --batch --no-tty --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null
    
    # Create correct repository URL
    print_info "Adding NVIDIA repository..."
    
    # Determine correct distribution string
    case "$VERSION" in
        "20.04") DIST_STRING="ubuntu20.04" ;;
        "22.04") DIST_STRING="ubuntu22.04" ;;
        "24.04") DIST_STRING="ubuntu24.04" ;;
        *) DIST_STRING="${DISTRIBUTION}${VERSION}" ;;
    esac
    
    ARCH=$(dpkg --print-architecture)
    
    # Create repository file
    cat > /tmp/nvidia-container-toolkit.list << EOF
deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/$DIST_STRING/$ARCH /
EOF
    
    sudo cp /tmp/nvidia-container-toolkit.list /etc/apt/sources.list.d/
    
    # Update and install
    sudo apt-get update -yq
    sudo apt-get install -yq nvidia-container-toolkit
    
    print_info "Configuring Docker for NVIDIA..."
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    
    print_info "NVIDIA Container Toolkit installed"
}

# ========== MAIN INSTALLATION FUNCTION ==========
install_everything() {
    print_info "=== STEP 1: INSTALLING DOCKER ==="
    
    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive
    
    sudo apt-get update -yq
    sudo apt-get upgrade -yq
    sudo apt-get install -yq docker.io
    sudo systemctl start docker
    sudo systemctl enable docker
    
    # Docker login
    docker_login
    
    # Check if NVIDIA GPU is present
    if lspci | grep -i nvidia > /dev/null; then
        print_info "=== STEP 2: INSTALLING NVIDIA DRIVERS ==="
        
        # Install NVIDIA drivers
        install_nvidia_drivers
        DRIVER_STATUS=$?
        
        if [ $DRIVER_STATUS -eq 0 ]; then
            print_info "NVIDIA drivers working without reboot"
            
            print_info "=== STEP 3: INSTALLING NVIDIA CONTAINER TOOLKIT ==="
            install_nvidia_container_toolkit
            
            REBOOT_NEEDED=false
            
        elif [ $DRIVER_STATUS -eq 2 ]; then
            print_info "NVIDIA drivers installed but need reboot"
            
            # Install NVIDIA container toolkit BEFORE reboot
            print_info "=== STEP 3: INSTALLING NVIDIA CONTAINER TOOLKIT ==="
            install_nvidia_container_toolkit
            
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
    
    # Start enhanced monitoring
    start_enhanced_monitoring
    
    # Schedule reboot if needed
    if [ "$REBOOT_NEEDED" = true ]; then
        print_info "Scheduling reboot for NVIDIA drivers..."
        
        print_info "System will reboot in 30 seconds..."
        shutdown -r +0.5
        
        # Keep alive until reboot
        sleep 40
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
    
    # Docker login again
    docker_login
    
    # Check if NVIDIA drivers are loaded
    if command -v nvidia-smi &> /dev/null && nvidia-smi > /dev/null 2>&1; then
        print_info "NVIDIA drivers working after reboot!"
    else
        print_warning "NVIDIA drivers not working after reboot"
    fi
    
    # Restart enhanced monitoring
    if [ ! -f /var/run/system-monitor.pid ] || ! ps -p $(cat /var/run/system-monitor.pid) > /dev/null 2>&1; then
        start_enhanced_monitoring
    fi
    
    run_trainer
}

# ========== RUN TRAINER CONTAINER ==========
run_trainer() {
    print_info "=== STARTING TRAINER CONTAINER ==="
    
    # Pull the image
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
}

# ========== CLEANUP FUNCTION (REMOVED TRAP) ==========
# We don't need cleanup for Azure Batch - it will handle node termination

# ========== MAIN EXECUTION FOR AZURE BATCH ==========
main() {
    print_info "Starting Azure Batch setup script..."
    
    # Check if we're in post-reboot phase
    if [ "$1" = "post-reboot" ]; then
        post_reboot
        exit 0
    fi
    
    # Check if already installed
    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        print_info "Docker already installed and running."
        
        # Docker login
        docker_login
        
        # Check if container is already running
        if sudo docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
            print_info "Container $CONTAINER_NAME is already running."
        else
            print_info "Starting trainer container..."
            run_trainer
        fi
        
        # Start enhanced monitoring
        start_enhanced_monitoring
    else
        # Fresh installation
        install_everything
    fi
    
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
        *)
            # Default: run main
            main "$@"
            ;;
    esac
fi
