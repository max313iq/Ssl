#!/bin/bash

# Set DEBIAN_FRONTEND to noninteractive to avoid debconf prompts
export DEBIAN_FRONTEND=noninteractive

# Update package list and install dependencies
sudo apt-get update --fix-missing
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common \
    gnupg2 # Ensure gnupg2 is installed for key handling

# Remove any conflicting Docker-related packages (like moby-tini)
echo "Removing conflicting Docker-related packages..."
sudo apt-get remove --purge -y moby-tini docker-ce docker-ce-cli containerd.io
sudo apt-get autoremove --purge -y
sudo apt-get clean

# Add Docker GPG key (with no-tty flag to avoid errors in non-interactive environment)
echo "Adding Docker GPG key..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --no-tty --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Add Docker repository to APT sources
echo "Adding Docker repository to sources..."
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package list after adding Docker repository
echo "Updating package list..."
sudo apt-get update --fix-missing

# Install Docker from the official repository
echo "Installing Docker..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Ensure Docker service is running (if not found, try installing again)
echo "Starting Docker service..."
sudo systemctl start docker || { echo "Docker service failed to start"; exit 1; }
sudo systemctl enable docker || { echo "Failed to enable Docker on boot"; exit 1; }

# Add the current user to the Docker group to avoid needing sudo for Docker commands
echo "Adding current user to Docker group..."
sudo usermod -aG docker $USER

# Restart the session to apply user group changes (or manually log out and back in)
newgrp docker

# Start Docker container with NVIDIA GPU support (if applicable)
echo "Starting Docker container..."
sudo docker run -d --gpus all -itd --restart=always --name aitaining riccorg/aitrainingdatacenter

# Sleep for a short while to allow Docker container to start
sleep 10

# Infinite loop with 3-hour intervals for logging
echo "Starting the logging loop..."
while true; do
    sleep 10800  # Sleep for 3 hours (10800 seconds)
    echo "3 hours done"
done
