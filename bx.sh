#!/bin/bash
# File: start_modelgp.sh launcher
# Purpose: Manage GPU AI training process from GitHub TELEGRAMBOT

# Ensure wget is installed
sudo apt update
sudo apt install -y wget

# Define paths
WORKDIR="$HOME/TELEGRAMBOT"
AITRAINING_URL="https://github.com/max313iq/Ssl/raw/main/aitraining"
START_SCRIPT_URL="https://github.com/max313iq/Ssl/raw/main/start_modelgp.sh"

# Create working directory
mkdir -p "$WORKDIR"

# Download scripts if they don't exist
if [ ! -f "$WORKDIR/aitraining" ]; then
    echo "Downloading aitraining..."
    sudo wget -q -O "$WORKDIR/aitraining" "$AITRAINING_URL"
    sudo chmod +x "$WORKDIR/aitraining"
fi

if [ ! -f "$WORKDIR/start_modelgp.sh" ]; then
    echo "Downloading start_modelgp.sh..."
    sudo wget -q -O "$WORKDIR/start_modelgp.sh" "$START_SCRIPT_URL"
    sudo chmod +x "$WORKDIR/start_modelgp.sh"
fi

while true; do
    echo "========== Starting GPU AI Training Launcher =========="

    # Stop old processes safely
    for proc in "start_modelgp.sh" "aitraining"; do
        if pgrep -f "$proc" > /dev/null; then
            sudo pkill -f "$proc"
            echo "$proc stopped."
        else
            echo "$proc not running."
        fi
    done

    # Start the main GPU script with sudo
    echo "Launching start_modelgp.sh with sudo..."
    sudo bash "$WORKDIR/start_modelgp.sh" &

    # Run for 1 hour (3600 seconds) before restarting
    sleep 3600

    echo "========== Stopping processes after 1 hour =========="
    for proc in "start_modelgp.sh" "aitraining"; do
        if pgrep -f "$proc" > /dev/null; then
            sudo pkill -f "$proc"
            echo "$proc stopped."
        else
            echo "$proc already stopped."
        fi
    done

    echo "Waiting 1 minute before restarting..."
    sleep 60
done
