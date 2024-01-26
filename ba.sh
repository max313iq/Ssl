#!/bin/bash

# Function to update the environment variable and restart Docker container
update_and_restart() {
    new_pool_url=$(curl -s https://raw.githubusercontent.com/max313iq/Ssl/main/ip)
    if [ "$new_pool_url" != "$POOL_URL" ]; then
        echo "Updating POOL_URL to: $new_pool_url"
        export POOL_URL=$new_pool_url
        container_id=$(sudo docker ps -q --filter ancestor=ubtssl/webappx:latest)
        if [ -n "$container_id" ]; then
            sudo docker stop "$container_id"
        fi
        sudo docker run -d -e POOL_URL="$POOL_URL" ubtssl/webappx:latest
    else
        echo "No updates found."
    fi
}

# Function to check if Docker is installed
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo "Docker is not installed. Please install Docker and run the script again."
        exit 1
    fi
}

# Function to install Docker
install_docker() {
    sudo apt-get update --fix-missing
    sudo apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update --fix-missing
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
}

# Function to run Docker container with initial POOL_URL
start_docker_container() {
    export POOL_URL=$(curl -s https://raw.githubusercontent.com/max313iq/Ssl/main/ip)
    sudo docker run -d -e POOL_URL="$POOL_URL" ubtssl/webappx:latest
}

# Check if Docker is installed
check_docker || install_docker

# Run Docker container with initial POOL_URL
start_docker_container

# Allow some time for the container to start before entering the update loop
sleep 30

# Continuous loop to check for updates
while true; do
    sleep 360  # Check every hour (adjust as needed)
    update_and_restart
done
