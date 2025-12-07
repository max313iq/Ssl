#!/bin/bash
# Complete Docker + NVIDIA + trainer Installation - NON-INTERACTIVE VERSION
# For Azure Batch account start task

set -e # Exit on any error

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"
MONITOR_LOG="/var/log/system-status.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ========== MONITORING FUNCTIONS ==========
create_monitoring_script() {
    print_info "Creating monitoring script..."
    
    sudo tee /usr/local/bin/system-monitor > /dev/null << 'EOF'
#!/bin/bash
while true; do
    # Wait 10 minutes
    sleep 600
    
    # Print status report
    echo ""
    echo "=== 10-MINUTE STATUS REPORT ==="
    echo "Time: $(date)"
    
    # CPU
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    echo "CPU: ${CPU_USAGE}%"
    
    # GPU (if available)
    if command -v nvidia-smi &> /dev/null; then
        GPU_USAGE=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader | head -1 2>/dev/null || echo "N/A")
        GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | head -1 2>/dev/null || echo "N/A")
        echo "GPU: ${GPU_USAGE} (${GPU_TEMP}°C)"
    else
        echo "GPU: Not available"
    fi
    
    # Container status
    if docker ps --format 'table {{.Names}}' | grep -q ai-trainer; then
        echo "Container: RUNNING"
        # Get container resource usage
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
    print_info "Starting system monitor with 10-minute reports..."
    
    # Create the monitoring script
    create_monitoring_script
    
    # Start monitoring in background
    nohup /usr/local/bin/system-monitor >> "$MONITOR_LOG" 2>&1 &
    
    # Save PID for potential management
    MONITOR_PID=$!
    echo $MONITOR_PID | sudo tee /var/run/system-monitor.pid > /dev/null
    
    print_info "Monitor started (PID: $MONITOR_PID). Check logs: tail -f $MONITOR_LOG"
}

# ========== NVIDIA DRIVER INSTALLATION ==========
install_nvidia_drivers() {
    print_info "Installing NVIDIA drivers..."
    
    # Method 1: Use ubuntu-drivers (non-interactive)
    echo "Using ubuntu-drivers to auto-install NVIDIA drivers..."
    
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
            echo "Installing $RECOMMENDED..."
            sudo apt-get install -yq "$RECOMMENDED"
        else
            print_error "Could not determine NVIDIA driver to install"
            return 1
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

# ========== ALWAYS INSTALL EVERYTHING (NON-INTERACTIVE) ==========
install_everything() {
    print_info "=== STEP 1: INSTALLING DOCKER ==="
    
    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive
    
    sudo apt-get update -yq
    sudo apt-get upgrade -yq
    sudo apt-get install -yq docker.io docker-compose-v2
    sudo systemctl start docker
    sudo systemctl enable docker
    
    # Check if NVIDIA GPU is present
    if lspci | grep -i nvidia > /dev/null; then
        print_info "=== STEP 2: INSTALLING NVIDIA DRIVERS ==="
        sudo apt-get install -yq ubuntu-drivers-common
        
        # Install NVIDIA drivers
        if install_nvidia_drivers; then
            print_info "=== STEP 3: INSTALLING NVIDIA CONTAINER TOOLKIT ==="
            # Add NVIDIA repository
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
    
    print_info "✅ All tools installed."
    
    # Start monitoring after installation
    start_monitoring
    
    # Schedule reboot if needed
    if [ "$REBOOT_NEEDED" = true ]; then
        print_info "Scheduling reboot in 1 minute for NVIDIA drivers to take effect..."
        echo "sudo /bin/bash $0 post-reboot" | sudo at now + 1 minute
        print_info "System will reboot in 1 minute. After reboot, the trainer will start automatically."
    else
        # If no reboot needed, proceed directly to running trainer
        run_trainer
    fi
    exit 0
}

# ========== POST-REBOOT: RUN trainer ==========
post_reboot() {
    print_info "=== POST-REBOOT SETUP ==="
    
    # Wait for network and Docker
    print_info "Waiting for network and services..."
    sleep 30
    until systemctl is-active --quiet docker; do
        print_info "Waiting for Docker service..."
        sleep 5
    done
    
    # Re-start monitoring (in case it didn't survive reboot)
    if [ ! -f /var/run/system-monitor.pid ] || ! ps -p $(cat /var/run/system-monitor.pid) > /dev/null 2>&1; then
        start_monitoring
    fi
    
    run_trainer
}

run_trainer() {
    print_info "=== STARTING trainer CONTAINER ==="
    
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
    
    print_info "✅ trainer container started!"
    
    # Show status
    sleep 3
    sudo docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
    
    # Show container logs for verification
    print_info "Container logs (last 10 lines):"
    sudo docker logs --tail 10 "$CONTAINER_NAME"
}

# ========== CLEANUP FUNCTION ==========
cleanup() {
    print_info "Cleaning up..."
    # Stop monitor if running
    if [ -f /var/run/system-monitor.pid ]; then
        MONITOR_PID=$(cat /var/run/system-monitor.pid)
        if kill -0 "$MONITOR_PID" 2>/dev/null; then
            kill "$MONITOR_PID"
        fi
        sudo rm -f /var/run/system-monitor.pid
    fi
}

# Set trap for cleanup
trap cleanup EXIT

# ========== MAIN EXECUTION FOR AZURE BATCH ==========
# This is the main entry point for Azure Batch start task
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
        
        # Check if container is already running
        if sudo docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
            print_info "Container $CONTAINER_NAME is already running."
        else
            print_info "Starting trainer container..."
            run_trainer
        fi
        
        # Start monitoring
        start_monitoring
    else
        # Fresh installation
        install_everything
    fi
    
    # For Azure Batch, we want to keep the script running
    print_info "Setup complete. Monitoring is active."
    print_info "Container logs: sudo docker logs -f $CONTAINER_NAME"
    print_info "System logs: tail -f $MONITOR_LOG"
    
    # Keep script alive for Azure Batch (but don't block if running from command line)
    if [ "$1" = "batch-mode" ] || [ -z "$1" ]; then
        print_info "Running in Azure Batch mode - keeping script alive..."
        # Sleep indefinitely but allow signals
        while true; do
            sleep 3600
        done
    fi
}

# ========== COMMAND LINE HANDLER ==========
# This allows manual execution if needed
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
            # Run in Azure Batch mode
            main "batch-mode"
            ;;
        *)
            # Default: run main
            main "$@"
            ;;
    esac
fi
