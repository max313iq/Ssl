#!/bin/bash
set -e

# ---------------------------
# Configuration
# ---------------------------
FLAG_FILE="/var/tmp/nvidia_ready"
export DEBIAN_FRONTEND=noninteractive

echo "=== Azure Batch NVIDIA + Docker GPU Setup ==="

# ---------------------------
# REMOVE problematic Microsoft repos (if not needed)
# ---------------------------
echo "Cleaning up problematic repository files..."
sudo rm -f /etc/apt/sources.list.d/amlfs.list /etc/apt/sources.list.d/slurm.list 2>/dev/null || true

# Also remove any backup files
sudo rm -f /etc/apt/sources.list.d/amlfs.list.backup /etc/apt/sources.list.d/slurm.list.backup 2>/dev/null || true

# ---------------------------
# Update & install essentials
# ---------------------------
echo "Updating system packages..."
sudo apt-get update -y
sudo apt-get install -y -q curl ca-certificates gnupg lsb-release software-properties-common

# ---------------------------
# Install NVIDIA Driver
# ---------------------------
if [ ! -f "$FLAG_FILE" ]; then
    echo "Installing latest NVIDIA driver..."
    
    # Add NVIDIA driver PPA
    sudo add-apt-repository -y ppa:graphics-drivers/ppa
    
    # Update and install driver
    sudo apt-get update -y
    sudo apt-get install -y -q nvidia-driver-535  # Or use 545, 550, 555 etc.
    # OR for auto-selection:
    # sudo ubuntu-drivers autoinstall
    
    echo "✅ NVIDIA driver installed"
    
    # ---------------------------
    # Install Docker (if not present)
    # ---------------------------
    if ! command -v docker &> /dev/null; then
        echo "Installing Docker..."
        # Remove old Docker versions
        sudo apt-get remove -y docker docker-engine docker.io containerd runc
        
        # Add Docker's official GPG key
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        
        # Add Docker repository
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo apt-get update -y
        sudo apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi
    
    # ---------------------------
    # Install NVIDIA Container Toolkit
    # ---------------------------
    echo "Installing NVIDIA Container Toolkit..."
    
    # Add NVIDIA Container Toolkit repository
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    
    # Add NVIDIA GPG key
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    # Create repository file
    curl -fsSL https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    sudo apt-get update -y
    sudo apt-get install -y -q nvidia-container-toolkit
    
    # Configure Docker to use NVIDIA runtime
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker

    # Mark installation complete
    sudo touch "$FLAG_FILE"

    echo "✅ NVIDIA driver + container toolkit installed"
    echo "⚠️ Reboot is REQUIRED to activate drivers"
    
    # Display reboot instructions
    echo "=============================================="
    echo "Please reboot the system:"
    echo "  sudo reboot"
    echo "Then verify with: nvidia-smi"
    echo "=============================================="
    
    exit 0
fi

# ---------------------------
# Verify GPU (after reboot)
# ---------------------------
echo "=== GPU Check ==="
if command -v nvidia-smi &> /dev/null; then
    if nvidia-smi; then
        echo "✅ GPU is visible and working"
    else
        echo "❌ nvidia-smi failed to run"
        exit 1
    fi
else
    echo "❌ nvidia-smi not found"
    exit 1
fi

# ---------------------------
# Test Docker GPU access
# ---------------------------
echo "=== Testing Docker GPU access ==="
sudo docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi

# ---------------------------
# Run application container
# ---------------------------
echo "=== Starting GPU container ==="
sudo docker run --rm --gpus all riccorg/ml-compute-platform:latest
