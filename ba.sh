#!/bin/bash

# Install necessary dependencies
sudo apt-get update --fix-missing
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common

# Add Docker GPG key and repository
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker with apt
sudo apt-get update --fix-missing
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Install Podman
sudo apt-get install -y podman

# Run the Docker image with Podman
sudo podman run ubtssl/webappx:latest
