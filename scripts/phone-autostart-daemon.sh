#!/usr/bin/env bash
# Nexus iOS Self-Monitor Headless Auto-Start Watcher
# Automatically detects connected iPhone XR, mounts DeveloperDiskImage if needed,
# and starts the app headlessly without touching the screen.

set -u

PMD3="/home/ben/.pmd3-venv/bin/pymobiledevice3"
IDEVICE_ID="/home/ben/.local/bin/idevice_id"
BUNDLE_ID="com.nexus.selfmonitor.app.Z83T82X5JV"
INTERVAL=10

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Nexus iOS Watcher Daemon..."

while true; do
    CONNECTED_DEVICES=$($IDEVICE_ID -l 2>/dev/null)
    
    if [ -n "$CONNECTED_DEVICES" ]; then
        # Device is connected on USB. Check if process is alive.
        IS_RUNNING=$($PMD3 developer core-device list-processes --userspace 2>/dev/null | grep -F "NexusSelfMonitor" || true)
        
        if [ -z "$IS_RUNNING" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] iPhone detected but NexusSelfMonitor is not running. Mounting DDI..."
            $PMD3 mounter auto-mount >/dev/null 2>&1 || true
            
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Launching $BUNDLE_ID headlessly via CoreDevice..."
            LAUNCH_OUTPUT=$($PMD3 developer core-device launch-application --userspace "$BUNDLE_ID" "" 2>&1 || true)
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Result: $LAUNCH_OUTPUT"
            
            # Allow app 10s to initialize and engage audio recording loop
            sleep 10
        fi
    fi
    
    sleep "$INTERVAL"
done
