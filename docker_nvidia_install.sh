#!/bin/bash
# Complete Docker + NVIDIA + trainer Installation - NON-INTERACTIVE VERSION

set -e # Exit on any error

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ========== ALWAYS INSTALL EVERYTHING (NON-INTERACTIVE) ==========
install_everything() {
    print_info "=== STEP 1: INSTALLING DOCKER ==="
    
    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    
    sudo apt update -yq
    sudo apt upgrade -yq
    sudo apt install -yq docker.io docker-compose
    sudo systemctl start docker
    sudo systemctl enable docker
    
    print_info "=== STEP 2: INSTALLING NVIDIA DRIVERS ==="
    sudo apt install -yq ubuntu-drivers-common
    sudo DEBIAN_FRONTEND=noninteractive ubuntu-drivers autoinstall -y
    
    print_info "=== STEP 3: INSTALLING NVIDIA CONTAINER TOOLKIT ==="
    # Add NVIDIA repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --batch --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    
    sudo apt update -yq
    sudo apt install -yq nvidia-container-toolkit
    
    print_info "=== STEP 4: CONFIGURING DOCKER FOR NVIDIA ==="
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    
    print_info "✅ All tools installed. Rebooting system..."
    echo "reboot" | sudo at now + 1 minute
    exit 0
}

# ========== POST-REBOOT: RUN trainer ==========
run_trainer() {
    print_info "=== POST-REBOOT: STARTING trainer ==="
    
    # Wait for Docker
    until systemctl is-active --quiet docker; do
        sleep 5
    done
    
    sudo docker pull "$IMAGE"
    sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
    sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    sudo docker run -d \
      --gpus all \
      --restart unless-stopped \
      --name "$CONTAINER_NAME" \
      "$IMAGE"
    
    print_info "✅ trainer container started!"
    
    # Show status
    sleep 2
    sudo docker ps
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
    *)
        echo "Usage: $0 {install|start|logs}"
        exit 1
        ;;
esac
