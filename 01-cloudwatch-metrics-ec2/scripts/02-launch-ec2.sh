#!/bin/bash
# Demo 01 - Script 2: Launch EC2 with Detailed Monitoring
# Run this from your local machine

set -e

echo "=== Launching EC2 Instance ==="

# Get latest Amazon Linux 2023 AMI
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)
echo "AMI: $AMI_ID"

# Get default VPC
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)
echo "VPC: $VPC_ID"

# Get a subnet
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[0].SubnetId' --output text)
echo "Subnet: $SUBNET_ID"

# Create security group
SG_ID=$(aws ec2 create-security-group \
  --group-name demo01-sg \
  --description "Demo01 CloudWatch Metrics" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)
echo "Security Group: $SG_ID"

# Allow SSH for EC2 Instance Connect
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp --port 22 --cidr 0.0.0.0/0

# Launch instance
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.micro \
  --iam-instance-profile Name=EC2CloudWatchProfile \
  --security-group-ids $SG_ID \
  --subnet-id $SUBNET_ID \
  --associate-public-ip-address \
  --monitoring Enabled=true \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=demo01-cw-metrics}]' \
  --query 'Instances[0].InstanceId' --output text)

echo "Instance ID: $INSTANCE_ID"
echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
echo "=== Instance is running ==="

aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,Monitoring:Monitoring.State,IP:PublicIpAddress}' \
  --output table

echo ""
echo "Connect via EC2 Instance Connect console or:"
echo "aws ec2-instance-connect ssh --instance-id $INSTANCE_ID"