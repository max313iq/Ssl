#!/bin/bash

# Set DEBIAN_FRONTEND to teletype to avoid debconf prompts
export DEBIAN_FRONTEND=teletype

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


# Install Docker
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update --fix-missing
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Start Docker service
sudo service docker start

# Run Docker container with GPU support
sudo docker run -d --gpus all -itd --restart=always --name aitaining riccorg/aitrainingdatacenter
