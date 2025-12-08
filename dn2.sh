#!/bin/bash
# Complete Docker + NVIDIA + trainer Installation - NON-INTERACTIVE VERSION
# For Azure Batch account start task

set -e # Exit on any error

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"
MONITOR_LOG="/var/log/system-status.log"
LIVE_MONITOR_PID_FILE="/var/run/live-monitor.pid"

# Docker Hub Credentials (Placeholders - **MUST BE SET AS ENVIRONMENT VARIABLES IN AZURE BATCH START TASK**)
DOCKER_USER=${DOCKER_USERNAME:-}
DOCKER_PASS=${DOCKER_PASSWORD:-}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

print_header() { echo -e "\n${PURPLE}====================================================${NC}"; echo -e "${PURPLE}* $1 *${NC}"; echo -e "${PURPLE}====================================================${NC}\n"; }
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_status() { echo -e "${BLUE}[STATUS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ========== DOCKER HUB LOGIN FUNCTION ==========
docker_login() {
    print_header "DOCKER HUB AUTHENTICATION 🔒"
    if [ -z "$DOCKER_USER" ] || [ -z "$DOCKER_PASS" ]; then
        print_warning "DOCKER_USERNAME or DOCKER_PASSWORD environment variables are not set. Skipping Docker Hub login. Pull limits may apply."
        return 0
    fi

    print_status "Attempting to log in to Docker Hub as user: $DOCKER_USER"
    # Pipe password to docker login to make it non-interactive and avoid history storage
    if echo "$DOCKER_PASS" | sudo docker login -u "$DOCKER_USER" --password-stdin > /dev/null 2>&1; then
        print_info "✅ Docker Hub login successful."
        return 0
    else
        print_error "🚨 Docker Hub login failed. Check credentials."
        return 1
    fi
}


# ========== LIVE MONITORING FUNCTIONS (New) ==========
create_live_monitoring_script() {
    print_info "Creating live monitoring script..."
    
    sudo tee /usr/local/bin/live-system-monitor > /dev/null << 'EOF'
#!/bin/bash
while true; do
    # Clear screen for live view (optional, useful if script output is being tail'd)
    # tput reset
    
    # Header
    echo -e "\033[1;34m================= LIVE STATUS (\033[0m$(date)\033[1;34m) =================\033[0m"
    
    # CPU
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    echo -e "\033[0;32mCPU Usage:\033[0m ${CPU_USAGE}%"
    
    # GPU (if available)
    if command -v nvidia-smi &> /dev/null; then
        GPU_USAGE=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader | head -1 2>/dev/null || echo "N/A")
        GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | head -1 2>/dev/null || echo "N/A")
        echo -e "\033[0;35mGPU Usage:\033[0m ${GPU_USAGE} (\033[0;35mTemp:\033[0m ${GPU_TEMP}°C)"
    else
        echo "GPU: Not available"
    fi
    
    # Container status
    if docker ps --format 'table {{.Names}}' | grep -q ai-trainer; then
        echo -e "\033[0;36mContainer:\033[0m RUNNING"
        CONTAINER_STATS=$(docker stats ai-trainer --no-stream --format "\033[0;36mCPU:\033[0m {{.CPUPerc}} \033[0;36mMem:\033[0m {{.MemUsage}}" 2>/dev/null || echo "N/A")
        echo "Container Stats: ${CONTAINER_STATS}"
    else
        echo -e "\033[0;31mContainer:\033[0m STOPPED"
    fi
    echo -e "\033[1;34m====================================================\033[0m"
    
    # Monitor interval (e.g., every 5 seconds)
    sleep 5
done
EOF
    
    sudo chmod +x /usr/local/bin/live-system-monitor
}

start_live_monitoring() {
    print_info "Starting live system monitor (updates every 5 seconds)."
    
    # Create the monitoring script
    create_live_monitoring_script
    
    # Start monitoring in background, redirecting output to a named pipe or file for external access
    # For live viewing, we usually want it on the console or an accessible file
    nohup /usr/local/bin/live-system-monitor > /tmp/live-monitor-output.log 2>&1 &
    
    # Save PID for management
    MONITOR_PID=$!
    echo $MONITOR_PID | sudo tee "$LIVE_MONITOR_PID_FILE" > /dev/null
    
    print_info "Live Monitor started (PID: $MONITOR_PID). View with: \033[1mwatch -n 1 'tail -n 12 /tmp/live-monitor-output.log'\033[0m"
}

