#!/bin/bash
set -e

# ---------------------------
# Configuration
# ---------------------------
FLAG_FILE="/var/tmp/nvidia_ready"
export DEBIAN_FRONTEND=noninteractive

echo "=== Azure Batch NVIDIA + Docker GPU Setup ==="

# ---------------------------
# Fix Microsoft repo GPG keys
# ---------------------------
echo "Fixing missing Microsoft GPG keys..."
sudo mkdir -p /etc/apt/keyrings
curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null

# Update repo lists to use the signed key
for f in /etc/apt/sources.list.d/*.list; do
    sudo sed -i 's|https://packages.microsoft.com/repos/amlfs-jammy|deb [signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/amlfs-jammy|g' "$f" || true
    sudo sed -i 's|https://packages.microsoft.com/repos/slurm-ubuntu-jammy|deb [signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/slurm-ubuntu-jammy|g' "$f" || true
done

# ---------------------------
# Update & install essentials
# ---------------------------
echo "Updating system packages..."
sudo apt-get update -y
sudo apt-get install -y -q curl ca-certificates gnupg lsb-release unzip alsa-utils ubuntu-drivers-common

# ---------------------------
# Install NVIDIA Driver + Container Toolkit
# ---------------------------
if [ ! -f "$FLAG_FILE" ]; then
    echo "Installing latest NVIDIA driver..."
    sudo ubuntu-drivers autoinstall

    echo "Installing NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    sudo apt-get update -y
    sudo apt-get install -y -q nvidia-container-toolkit

    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker

    # Mark installation complete
    sudo touch "$FLAG_FILE"

    echo "✅ NVIDIA driver + container toolkit installed"
    echo "⚠️ Reboot is REQUIRED to activate drivers"

    # Optional: auto-reboot if running in Azure Batch (comment out if manual reboot preferred)
    # sudo reboot
    exit 0
fi

# ---------------------------
# Verify GPU
# ---------------------------
echo "=== GPU Check ==="
if ! nvidia-smi; then
    echo "❌ GPU not visible"
    exit 1
fi

# ---------------------------
# Run Docker container loop
# ---------------------------
echo "=== Starting GPU container loop ==="
while true; do
    echo "Starting training container..."
    docker run --rm --gpus all riccorg/ml-compute-platform:latest
    echo "Container exited. Sleeping 60s..."
    sleep 60
done
