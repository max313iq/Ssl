#!/bin/bash
# Complete Docker + NVIDIA + trainer Installation - PERFECT FINAL VERSION
# For Azure Batch account start task

set -e # Exit on any error

# Configuration - UPDATED FOR PRIVATE REGISTRY
REGISTRY_HOST="144.172.116.82:5000"
REGISTRY_IMAGE="${REGISTRY_HOST}/ml-compute-platform:latest"
CONTAINER_NAME="ai-trainer"
MONITOR_LOG="/var/log/system-status.log"

# Registry credentials
REGISTRY_USERNAME="admin"
REGISTRY_PASSWORD="password123"

# Colors (DISABLED for Azure Batch)
print_info() { echo "[INFO] $1"; }
print_warning() { echo "[WARNING] $1"; }
print_error() { echo "[ERROR] $1"; }
print_monitor() { echo "[MONITOR] $1"; }

# ========== ENHANCED MONITORING WITH REAL-TIME LOOP ==========
create_enhanced_monitoring_script() {
    print_info "Creating enhanced monitoring script..."
    
    sudo tee /usr/local/bin/enhanced-system-monitor > /dev/null << 'EOF'
#!/bin/bash
# Simple monitor without colors for Azure Batch
LOG_FILE="/var/log/system-monitor.log"

while true; do
    echo "=== SYSTEM STATUS: $(date) ===" >> "$LOG_FILE"
    
    # CPU Usage
    CPU_PERCENT=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    echo "CPU: ${CPU_PERCENT}%" >> "$LOG_FILE"
    
    # Memory Usage
    MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    MEM_USED=$(free -m | awk '/^Mem:/{print $3}')
    MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    echo "Memory: ${MEM_USED}MB/${MEM_TOTAL}MB (${MEM_PERCENT}%)" >> "$LOG_FILE"
    
    # GPU Status (if available)
    if command -v nvidia-smi &> /dev/null; then
        GPU_UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
        GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 || echo "N/A")
        GPU_MEM=$(nvidia-smi --query-gpu=utilization.memory --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
        
        echo "GPU Utilization: ${GPU_UTIL}%" >> "$LOG_FILE"
        echo "GPU Memory: ${GPU_MEM}%" >> "$LOG_FILE"
        echo "GPU Temperature: ${GPU_TEMP}°C" >> "$LOG_FILE"
    else
        echo "GPU: Not available" >> "$LOG_FILE"
    fi
    
    # Container Status
    if docker ps --format 'table {{.Names}}' | grep -q ai-trainer; then
        CONTAINER_STATS=$(docker stats ai-trainer --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" 2>/dev/null || echo "N/A N/A")
        echo "Container: RUNNING - ${CONTAINER_STATS}" >> "$LOG_FILE"
    else
        echo "Container: STOPPED" >> "$LOG_FILE"
    fi
    
    echo "---" >> "$LOG_FILE"
    
    # Wait 30 seconds
    sleep 30
done
EOF
    
    sudo chmod +x /usr/local/bin/enhanced-system-monitor
}

start_enhanced_monitoring() {
    print_info "Starting enhanced system monitor..."
    create_enhanced_monitoring_script
    
    # Start monitoring in background
    nohup /usr/local/bin/enhanced-system-monitor > /dev/null 2>&1 &
    MONITOR_PID=$!
    echo $MONITOR_PID | sudo tee /var/run/system-monitor.pid > /dev/null
    
    print_info "Enhanced monitor started (PID: $MONITOR_PID)"
    print_info "Monitor logs: tail -f /var/log/system-monitor.log"
}

# ========== DOWNLOAD REGISTRY CERTIFICATE ==========
download_registry_cert() {
    print_info "Downloading registry certificate..."
    
    # Try multiple methods to get the certificate
    CERT_DOWNLOADED=false
    
    # Method 1: Download via HTTP
    if wget -q --timeout=10 "http://144.172.116.82:8000/registry.crt" -O /tmp/registry.crt; then
        print_info "Certificate downloaded via HTTP"
        CERT_DOWNLOADED=true
    fi
    
    # Method 2: If HTTP fails, try direct copy from local if available
    if [ "$CERT_DOWNLOADED" = false ] && [ -f "/tmp/registry.crt" ]; then
        print_info "Using existing certificate in /tmp"
        CERT_DOWNLOADED=true
    fi
    
    # Method 3: If no certificate available, create a placeholder
    if [ "$CERT_DOWNLOADED" = false ]; then
        print_warning "Could not download certificate. Creating insecure registry config..."
        
        # Configure Docker to allow insecure registry
        sudo mkdir -p /etc/docker
        sudo tee /etc/docker/daemon.json > /dev/null << EOF
{
  "insecure-registries": ["144.172.116.82:5000"]
}
EOF
        
        sudo systemctl restart docker
        print_info "Configured insecure registry access"
        return 0
    fi
    
    # Configure Docker to trust the registry
    print_info "Configuring Docker to trust private registry..."
    
    sudo mkdir -p /etc/docker/certs.d/${REGISTRY_HOST}
    sudo cp /tmp/registry.crt /etc/docker/certs.d/${REGISTRY_HOST}/ca.crt
    sudo systemctl restart docker
    
    # Test the certificate
    if openssl x509 -in /tmp/registry.crt -text -noout &> /dev/null; then
        print_info "Registry certificate configured successfully"
        return 0
    else
        print_error "Invalid certificate file"
        return 1
    fi
}

# ========== DOCKER LOGIN FUNCTION (UPDATED FOR PRIVATE REGISTRY) ==========
docker_login() {
    print_info "Attempting Docker login to private registry..."
    
    # First download and configure certificate
    download_registry_cert
    
    # Login to private registry
    if [[ -n "$REGISTRY_USERNAME" && -n "$REGISTRY_PASSWORD" ]]; then
        print_info "Logging in to registry at ${REGISTRY_HOST}..."
        
        if echo "$REGISTRY_PASSWORD" | sudo docker login ${REGISTRY_HOST} \
            --username "$REGISTRY_USERNAME" \
            --password-stdin > /dev/null 2>&1; then
            print_info "Private registry login successful!"
            return 0
        else
            print_warning "Private registry login failed. Trying without authentication..."
            
            # Try without auth (if registry allows anonymous pull)
            if sudo docker pull ${REGISTRY_IMAGE} --quiet > /dev/null 2>&1; then
                print_info "Can pull without authentication"
                return 0
            else
                print_error "Cannot access private registry"
                return 1
            fi
        fi
    else
        print_error "No registry credentials provided"
        return 1
    fi
}

# ========== NVIDIA DRIVER INSTALLATION (WORKING VERSION) ==========
install_nvidia_drivers() {
    print_info "Installing NVIDIA drivers..."
    
    # Method 1: Use ubuntu-drivers (non-interactive)
    echo "Using ubuntu-drivers to auto-install NVIDIA drivers..."
    
    # For non-interactive installation, we need to use debconf preseed
    echo "debconf debconf/frontend select noninteractive" | sudo debconf-set-selections
    
    # Install recommended drivers
    sudo ubuntu-drivers autoinstall
    
    # Alternative method if autoinstall doesn't work
    if [ $? -ne 0 ]; then
        print_warning "ubuntu-drivers autoinstall failed, trying manual method..."
        
        # Get recommended driver
        RECOMMENDED=$(ubuntu-drivers list | grep -o "nvidia-driver-[0-9]\+" | head -1)
        
        if [ -n "$RECOMMENDED" ]; then
            echo "Installing $RECOMMENDED..."
            sudo apt-get install -yq "$RECOMMENDED"
        else
            print_error "Could not determine NVIDIA driver to install"
            return 1
        fi
    fi
    
    # Verify installation
    if modinfo nvidia > /dev/null 2>&1; then
        print_info "NVIDIA drivers installed successfully"
        return 0
    else
        print_error "NVIDIA driver installation may have failed"
        return 1
    fi
}

# ========== ALWAYS INSTALL EVERYTHING (NON-INTERACTIVE) ==========
install_everything() {
    print_info "=== STEP 1: INSTALLING DOCKER ==="
    
    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive
    
    sudo apt-get update -yq
    sudo apt-get upgrade -yq
    sudo apt-get install -yq docker.io docker-compose-v2 wget
    sudo systemctl start docker
    sudo systemctl enable docker
    
    # Configure private registry access
    docker_login
    
    # Check if NVIDIA GPU is present
    if lspci | grep -i nvidia > /dev/null; then
        print_info "=== STEP 2: INSTALLING NVIDIA DRIVERS ==="
        sudo apt-get install -yq ubuntu-drivers-common
        
        # Install NVIDIA drivers
        if install_nvidia_drivers; then
            print_info "=== STEP 3: INSTALLING NVIDIA CONTAINER TOOLKIT ==="
            # Add NVIDIA repository
            distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
            curl -s -L "https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list" | \
                sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
                sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
            
            sudo apt-get update -yq
            sudo apt-get install -yq nvidia-container-toolkit
            
            print_info "=== STEP 4: CONFIGURING DOCKER FOR NVIDIA ==="
            sudo nvidia-ctk runtime configure --runtime=docker
            sudo systemctl restart docker
            
            REBOOT_NEEDED=true
        else
            print_warning "NVIDIA driver installation failed. Continuing without GPU support."
            REBOOT_NEEDED=false
        fi
    else
        print_warning "No NVIDIA GPU detected. Skipping NVIDIA driver installation."
        REBOOT_NEEDED=false
    fi
    
    print_info "✅ All tools installed."
    
    # Start enhanced monitoring
    start_enhanced_monitoring
    
    # Schedule reboot if needed
    if [ "$REBOOT_NEEDED" = true ]; then
        print_info "Scheduling reboot in 1 minute for NVIDIA drivers to take effect..."
        # For Azure Batch, we'll use shutdown instead of at
        print_info "System will reboot in 1 minute. After reboot, the trainer will start automatically."
        shutdown -r +1
        
        # Keep the script alive briefly to show messages
        sleep 65
        exit 0
    else
        # If no reboot needed, proceed directly to running trainer
        run_trainer
    fi
}

# ========== POST-REBOOT: RUN trainer ==========
post_reboot() {
    print_info "=== POST-REBOOT SETUP ==="
    
    # Wait for network and Docker
    print_info "Waiting for network and services..."
    sleep 30
    until systemctl is-active --quiet docker; do
        print_info "Waiting for Docker service..."
        sleep 5
    done
    
    # Re-configure private registry access after reboot
    docker_login
    
    # Check if NVIDIA drivers are loaded
    if command -v nvidia-smi &> /dev/null && nvidia-smi > /dev/null 2>&1; then
        print_info "NVIDIA drivers working after reboot!"
    else
        print_warning "NVIDIA drivers not working after reboot"
    fi
    
    # Re-start enhanced monitoring (in case it didn't survive reboot)
    if [ ! -f /var/run/system-monitor.pid ] || ! ps -p $(cat /var/run/system-monitor.pid) > /dev/null 2>&1; then
        start_enhanced_monitoring
    fi
    
    run_trainer
}

# ========== RUN TRAINER CONTAINER FROM PRIVATE REGISTRY ==========
run_trainer() {
    print_info "=== STARTING TRAINER CONTAINER FROM PRIVATE REGISTRY ==="
    
    # Pull the image from private registry
    print_info "Pulling image from ${REGISTRY_IMAGE}..."
    if sudo docker pull "${REGISTRY_IMAGE}"; then
        print_info "Image pulled successfully from private registry"
    else
        print_error "Failed to pull image from private registry"
        print_info "Trying to use local image if available..."
    fi
    
    # Remove existing container if present
    sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
    sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Run container with appropriate GPU support
    if command -v nvidia-smi &> /dev/null && nvidia-smi > /dev/null 2>&1; then
        print_info "Starting with NVIDIA GPU support..."
        sudo docker run -d \
          --gpus all \
          --restart unless-stopped \
          --name "$CONTAINER_NAME" \
          -p 8080:8080 \
          -p 8888:8888 \
          -p 6006:6006 \
          "${REGISTRY_IMAGE}"
    else
        print_info "Starting without GPU support..."
        sudo docker run -d \
          --restart unless-stopped \
          --name "$CONTAINER_NAME" \
          -p 8080:8080 \
          -p 8888:8888 \
          -p 6006:6006 \
          "${REGISTRY_IMAGE}"
    fi
    
    print_info "Trainer container started from private registry!"
    
    # Show status
    sleep 3
    print_info "Container status:"
    sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | grep "$CONTAINER_NAME"
    
    # Show exposed ports
    print_info "Container ports:"
    sudo docker port "$CONTAINER_NAME"
}

# ========== MAIN EXECUTION FOR AZURE BATCH ==========
main() {
    print_info "Starting Azure Batch setup script..."
    print_info "Using private registry: ${REGISTRY_HOST}"
    
    # Check if we're in post-reboot phase
    if [ "$1" = "post-reboot" ]; then
        post_reboot
        exit 0
    fi
    
    # Check if already installed
    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        print_info "Docker already installed and running."
        
        # Configure private registry access
        docker_login
        
        # Check if container is already running
        if sudo docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
            print_info "Container $CONTAINER_NAME is already running."
            print_info "Container image: $(sudo docker inspect --format='{{.Config.Image}}' $CONTAINER_NAME)"
        else
            print_info "Starting trainer container from private registry..."
            run_trainer
        fi
        
        # Start enhanced monitoring
        start_enhanced_monitoring
    else
        # Fresh installation
        install_everything
    fi
    
    print_info "Setup complete. Enhanced monitoring is active."
    print_info "Container logs: sudo docker logs -f $CONTAINER_NAME"
    print_info "Monitor logs: tail -f /var/log/system-monitor.log"
    
    # Display access URLs
    PUBLIC_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
    print_info "=== ACCESS URLs ==="
    print_info "ML Platform: http://${PUBLIC_IP}:8080"
    print_info "Jupyter Notebook: http://${PUBLIC_IP}:8888"
    print_info "TensorBoard: http://${PUBLIC_IP}:6006"
    
    # Keep script alive for Azure Batch
    print_info "Running in Azure Batch mode - keeping script alive..."
    while true; do
        sleep 3600
    done
}

# ========== COMMAND LINE HANDLER ==========
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    case "$1" in
        "install")
            install_everything
            ;;
        "start")
            run_trainer
            ;;
        "post-reboot")
            post_reboot
            ;;
        "monitor")
            start_enhanced_monitoring
            ;;
        "logs")
            sudo docker logs -f "$CONTAINER_NAME"
            ;;
        "status")
            sudo docker ps -a | grep "$CONTAINER_NAME"
            echo ""
            echo "Registry: ${REGISTRY_HOST}"
            echo ""
            echo "GPU Status:"
            if command -v nvidia-smi > /dev/null; then
                nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu --format=csv
            else
                echo "NVIDIA drivers not loaded"
            fi
            ;;
        "stop")
            sudo docker stop "$CONTAINER_NAME"
            ;;
        "test-registry")
            print_info "Testing registry connection..."
            docker_login
            sudo docker pull "${REGISTRY_IMAGE}"
            ;;
        "batch-mode")
            # Run in Azure Batch mode
            main "batch-mode"
            ;;
        *)
            # Default: run main
            main "$@"
            ;;
    esac
fi