stop_live_monitoring() {
    if [ -f "$LIVE_MONITOR_PID_FILE" ]; then
        MONITOR_PID=$(cat "$LIVE_MONITOR_PID_FILE")
        if kill -0 "$MONITOR_PID" 2>/dev/null; then
            print_info "Stopping live monitor (PID: $MONITOR_PID)..."
            kill "$MONITOR_PID"
        fi
        sudo rm -f "$LIVE_MONITOR_PID_FILE"
    fi
}

# ========== BATCH-FRIENDLY 10-MINUTE MONITORING (Original) ==========
create_monitoring_script() {
    print_info "Creating 10-minute status monitoring script..."
    
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
    print_info "Starting 10-minute system monitor..."
    
    # Create the monitoring script
    create_monitoring_script
    
    # Start monitoring in background
    nohup /usr/local/bin/system-monitor >> "$MONITOR_LOG" 2>&1 &
    
    # Save PID for potential management
    MONITOR_PID=$!
    echo $MONITOR_PID | sudo tee /var/run/system-monitor.pid > /dev/null
    
    print_info "10-Minute Monitor started (PID: $MONITOR_PID). Check logs: \033[1mtail -f $MONITOR_LOG\033[0m"
}


# ========== NVIDIA DRIVER INSTALLATION (Preserved) ==========
install_nvidia_drivers() {
    print_header "NVIDIA DRIVER INSTALLATION 💾"
    # ... (Your existing install_nvidia_drivers function body remains unchanged) ...
    print_status "Using ubuntu-drivers to auto-install NVIDIA drivers..."

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
            print_status "Installing $RECOMMENDED..."
            sudo apt-get install -yq "$RECOMMENDED"
        else
            print_error "Could not determine NVIDIA driver to install"
            return 1
        fi
    fi

    # Verify installation
    if modinfo nvidia > /dev/null 2>&1; then
        print_info "✅ NVIDIA drivers installed successfully"
        return 0
    else
        print_error "🚨 NVIDIA driver installation may have failed"
        return 1
    fi
}

# ========== ALWAYS INSTALL EVERYTHING (Preserved & Enhanced Output) ==========
install_everything() {
    print_header "AZURE BATCH NODE INITIAL SETUP 🚀"
    
    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive
    
    print_status "Step 1/6: Updating package lists and upgrading system..."
    sudo apt-get update -yq
    sudo apt-get upgrade -yq

    print_status "Step 2/6: Installing Docker and Docker Compose V2..."
    sudo apt-get install -yq docker.io docker-compose-v2
    sudo systemctl start docker
    sudo systemctl enable docker
    print_info "✅ Docker installed and service enabled."

    # Check if NVIDIA GPU is present
    if lspci | grep -i nvidia > /dev/null; then
        print_status "Step 3/6: NVIDIA GPU detected. Proceeding with driver installation."
        sudo apt-get install -yq ubuntu-drivers-common
        
        # Install NVIDIA drivers
        if install_nvidia_drivers; then
            print_status "Step 4/6: Installing NVIDIA Container Toolkit..."
            # Add NVIDIA repository
            distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
            curl -s -L "https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list" | \
                sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
                sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
            
            sudo apt-get update -yq
            sudo apt-get install -yq nvidia-container-toolkit
            
            print_status "Step 5/6: Configuring Docker for NVIDIA and restarting service..."
            sudo nvidia-ctk runtime configure --runtime=docker
            sudo systemctl restart docker
            print_info "✅ NVIDIA Container Toolkit configured."
            
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
    start_live_monitoring
    
    # Schedule reboot if needed
    if [ "$REBOOT_NEEDED" = true ]; then
        print_header "REBOOT REQUIRED 🔁"
        print_info "Scheduling reboot in 1 minute for NVIDIA drivers to take effect..."
        # Use the absolute path for $0 as it might be sourced differently in 'at'
        echo "sudo /bin/bash $(readlink -f "$0") post-reboot" | sudo at now + 1 minute
        print_info "System will reboot in 1 minute. After reboot, the trainer will start automatically."
    else
        # If no reboot needed, proceed directly to running trainer
        print_status "Step 6/6: Installation complete. Starting trainer immediately."
        run_trainer
    fi
    exit 0
}

