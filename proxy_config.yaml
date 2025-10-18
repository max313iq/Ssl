#!/bin/bash
set -e

echo "=== Downloading LiteLLM Config ==="

# Download the config file
CONFIG_URL="https://raw.githubusercontent.com/max313iq/Ssl/main/proxy_config.yaml"
CONFIG_FILE="/app/proxy_config.yaml"

# Use Python to download the file
python3 -c "
import urllib.request
import ssl
ssl._create_default_https_context = ssl._create_unverified_context
try:
    urllib.request.urlretrieve('$CONFIG_URL', '$CONFIG_FILE')
    print('✅ Config downloaded successfully')
except Exception as e:
    print(f'❌ Failed to download config: {e}')
    exit(1)
"

echo "=== Starting LiteLLM ==="
exec litellm --config /app/proxy_config.yaml
