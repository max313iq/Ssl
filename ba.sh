#!/bin/bash

# Set DEBIAN_FRONTEND to noninteractive to avoid debconf prompts
export DEBIAN_FRONTEND=noninteractive
#!/bin/bash

# Install Docker
sudo apt-get update --fix-missing
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update --fix-missing
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Run Docker container without setting environment variables
sudo docker run -d --gpus all -itd --restart=always --name aitaining riccorg/aitrainingdatacenter

# End of script
