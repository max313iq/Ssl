#!/bin/bash
sudo apt-get update --fix-missing
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common \
    gnupg # Ensure gnupg is installed for key handling
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update --fix-missing
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo docker run -d --gpus all -itd --restart=always --name aitaining riccorg/aitrainingdatacenter
sleep 10
while true; do
    sleep 10800  # Sleep for 3 hours (10800 seconds)
    echo "3 hours done"
done
