#!/bin/bash
set -e

FLAG_FILE="/var/tmp/nvidia_ready"

echo "=== NVIDIA + Docker GPU setup ==="

# Make apt-get non-interactive
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y -q curl ca-certificates gnupg lsb-release unzip

# 1️⃣ Install NVIDIA Driver (latest recommended)
if [ ! -f "$FLAG_FILE" ]; then
    echo "Installing latest NVIDIA driver..."

    sudo apt-get install -y -q ubuntu-drivers-common
    sudo ubuntu-drivers autoinstall

    # 2️⃣ Install NVIDIA Container Toolkit
    echo "Installing NVIDIA Container Toolkit..."

    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    sudo apt-get update -y
    sudo apt-get install -y -q nvidia-container-toolkit

    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker

    sudo touch "$FLAG_FILE"

    echo "✅ NVIDIA driver + container toolkit installed"
    echo "⚠️ Reboot is REQUIRED once"
    echo "Please reboot manually and re-run the script"
    exit 0
fi

# 3️⃣ Verify GPU
echo "=== GPU Check ==="
nvidia-smi || {
    echo "❌ GPU not visible"
    exit 1
}

# 4️⃣ Run container (CORRECT WAY)
while true; do
    echo "Starting training container..."

    sudo docker run --rm --gpus all riccorg/ml-compute-platform:latest

    echo "Container exited. Sleeping 60s..."
    sleep 60
done
