#!/bin/bash
# Complete Docker + NVIDIA + trainer Installation - PERFECT FINAL VERSION
# For Azure Batch account start task


# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"
MONITOR_LOG="/var/log/system-status.log"

# Docker credentials - Set in Azure Batch environment variables
DOCKER_USERNAME="riccorg"
DOCKER_PASSWORD="UL3bJ_5dDcPF7s#"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_monitor() { echo -e "${CYAN}[MONITOR]${NC} $1"; }

# ========== ENHANCED MONITORING WITH REAL-TIME LOOP ==========
create_enhanced_monitoring_script() {
    print_info "Creating enhanced monitoring script..."
    
    sudo tee /usr/local/bin/enhanced-system-monitor > /dev/null << 'EOF'
#!/bin/bash

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

print_monitor() { echo -e "${CYAN}[MONITOR]${NC} $1"; }

while true; do
    # Clear screen and show header
    clear
    echo -e "${BLUE}===============================================${NC}"
    echo -e "${GREEN}     REAL-TIME SYSTEM MONITOR - $(date)${NC}"
    echo -e "${BLUE}===============================================${NC}"
    echo ""
    
    # CPU Usage with percentage
    echo -e "${YELLOW}CPU USAGE:${NC}"
    CPU_PERCENT=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    CPU_BAR=$(printf "%-20s" "$(printf '#%.0s' $(seq 1 $((CPU_PERCENT / 5))))")
    echo "  Usage: ${CPU_PERCENT}%"
    echo "  [${CPU_BAR// /-}]"
    echo ""
    
    # Memory Usage
    echo -e "${GREEN}MEMORY USAGE:${NC}"
    MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    MEM_USED=$(free -m | awk '/^Mem:/{print $3}')
    MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    MEM_BAR=$(printf "%-20s" "$(printf '#%.0s' $(seq 1 $((MEM_PERCENT / 5))))")
    echo "  Used: ${MEM_USED}MB / ${MEM_TOTAL}MB (${MEM_PERCENT}%)"
    echo "  [${MEM_BAR// /-}]"
    echo ""
    
    # GPU Status (if available)
    echo -e "${PURPLE}GPU STATUS:${NC}"
    if command -v nvidia-smi &> /dev/null; then
        # Get GPU info
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "Unknown")
        GPU_UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
        GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 || echo "N/A")
        GPU_MEM=$(nvidia-smi --query-gpu=utilization.memory --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
        
        echo "  Model: ${GPU_NAME}"
        echo "  Utilization: ${GPU_UTIL}%"
        echo "  Memory: ${GPU_MEM}%"
        echo "  Temperature: ${GPU_TEMP}°C"
        
        # GPU bar
        GPU_BAR=$(printf "%-20s" "$(printf '#%.0s' $(seq 1 $((GPU_UTIL / 5))))")
        echo "  [${GPU_BAR// /-}]"
    else
        echo "  No GPU detected or NVIDIA drivers not loaded"
    fi
    echo ""
    
    # Container Status
    echo -e "${CYAN}CONTAINER STATUS:${NC}"
    if docker ps --format 'table {{.Names}}' | grep -q ai-trainer; then
        CONTAINER_INFO=$(docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep ai-trainer)
        CONTAINER_STATS=$(docker stats ai-trainer --no-stream --format "{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null || echo "N/A\tN/A")
        CPU_CONTAINER=$(echo "$CONTAINER_STATS" | cut -f1)
        MEM_CONTAINER=$(echo "$CONTAINER_STATS" | cut -f2)
        
        echo -e "  ${GREEN}✓ RUNNING${NC}"
        echo "  Status: $(echo "$CONTAINER_INFO" | awk '{print $2}')"
        echo "  CPU: ${CPU_CONTAINER}"
        echo "  Memory: ${MEM_CONTAINER}"
        echo "  Ports: $(echo "$CONTAINER_INFO" | awk '{print $3}')"
        
        # Container uptime
        CONTAINER_ID=$(docker ps -q --filter "name=ai-trainer")
        if [ -n "$CONTAINER_ID" ]; then
            STARTED_AT=$(docker inspect --format='{{.State.StartedAt}}' "$CONTAINER_ID" 2>/dev/null)
            if [ -n "$STARTED_AT" ]; then
                UPTIME=$(date -d "@$(( $(date +%s) - $(date -d "$STARTED_AT" +%s) ))" -u +'%-Hh %-Mm %-Ss')
                echo "  Uptime: ${UPTIME}"
            fi
        fi
    else
        echo -e "  ${RED}✗ STOPPED${NC}"
    fi
    echo ""
    
    # System Load
    echo -e "${YELLOW}SYSTEM LOAD:${NC}"
    LOAD_AVG=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
    echo "  Load Average: ${LOAD_AVG}"
    echo ""
    
    echo -e "${BLUE}===============================================${NC}"
    echo -e "${CYAN}Refreshing in 5 seconds... (Press Ctrl+C to exit)${NC}"
    echo -e "${BLUE}===============================================${NC}"
    
    # Wait 5 seconds before next update
    sleep 5
done
EOF
    
    sudo chmod +x /usr/local/bin/enhanced-system-monitor
}

start_enhanced_monitoring() {
    print_info "Starting enhanced system monitor..."
    create_enhanced_monitoring_script
    
    # Start monitoring in background
    nohup /usr/local/bin/enhanced-system-monitor >> "$MONITOR_LOG" 2>&1 &
    MONITOR_PID=$!
    echo $MONITOR_PID | sudo tee /var/run/system-monitor.pid > /dev/null
    
    print_info "Enhanced monitor started (PID: $MONITOR_PID)"
    print_info "To view live monitoring: sudo /usr/local/bin/enhanced-system-monitor"
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
            print_info "✅ Docker login successful!"
            
            # Verify login
            if sudo docker info 2>/dev/null | grep -q "Username:"; then
                print_info "✅ Docker login verified!"
                return 0
            else
                print_warning "⚠️ Docker login may not have worked"
                return 1
            fi
        else
            print_warning "Docker login failed. Continuing without authenticated pull..."
            return 1
        fi
    else
        print_warning "No Docker credentials provided. You may hit pull rate limits."
        print_warning "Set DOCKER_USERNAME and DOCKER_PASSWORD environment variables to avoid this."
        return 1
    fi
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
    
    # Verify installation by trying to load the module
    if sudo modprobe nvidia 2>/dev/null; then
        print_info "✅ NVIDIA drivers installed and loaded successfully"
        
        # Load other required NVIDIA modules
        sudo modprobe nvidia_uvm 2>/dev/null || true
        sudo modprobe nvidia_drm 2>/dev/null || true
        sudo modprobe nvidia_modeset 2>/dev/null || true
        
        # Test with nvidia-smi
        sleep 2
        if nvidia-smi > /dev/null 2>&1; then
            print_info "✅ nvidia-smi is working"
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
    
    # Download GPG key without tty issues
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
    
    print_info "✅ NVIDIA Container Toolkit installed"
}

# ========== MAIN INSTALLATION FUNCTION ==========
install_everything() {
    print_info "=== STEP 1: INSTALLING DOCKER ==="
    
    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive
    
    sudo apt-get update -yq
    sudo apt-get upgrade -yq
    sudo apt-get install -yq docker.io docker-compose-v2
    sudo systemctl start docker
    sudo systemctl enable docker
    
    # Docker login
    docker_login
    
    # Check if NVIDIA GPU is present
    if lspci | grep -i nvidia > /dev/null; then
        print_info "=== STEP 2: INSTALLING NVIDIA DRIVERS ==="
        sudo apt-get install -yq ubuntu-drivers-common
        
        # Install NVIDIA drivers
        DRIVER_RESULT=$(install_nvidia_drivers)
        DRIVER_STATUS=$?
        
        if [ $DRIVER_STATUS -eq 0 ]; then
            print_info "✅ NVIDIA drivers working without reboot"
            
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
    
    print_info "✅ All tools installed."
    
    # Start enhanced monitoring
    start_enhanced_monitoring
    
    # Schedule reboot if needed
    if [ "$REBOOT_NEEDED" = true ]; then
        print_info "Scheduling reboot for NVIDIA drivers..."
        
        # Create post-reboot script
        cat > /tmp/post-reboot-script.sh << 'EOF'
#!/bin/bash
sleep 30
curl -s https://raw.githubusercontent.com/max313iq/Ssl/refs/heads/main/docker_nvidia_install.sh | sudo bash -s post-reboot
EOF
        chmod +x /tmp/post-reboot-script.sh
        
        print_info "System will reboot in 30 seconds..."
        shutdown -r +0.5 "Azure Batch NVIDIA driver reboot"
        
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
        print_info "✅ NVIDIA drivers working after reboot!"
        nvidia-smi --query-gpu=name,utilization.gpu --format=csv
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
    
    print_info "✅ Trainer container started!"
    
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
    print_info "System logs: tail -f $MONITOR_LOG"
    print_info "Live monitoring: sudo /usr/local/bin/enhanced-system-monitor"
    
    # Keep script alive for Azure Batch
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
            start_enhanced_monitoring
            ;;
        "live-monitor")
            create_enhanced_monitoring_script
            /usr/local/bin/enhanced-system-monitor
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
