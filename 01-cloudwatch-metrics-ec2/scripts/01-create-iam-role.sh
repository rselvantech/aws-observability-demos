#!/bin/bash
# Demo 01 - Script 1: Create IAM Role for EC2 → CloudWatch
# Run this from your local machine (not the EC2 instance)

set -e

echo "=== Creating IAM Role for EC2 CloudWatch Access ==="

# Create trust policy
cat > /tmp/ec2-trust-policy.json << 'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY

# Create role
aws iam create-role \
  --role-name EC2CloudWatchRole \
  --assume-role-policy-document file:///tmp/ec2-trust-policy.json \
  --description "Allows EC2 instances to send metrics and logs to CloudWatch"

# Attach managed policy
aws iam attach-role-policy \
  --role-name EC2CloudWatchRole \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

# Create instance profile
aws iam create-instance-profile \
  --instance-profile-name EC2CloudWatchProfile

# Add role to profile
aws iam add-role-to-instance-profile \
  --instance-profile-name EC2CloudWatchProfile \
  --role-name EC2CloudWatchRole

echo "=== IAM Role Created ==="
aws iam get-role --role-name EC2CloudWatchRole \
  --query 'Role.{Name:RoleName,Arn:Arn}' --output table