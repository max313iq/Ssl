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

# Start Docker service
sudo service docker start

# Run Docker container with GPU support
sudo docker run -d --gpus all -itd --restart=always --name aitaining riccorg/aitrainingdatacenter
