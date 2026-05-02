#!/bin/bash
# Demo 01 - Script 3: Install and Configure CloudWatch Agent
# Run this INSIDE the EC2 instance via EC2 Instance Connect

set -e

echo "=== Installing CloudWatch Agent ==="
sudo dnf install -y amazon-cloudwatch-agent stress-ng

echo "=== Writing Agent Configuration ==="
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CONFIG'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent"
  },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}",
      "InstanceType": "${aws:InstanceType}"
    },
    "metrics_collected": {
      "mem": {
        "measurement": ["mem_used_percent", "mem_available", "mem_total"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["disk_used_percent", "disk_free", "disk_total"],
        "resources": ["/"],
        "metrics_collection_interval": 60
      },
      "cpu": {
        "measurement": ["cpu_usage_user", "cpu_usage_system", "cpu_usage_idle"],
        "metrics_collection_interval": 60
      }
    }
  }
}
CONFIG

echo "=== Starting CloudWatch Agent ==="
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

echo "=== Agent Status ==="
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status
echo "=== Done. Metrics will appear in CloudWatch within 60 seconds ==="