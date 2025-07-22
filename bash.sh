#!/bin/bash

IMAGE_TAR_URL="http://45.61.151.35/imagegenv5.tar"
IMAGE_TAR_LOCAL="/tmp/imagegenv5.tar"
IMAGE_NAME="riccorg/imagegenv5:latest"
POOL_URL=""
MAX_RETRIES=5
RETRY_DELAY=5  # بالثواني بين المحاولات

retry_download_and_load() {
    local retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        echo "Attempt $(($retries + 1)) to download Docker image..."

        curl -fsSL "$IMAGE_TAR_URL" -o "$IMAGE_TAR_LOCAL"
        if [ $? -eq 0 ]; then
            echo "Download succeeded. Loading into Docker..."
            docker load -i "$IMAGE_TAR_LOCAL"
            if [ $? -eq 0 ]; then
                echo "Docker image loaded successfully."
                return 0
            else
                echo "Docker load failed."
            fi
        else
            echo "Download failed."
        fi

        retries=$(($retries + 1))
        echo "Retrying in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
    done

    echo "Failed to download and load Docker image after $MAX_RETRIES attempts."
    exit 1
}

update_and_restart() {
    new_pool_url=$(curl -s https://raw.githubusercontent.com/anhacvai11/bash/refs/heads/main/ip)
    if [ "$new_pool_url" != "$POOL_URL" ]; then
        echo "Updating POOL_URL to: $new_pool_url"
        POOL_URL=$new_pool_url

        docker stop rvn-test 2>/dev/null
        docker rm rvn-test 2>/dev/null

        retry_download_and_load

        docker run --gpus all -d --restart unless-stopped --name rvn-test "$IMAGE_NAME"
    else
        echo "No updates found."
    fi
}

install_docker() {
    sudo apt-get update --fix-missing
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update --fix-missing
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        echo "Docker not installed. Installing..."
        install_docker
    else
        echo "Docker already installed."
    fi
}

# تحقق من Docker
check_docker

# تحقق من وجود GPU
echo "Checking GPU..."
if ! command -v nvidia-smi &> /dev/null; then
    echo "GPU not available or NVIDIA drivers not installed!"
    exit 1
fi

# تحميل وتشغيل الصورة مع إعادة المحاولة
retry_download_and_load

docker stop rvn-test 2>/dev/null
docker rm rvn-test 2>/dev/null

docker run --gpus all -d --restart unless-stopped --name rvn-test "$IMAGE_NAME"

sleep 10

while true; do
    sleep 3600  # كل 20 دقيقة
    update_and_restart
done
