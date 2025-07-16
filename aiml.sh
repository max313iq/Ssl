#!/bin/bash

# CUDA installation state file
CUDA_FLAG="/var/tmp/cuda_installed"
DOCKER_FLAG="/var/tmp/docker_installed" # New flag for Docker installation

# Log file for script output
LOG_FILE="/var/log/mining_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1 # Redirect stdout and stderr to log file and console

echo "Starting mining setup script at $(date)"

# --- 1. Install CUDA if not already installed ---
if [ ! -f "$CUDA_FLAG" ]; then
    echo "Starting CUDA installation..."

    # Update system and install NVIDIA driver
    echo "Updating system and installing ubuntu-drivers-common..."
    sudo apt update
    sudo apt install -y ubuntu-drivers-common

    echo "Installing recommended NVIDIA driver..."
    sudo ubuntu-drivers install # This installs the recommended driver

    # Check if a driver was installed and prompt for reboot if needed
    echo "Checking NVIDIA driver status..."
    if ! command -v nvidia-smi &> /dev/null; then
        echo "NVIDIA driver not found or not loaded. A reboot might be required."
        echo "Please reboot your system and run this script again."
        sudo reboot
        exit 0
    else
        echo "NVIDIA driver detected. Proceeding with CUDA Toolkit installation."
    fi

    # Install CUDA Toolkit 11.8 for Ubuntu 24.04 (Noble Numbat)
    echo "Adding CUDA repository key and installing CUDA Toolkit 11.8..."
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring_1.1-1_all.deb
    sudo dpkg -i /tmp/cuda-keyring_1.1-1_all.deb
    rm /tmp/cuda-keyring_1.1-1_all.deb # Clean up
    sudo apt update
    sudo apt -y install cuda-toolkit-11-8

    # Optional: Add CUDA to PATH and LD_LIBRARY_PATH (for current session/user)
    # For a system-wide persistent setup, these are typically handled by the toolkit installer or /etc/profile.d
    # export PATH=/usr/local/cuda-11.8/bin${PATH:+:${PATH}}
    # export LD_LIBRARY_PATH=/usr/local/cuda-11.8/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}

    # Mark installation complete
    sudo touch "$CUDA_FLAG"

    echo "CUDA installation complete. A system reboot is highly recommended."
    echo "The script will resume Docker and mining setup after reboot."
    sudo reboot
    exit 0 # Exit after initiating reboot
fi

# --- 2. Install Docker if not already installed ---
install_docker() {
    echo "Installing Docker..."
    # Ensure lsb_release is installed for docker repo setup
    sudo apt-get update && sudo apt-get install -y lsb-release

    sudo apt-get update
    sudo apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        software-properties-common

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io

    # Add current user to docker group to run docker commands without sudo
    echo "Adding current user ($USER) to docker group..."
    sudo usermod -aG docker "$USER"
    echo "You might need to log out and log back in for docker group changes to take effect."
    echo "Docker installation complete."
    sudo touch "$DOCKER_FLAG"
}

if [ ! -f "$DOCKER_FLAG" ]; then
    if ! command -v docker &> /dev/null; then
        echo "Docker is not installed. Installing Docker..."
        install_docker
    else
        echo "Docker is already installed."
        sudo touch "$DOCKER_FLAG" # Mark as installed if already present
    fi
else
    echo "Docker was previously installed (flag found)."
    # If docker command is missing despite flag, reinstall
    if ! command -v docker &> /dev/null; then
        echo "Docker command not found, reinstalling Docker..."
        rm "$DOCKER_FLAG" # Remove flag to force reinstall
        install_docker
    fi
fi

# Ensure docker service is running
echo "Ensuring Docker service is running..."
sudo systemctl start docker || echo "Failed to start Docker service. Please check systemctl status docker."
sudo systemctl enable docker || echo "Failed to enable Docker service. Please check systemctl status docker."

# --- 3. Validate GPU and Docker Setup ---
echo "Validating GPU and Docker setup..."
if command -v nvidia-smi &> /dev/null; then
    echo "nvidia-smi output:"
    nvidia-smi
else
    echo "Warning: nvidia-smi command not found. GPU driver may not be installed or configured correctly."
    echo "Please ensure NVIDIA drivers are properly installed and rebooted."
    # Potentially exit here if GPU is mandatory
    # exit 1
fi

