#!/bin/bash
# Script to kill NiFi processes safely

echo "$(date '+%F %T') | 🔍 Starting NiFi process termination script..."

# Get list of NiFi process IDs
nifi_pids=$(pgrep -f nifi.sh || echo "")

if [[ -n "$nifi_pids" ]]; then
    echo "$(date '+%F %T') | ℹ️ Found NiFi processes running (PIDs: $nifi_pids), attempting to kill them..."
    
    # First try gentle termination
    for pid in $nifi_pids; do
        echo "$(date '+%F %T') | ℹ️ Sending SIGTERM to PID $pid..."
        sudo kill $pid 2>/dev/null || echo "$(date '+%F %T') | ⚠️ Warning: kill command failed for PID $pid"
    done
    
    echo "$(date '+%F %T') | ℹ️ Waiting for processes to terminate..."
    sleep 5
    
    # Check if processes were successfully killed
    nifi_pids=$(pgrep -f nifi.sh || echo "")
    if [[ -n "$nifi_pids" ]]; then
        echo "$(date '+%F %T') | ⚠️ Warning: NiFi processes still running after SIGTERM, trying SIGKILL..."
        for pid in $nifi_pids; do
            echo "$(date '+%F %T') | ℹ️ Sending SIGKILL to PID $pid..."
            sudo kill -9 $pid 2>/dev/null || echo "$(date '+%F %T') | ⚠️ Warning: kill -9 command failed for PID $pid"
        done
        sleep 2
        
        # Final check
        nifi_pids=$(pgrep -f nifi.sh || echo "")
        if [[ -n "$nifi_pids" ]]; then
            echo "$(date '+%F %T') | ⚠️ Warning: Some NiFi processes could not be killed (PIDs: $nifi_pids)"
        else
            echo "$(date '+%F %T') | ✅ All NiFi processes successfully terminated"
        fi
    else
        echo "$(date '+%F %T') | ✅ All NiFi processes successfully terminated"
    fi
else
    echo "$(date '+%F %T') | ℹ️ No NiFi processes found running"
fi

echo "$(date '+%F %T') | ✅ NiFi process termination script completed"
exit 0