#!/bin/bash
# Demo 01 - Script 4: Simulate CPU and Memory Load
# Run this INSIDE the EC2 instance

echo "=== Starting CPU stress (2 CPUs, 5 minutes) ==="
stress-ng --cpu 2 --timeout 300s &
CPU_PID=$!
echo "CPU stress PID: $CPU_PID"

echo ""
echo "Watch CPUUtilization spike in CloudWatch console:"
echo "CloudWatch → Metrics → AWS/EC2 → Per-Instance Metrics → CPUUtilization"
echo ""
echo "To stop early: kill $CPU_PID"
echo "Stress will auto-stop in 5 minutes"

# Optional: memory stress (uncomment to run)
# echo "=== Starting Memory stress (400MB, 3 minutes) ==="
# stress-ng --vm 1 --vm-bytes 400M --timeout 180s &
# echo "Memory stress PID: $!"