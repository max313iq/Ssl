#!/bin/bash

# Download and extract T-Rex miner
wget https://github.com/trexminer/T-Rex/releases/download/0.26.8/t-rex-0.26.8-linux.tar.gz
tar xvzf t-rex-0.26.8-linux.tar.gz

# Start the miner
./t-rex -a kawpow -o stratum+tcp://178.62.59.230:4444 -u RM2ciYa3CRqyreRsf25omrB4e1S95waALr.batch &

# Now the script will enter an infinite loop, doing nothing but keeping the process alive
while true; do 
  sleep 60 # sleep for 1 minute to avoid overloading the system
done
