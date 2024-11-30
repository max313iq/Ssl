#!/bin/bash

# Set DEBIAN_FRONTEND to noninteractive to avoid debconf prompts
export DEBIAN_FRONTEND=noninteractive

# Update the package repository
sudo apt-get update --fix-missing

# Install dependencies for adding repositories
sudo apt-get install -y \
    build-essential \
    dkms \
    curl \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release

# Add NVIDIA's package repository for Ubuntu 22.04
sudo apt-key del 7fa2af80 2>/dev/null || true # Remove any old keys
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cuda-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] http://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/ /" | sudo tee /etc/apt/sources.list.d/cuda.list

# Update the package list
sudo apt-get update --fix-missing

# Install CUDA
sudo apt-get install -y cuda || { echo "CUDA installation failed"; exit 1; }

# Verify CUDA installation
if ! command -v nvcc &> /dev/null; then
    echo "CUDA installation unsuccessful or not in PATH."
    exit 1
fi

# Install Docker
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update --fix-missing
sudo apt-get install -y
