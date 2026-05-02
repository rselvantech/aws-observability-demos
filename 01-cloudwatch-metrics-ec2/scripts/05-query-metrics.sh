#!/bin/bash
# Demo 01 - Script 5: Query CloudWatch Metrics via CLI
# Run this from your local machine

set -e

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=demo01-cw-metrics" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

echo "=== Instance: $INSTANCE_ID ==="

echo ""
echo "=== CPUUtilization (last 1 hour, 5-min periods) ==="
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average Maximum \
  --output table

echo ""
echo "=== Memory Used % (CWAgent, last 30 min) ==="
aws cloudwatch get-metric-statistics \
  --namespace CWAgent \
  --metric-name mem_used_percent \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v-30M +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Average \
  --output table

echo ""
echo "=== All Available EC2 Metrics for this Instance ==="
aws cloudwatch list-metrics \
  --namespace AWS/EC2 \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID \
  --query 'Metrics[].MetricName' \
  --output table

echo ""
echo "=== All CWAgent Metrics for this Instance ==="
aws cloudwatch list-metrics \
  --namespace CWAgent \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID \
  --query 'Metrics[].MetricName' \
  --output table