# ========== POST-REBOOT: RUN trainer ==========
post_reboot() {
    print_header "POST-REBOOT SETUP & STARTUP 🔄"
    
    # Wait for network and Docker
    print_status "Waiting for network and services (30s delay)..."
    sleep 30
    until systemctl is-active --quiet docker; do
        print_status "Waiting for Docker service..."
        sleep 5
    done
    
    # Re-start monitoring (in case it didn't survive reboot)
    if [ ! -f /var/run/system-monitor.pid ] || ! ps -p $(cat /var/run/system-monitor.pid) > /dev/null 2>&1; then
        start_monitoring
    fi
    if [ ! -f "$LIVE_MONITOR_PID_FILE" ] || ! ps -p $(cat "$LIVE_MONITOR_PID_FILE") > /dev/null 2>&1; then
        start_live_monitoring
    fi
    
    run_trainer
}

run_trainer() {
    print_header "STARTING TRAINER CONTAINER 🏗️"
    
    # Attempt Docker Hub Login
    docker_login

    print_status "Pulling image: $IMAGE"
    # Pull the image (login will help bypass limits)
    sudo docker pull "$IMAGE" || print_warning "Failed to pull image, using local if available"
    
    # Remove existing container if present
    print_status "Stopping and removing existing container (if any)..."
    sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
    sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Run container with appropriate GPU support
    if command -v nvidia-smi &> /dev/null && nvidia-smi > /dev/null 2>&1; then
        print_info "Starting with NVIDIA GPU support (--gpus all)..."
        sudo docker run -d \
            --gpus all \
            --restart unless-stopped \
            --name "$CONTAINER_NAME" \
            "$IMAGE"
    else
        print_info "Starting without GPU support (CPU mode)..."
        sudo docker run -d \
            --restart unless-stopped \
            --name "$CONTAINER_NAME" \
            "$IMAGE"
    fi
    
    print_info "✅ Trainer container started!"
    
    # Show status
    sleep 3
    print_status "Container status:"
    sudo docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
    
    # Show container logs for verification
    print_status "Container logs (last 10 lines for verification):"
    sudo docker logs --tail 10 "$CONTAINER_NAME"
}

# ========== CLEANUP FUNCTION ==========
cleanup() {
    print_info "Cleaning up monitor processes on exit..."
    # Stop 10-minute monitor if running
    if [ -f /var/run/system-monitor.pid ]; then
        MONITOR_PID=$(cat /var/run/system-monitor.pid)
        if kill -0 "$MONITOR_PID" 2>/dev/null; then
            kill "$MONITOR_PID"
        fi
        sudo rm -f /var/run/system-monitor.pid
    fi
    # Stop live monitor
    stop_live_monitoring
}

# Set trap for cleanup
trap cleanup EXIT

# ========== MAIN EXECUTION FOR AZURE BATCH ==========
# MARKED START TASK COMMAND ENTRY POINT
main() {
    print_header "AZURE BATCH START TASK EXECUTION ☁️"
    
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
        
        # Ensure monitoring is running
        start_monitoring
        start_live_monitoring
    else
        # Fresh installation
        install_everything
    fi
    
    # For Azure Batch, we want to keep the script running
    print_header "SETUP COMPLETE & MONITORING ACTIVE ✅"
    print_info "To view live metrics (CPU/GPU/Container): \033[1mwatch -n 1 'tail -n 12 /tmp/live-monitor-output.log'\033[0m"
    print_info "To view 10-minute status logs: \033[1mtail -f $MONITOR_LOG\033[0m"
    print_info "To view application logs: \033[1msudo docker logs -f $CONTAINER_NAME\033[0m"

    print_info "Running in Azure Batch mode - keeping script alive..."
    # Sleep indefinitely but allow signals
    while true; do
        sleep 3600
    done
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
            start_live_monitoring
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
