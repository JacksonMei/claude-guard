#!/usr/bin/env bash
# Demo script for asciinema recording
GUARD="/Users/jun/Documents/code/xagent/cluade-guard/scripts/guard.sh"

echo '$ /guard ram'
sleep 0.5
bash "$GUARD" ram
sleep 2

echo ''
echo '$ /guard sessions'
sleep 0.5
bash "$GUARD" sessions
sleep 2

echo ''
echo '$ /guard clean --dry-run'
sleep 0.5
bash "$GUARD" clean --dry-run
sleep 2

echo ''
echo '$ /guard auto --dry-run'
sleep 0.5
bash "$GUARD" auto --dry-run
sleep 1
