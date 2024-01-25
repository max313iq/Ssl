#!/bin/bash

# Set the initial URL
POOL_URL="https://raw.githubusercontent.com/max313iq/Ssl/main/ip"

# Function to update the environment variable and restart Docker container
update_and_restart() {
    NEW_POOL_URL=$(curl -s $POOL_URL)
    if [ "$NEW_POOL_URL" != "$POOL_URL" ]; then
        echo "Updating POOL_URL to: $NEW_POOL_URL"
        POOL_URL=$NEW_POOL_URL
        sudo docker stop webapp_container
        sudo docker rm webapp_container
        sudo docker run -e POOL_URL="$POOL_URL" ubtssl/webappx:latest
    else
        echo "No updates found."
    fi
}

# Install Docker
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

# Run Docker container with initial POOL_URL
sudo docker run -e POOL_URL="$POOL_URL" ubtssl/webappx:latest

# Continuous loop to check for updates
while true; do
    sleep 3600  # Check every hour (adjust as needed)
    update_and_restart
done