# Test Docker with GPU
echo "Testing Docker GPU access..."
if docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi &> /dev/null; then
    echo "Docker can access GPUs successfully."
else
    echo "Error: Docker cannot access GPUs. Please check NVIDIA driver, Docker, and NVIDIA Container Toolkit installation."
    echo "Ensure that the NVIDIA Container Toolkit is installed: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
    exit 1 # Exit if GPU access fails
fi


# --- 4. Mining Pool Management and Container Lifecycle ---

# Initialize POOL_URL. Try to read from an existing container if possible, or set a default/placeholder.
# This makes the first comparison in update_and_restart more robust.
POOL_URL="" # Initialize with an empty string
CONTAINER_NAME="rvn-test"
IMAGE_NAME="riccorg/imagegenv4:latest"
POOL_SOURCE_URL="https://raw.githubusercontent.com/anhacvai11/bash/refs/heads/main/ip"

# Attempt to get the initial POOL_URL from the Docker image's expected environment,
# or set a dummy value to ensure the first update_and_restart runs the container.
# NOTE: This assumes the Docker image has a default POOL_URL or it's implicitly used.
# If the Docker image truly needs POOL_URL as an env var, you might need to set it here initially.
# For simplicity, we'll let update_and_restart handle the first actual fetch.

# Function to update mining pool and restart container if pool changes
update_and_restart() {
    echo "Checking for new mining pool URL from $POOL_SOURCE_URL..."
    local new_pool_url=$(curl -s "$POOL_SOURCE_URL")
    local current_container_running=$(docker ps -q -f name="$CONTAINER_NAME") # Check if container is running

    if [ -z "$new_pool_url" ]; then
        echo "Warning: Failed to fetch new pool URL from $POOL_SOURCE_URL. Keeping current pool if any, or skipping update."
        return # Exit function if we can't get a new URL
    fi

    # Only set POOL_URL if it's the first time or if it actually changed
    if [ "$new_pool_url" != "$POOL_URL" ]; then
        echo "Pool URL change detected: '$POOL_URL' -> '$new_pool_url'"
        export POOL_URL="$new_pool_url" # Update global POOL_URL for future comparisons

        echo "Stopping and removing old container: $CONTAINER_NAME..."
        docker stop "$CONTAINER_NAME" 2>/dev/null || true # '|| true' to prevent script from exiting if stop fails
        docker rm "$CONTAINER_NAME" 2>/dev/null || true

        echo "Running new container with updated POOL_URL: $new_pool_url"
        # Pass POOL_URL as an environment variable to the Docker container
        docker run --gpus all -d --restart unless-stopped \
                   --name "$CONTAINER_NAME" \
                   -e POOL_URL="$POOL_URL" \
                   "$IMAGE_NAME"

        if [ $? -eq 0 ]; then
            echo "Container $CONTAINER_NAME started successfully."
        else
            echo "Error: Failed to start container $CONTAINER_NAME. Check Docker logs."
            docker logs "$CONTAINER_NAME" 2>/dev/null
        fi
    else
        if [ -z "$current_container_running" ]; then
            echo "Pool URL has not changed, but container '$CONTAINER_NAME' is not running. Starting it."
            # Initial run or if container died unexpectedly but pool hasn't changed
            docker run --gpus all -d --restart unless-stopped \
                       --name "$CONTAINER_NAME" \
                       -e POOL_URL="$POOL_URL" \
                       "$IMAGE_NAME"
            if [ $? -eq 0 ]; then
                echo "Container $CONTAINER_NAME started successfully."
            else
                echo "Error: Failed to start container $CONTAINER_NAME. Check Docker logs."
                docker logs "$CONTAINER_NAME" 2>/dev/null
            fi
        else
            echo "No updates found and container '$CONTAINER_NAME' is already running."
        fi
    fi
}

# Initial cleanup and run (handles first run or restart after reboot)
echo "Performing initial container setup..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

# Call update_and_restart immediately to ensure the container starts with the latest pool
# This will fetch the initial POOL_URL and start the container
update_and_restart

# Wait a moment before entering the loop to ensure container has time to start
echo "Waiting 10 seconds before entering continuous check loop..."
sleep 10

# Continuous loop for checking and updating mining pool
echo "Entering continuous mining pool check loop (every 20 minutes)..."
while true; do
    sleep 1200 # Check every 20 minutes (1200 seconds)
    update_and_restart
done

echo "Script finished (this line should ideally not be reached in the loop)."
