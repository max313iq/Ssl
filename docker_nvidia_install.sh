#!/bin/bash
# Complete Docker + NVIDIA + trainer Installation
# ALWAYS installs everything, no checks needed

set -e # Exit on any error

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"
MONITOR_INTERVAL=30 # Seconds between container status checks

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ========== ALWAYS INSTALL EVERYTHING ==========
install_everything() {
    print_info "=== STEP 1: INSTALLING DOCKER ==="
    sudo apt update
    sudo apt upgrade -y
    sudo apt install -y docker.io docker-compose
    sudo systemctl start docker
    sudo systemctl enable docker
    # Add user to docker group (requires re-login to take effect)
    sudo usermod -aG docker $USER
    
    print_info "=== STEP 2: INSTALLING NVIDIA DRIVERS ==="
    sudo apt install -y ubuntu-drivers-common
    sudo ubuntu-drivers autoinstall
    
    print_info "=== STEP 3: INSTALLING NVIDIA CONTAINER TOOLKIT ==="
    # Add NVIDIA repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    sudo apt update
    sudo apt install -y nvidia-container-toolkit
    
    print_info "=== STEP 4: CONFIGURING DOCKER FOR NVIDIA ==="
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    
    print_info "✅ All tools installed. Rebooting system..."
    print_warning "NOTE: After reboot, run: $0 start"
    sudo reboot
    exit 0
}

# ========== POST-REBOOT: RUN trainer ==========
run_trainer() {
    print_info "=== POST-REBOOT: STARTING trainer ==="
    
    # Always pull latest image
    sudo docker pull "$IMAGE"
    
    # Always stop and remove old container
    sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
    sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Always run fresh container
    sudo docker run -d \
      --gpus all \
      --restart unless-stopped \
      --name "$CONTAINER_NAME" \
      "$IMAGE"
    
    print_info "✅ trainer container started! Use '$0 logs' to view output."
    
    # Show status
    sleep 2
    echo ""
    print_info "=== SYSTEM STATUS ==="
    nvidia-smi 2>/dev/null || print_warning "nvidia-smi not found. Check driver install."
    echo ""
    sudo docker ps
}

# ========== NEW FUNCTION: MONITOR CONTAINER STATE ==========
monitor_trainer() {
    print_info "=== MONITORING CONTAINER: $CONTAINER_NAME (Check every ${MONITOR_INTERVAL}s) ==="
    
    # Ensure the docker service is running before starting the loop
    if ! sudo systemctl is-active --quiet docker; then
        print_error "Docker service is not running. Attempting to start it..."
        sudo systemctl start docker || { print_error "Failed to start Docker. Exiting monitor."; exit 1; }
    fi

    while true; do
        # Check if the container is running by filtering for name and running status
        if ! sudo docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" --format "{{.Names}}" | grep -q "$CONTAINER_NAME"; then
            print_warning "Container $CONTAINER_NAME is NOT running! Status check failed. Attempting restart..."
            
            # Attempt to restart the container
            if sudo docker restart "$CONTAINER_NAME"; then
                print_info "Restart command issued successfully."
            else
                print_error "Failed to restart container $CONTAINER_NAME."
            fi
            
            # Give it a moment to start before the next check
            sleep 5
        else
            print_info "Container $CONTAINER_NAME is running normally. Next check in ${MONITOR_INTERVAL} seconds."
        fi
        
        # Wait for the defined interval before checking again
        sleep $MONITOR_INTERVAL
    done
}


# ========== COMMAND LINE ==========
case "$1" in
    "install")
        install_everything
        ;;
    "start")
        run_trainer
        ;;
    "logs")
        sudo docker logs -f "$CONTAINER_NAME"
        ;;
    "restart")
        sudo docker restart "$CONTAINER_NAME"
        print_info "Container restarted"
        ;;
    "stop")
        sudo docker stop "$CONTAINER_NAME"
        print_info "Container stopped"
        ;;
    "update")
        sudo docker pull "$IMAGE"
        sudo docker restart "$CONTAINER_NAME"
        print_info "Container updated"
        ;;
    "status")
        nvidia-smi 2>/dev/null || print_warning "nvidia-smi not found. Check driver install."
        sudo docker ps -a
        ;;
    "monitor")
        monitor_trainer
        ;;
    *)
        echo "Usage: $0 {install|start|logs|restart|stop|update|status|monitor}"
        echo ""
        echo "  install   - Install everything (Docker, NVIDIA) and reboot."
        echo "  start     - Start the trainer container (run after reboot)."
        echo "  logs      - View container logs in real-time."
        echo "  restart   - Restart the running container."
        echo "  stop      - Stop the running container."
        echo "  update    - Pull the latest image and restart the container."
        echo "  status    - Check GPU and container status (running/stopped)."
        echo "  monitor   - **Loop Function**: Continuously check container status and auto-restart if stopped."
        exit 1
        ;;
esac
