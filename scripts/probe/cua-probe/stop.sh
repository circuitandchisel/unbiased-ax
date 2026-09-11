#!/bin/bash
# Stops the probe. The log is left where it is.
pkill -f 'ProbeTarget.app/Contents/MacOS/ProbeTarget' 2>/dev/null
pkill -f 'build/recorder' 2>/dev/null
pkill -f 'web-probe.cjs' 2>/dev/null
sleep 1
echo "probe stopped; log kept at $HOME/cua-probe/probe.jsonl"
