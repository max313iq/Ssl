#!/bin/bash


echo "=== Docker + NVIDIA Quick Installer ==="

# Download and run the main script
curl -sSL https://raw.githubusercontent.com/max313iq/Ssl/refs/heads/main/docker_nvidia_install.sh -o install.sh
chmod +x install.sh

# Run installation
sudo ./install.sh install

# Enable auto-start
sudo ./install.sh autostart

echo "Installation complete!"
echo "Check status: ./install.sh status"
echo "View logs: ./install.sh logs"
