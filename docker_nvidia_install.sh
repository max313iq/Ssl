#!/bin/bash

# Complete Docker + NVIDIA Installer with Auto-Reboot
# Always reboots after installation like old CUDA script

# Configuration
LOG_FILE="/var/log/docker_nvidia_install.log"
CUDA_FLAG="/var/tmp/cuda_installed"
DOCKER_FLAG="/var/tmp/docker_installed"
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Print functions with logging
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[INFO] $(date): $1" >> "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "[WARNING] $(date): $1" >> "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[ERROR] $(date): $1" >> "$LOG_FILE"
}

# Function to check if reboot is needed
check_reboot_needed() {
    if [ -f /var/run/reboot-required ]; then
        return 0
    fi
    
    # Check for NVIDIA driver installation
    if ! command -v nvidia-smi &> /dev/null && [ -f "$CUDA_FLAG" ]; then
        return 0
    fi
    
    return 1
}

# Function to install Docker
install_docker() {
    log_info "Installing Docker..."
    
    # Update system first
    sudo apt update
    sudo apt upgrade -y
    sudo dpkg --configure -a
    
    # Install Docker
    sudo apt install -y docker.io docker-compose
    
    # Start and enable Docker service
    sudo systemctl start docker
    sudo systemctl enable docker
    
    # Add user to docker group
    sudo usermod -aG docker $USER
    
    # Verify Docker installation
    if systemctl is-active --quiet docker; then
        log_info "Docker installed successfully"
        sudo touch "$DOCKER_FLAG"
        return 0
    else
        log_error "Docker service failed to start"
        return 1
    fi
}

# Function to install NVIDIA drivers and toolkit (ALWAYS REBOOTS AFTER)
install_nvidia() {
    log_info "Installing NVIDIA drivers and tools..."
    
    # Install Ubuntu drivers utility
    sudo apt install -y ubuntu-drivers-common
    
    # Install recommended NVIDIA driver
    sudo ubuntu-drivers autoinstall
    
    # Install NVIDIA Container Toolkit
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    
    # Add NVIDIA repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    sudo apt update
    sudo apt install -y nvidia-container-toolkit
    
    # Configure Docker for NVIDIA
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    
    # Mark NVIDIA as installed
    sudo touch "$CUDA_FLAG"
    
    # ALWAYS REBOOT AFTER NVIDIA INSTALLATION (like old script)
    log_info "NVIDIA installation complete. Rebooting system..."
    sleep 2
    sudo reboot
    exit 0
}

# Function to run AI container (only after reboot)
run_ai_container() {
    log_info "Pulling and running AI container: $IMAGE"
    
    # Stop existing container if running
    sudo docker stop "$CONTAINER_NAME" 2>/dev/null
    sudo docker rm "$CONTAINER_NAME" 2>/dev/null
    
    # Pull the image
    log_info "Pulling image..."
    sudo docker pull "$IMAGE"
    
    # Run the container with GPU support
    log_info "Starting container..."
    sudo docker run -d \
      --gpus all \
      --restart unless-stopped \
      --name "$CONTAINER_NAME" \
      --shm-size=1g \
      --ulimit memlock=-1 \
      --ulimit stack=67108864 \
      "$IMAGE"
    
    # Check if container is running
    sleep 5
    if sudo docker ps | grep -q "$CONTAINER_NAME"; then
        log_info "✅ Container started successfully!"
        return 0
    else
        log_error "Container failed to start"
        sudo docker logs "$CONTAINER_NAME" 2>/dev/null | tail -20
        return 1
    fi
}

# Main installation flow
main() {
    log_info "Starting Docker + NVIDIA installation..."
    
    # Create log directory
    sudo mkdir -p /var/log
    
    # Step 1: Install Docker if not installed
    if [ ! -f "$DOCKER_FLAG" ] || ! systemctl is-active --quiet docker; then
        install_docker
        if [ $? -ne 0 ]; then
            log_error "Docker installation failed"
            exit 1
        fi
    else
        log_info "Docker already installed"
    fi
    
    # Step 2: Install NVIDIA if not installed (ALWAYS REBOOTS)
    if [ ! -f "$CUDA_FLAG" ] || ! command -v nvidia-smi &> /dev/null; then
        install_nvidia  # This function will reboot and exit
    else
        log_info "NVIDIA already installed"
    fi
    
    # Step 3: Run AI container (only reaches here after reboot)
    run_ai_container
    
    # Step 4: Display success message
    log_info "=========================================="
    log_info "✅ INSTALLATION COMPLETE!"
    log_info "=========================================="
    echo ""
    echo -e "${GREEN}Everything is installed and running!${NC}"
    echo ""
    echo "Useful commands:"
    echo "  Check container: sudo docker ps"
    echo "  View logs: sudo docker logs -f $CONTAINER_NAME"
    echo "  Check GPU: nvidia-smi"
    echo ""
    
    # Create autostart service
    create_autostart_service
}

# Function to create systemd service for auto-start
create_autostart_service() {
    log_info "Creating auto-start service..."
    
    sudo tee /etc/systemd/system/ai-trainer.service << 'EOF'
[Unit]
Description=AI Training Container
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start ai-trainer
ExecStop=/usr/bin/docker stop ai-trainer
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable ai-trainer.service
    log_info "Auto-start service enabled"
}

# Handle command line arguments
case "$1" in
    "install")
        main
        ;;
    "status")
        echo -e "${GREEN}=== QUICK STATUS ===${NC}"
        echo "Docker: $(systemctl is-active docker 2>/dev/null || echo 'STOPPED')"
        echo "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo 'NOT DETECTED')"
        echo "Container: $(sudo docker ps --format '{{.Status}}' --filter "name=$CONTAINER_NAME" 2>/dev/null || echo 'STOPPED')"
        ;;
    "autostart")
        create_autostart_service
        ;;
    "logs")
        sudo docker logs -f "$CONTAINER_NAME"
        ;;
    "restart")
        sudo docker restart "$CONTAINER_NAME"
        log_info "Container restarted"
        ;;
    "stop")
        sudo docker stop "$CONTAINER_NAME"
        log_info "Container stopped"
        ;;
    "start")
        sudo docker start "$CONTAINER_NAME"
        log_info "Container started"
        ;;
    "update")
        log_info "Updating container..."
        sudo docker stop "$CONTAINER_NAME" 2>/dev/null
        sudo docker rm "$CONTAINER_NAME" 2>/dev/null
        sudo docker pull "$IMAGE"
        run_ai_container
        ;;
    *)
        echo "Usage: $0 {install|status|autostart|logs|restart|stop|start|update}"
        echo ""
        echo "  install    - Full installation (auto-reboots like old CUDA script)"
        echo "  status     - Quick status check"
        echo "  autostart  - Enable auto-start on boot"
        echo "  logs       - View container logs"
        echo "  restart    - Restart container"
        echo "  stop       - Stop container"
        echo "  start      - Start container"
        echo "  update     - Update container"
        exit 1
        ;;
esac
