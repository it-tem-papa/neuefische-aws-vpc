#!/bin/bash

# Exit on error
set -e

# Configurable variables
REGION="us-west-2"
VPC_CIDR="10.0.0.0/25"
PUBLIC_SUBNET_CIDR="10.0.0.0/27"   # 32-5=27 Public IPs
PRIVATE_SUBNET_CIDR="10.0.0.64/26" # 64-5=59 Private IPs
AMI_ID="ami-00a7380fd4aafd9d1" # Amazon Linux 2 AMI
INSTANCE_TYPE="t3.micro"
KEY_NAME="vockey" # Update this with your key pair name
TAG="secure-infra"
VPC_NAME="$TAG-vpc"
PUBLIC_SUBNET_NAME="$TAG-public"
PRIVATE_SUBNET_NAME="$TAG-private"
IGW_NAME="$TAG-igw"
PUBLIC_RT_NAME="$TAG-public-rt"
PRIVATE_RT_NAME="$TAG-private-rt"
NAT_GW_NAME="$TAG-nat"
WEB_SG_NAME="$TAG-web-sg"
APP_SG_NAME="$TAG-app-sg"
WEB_INSTANCE_NAME="$TAG-web"
APP_INSTANCE_NAME="$TAG-app"
USER_DATA_SCRIPT="#!/bin/bash\n\
# Update system on first boot\n\
yum update -y\n\
"

echo "Starting AWS infrastructure setup..."

USER_IP=$(curl -s http://checkip.amazonaws.com)
echo "User's Public IP Address: $USER_IP"

# Check if VPC with the specified name exists
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=$VPC_NAME" \
  --query "Vpcs[0].VpcId" \
  --output text)

# If the VPC doesn't exist, create it
if [ "$VPC_ID" == "None" ]; then
        
    # Create VPC
    VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --region $REGION \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME}]" \
    --output text --query 'Vpc.VpcId')

    echo "Created VPC: $VPC_ID"
else
  echo "VPC with the name $VPC_NAME already exists. VPC ID: $VPC_ID"
fi

# Check if subnet with the specified name exists in the given VPC
PUBLIC_SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=$PUBLIC_SUBNET_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[0].SubnetId" \
  --output text)

# If the subnet doesn't exist, create it
if [ "$PUBLIC_SUBNET_ID" == "None" ]; then
    # Create Subnet
    PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PUBLIC_SUBNET_CIDR \
    --availability-zone ${REGION}a \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PUBLIC_SUBNET_NAME}]" \
    --output text --query 'Subnet.SubnetId')

    echo "Subnet created: Public=$PUBLIC_SUBNET_ID"
else
  echo "Subnet with the name $PUBLIC_SUBNET_NAME already exists. Subnet ID: $PUBLIC_SUBNET_ID"
fi

# Check if subnet with the specified name exists in the given VPC
PRIVATE_SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=$PRIVATE_SUBNET_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[0].SubnetId" \
  --output text)

# If the subnet doesn't exist, create it
if [ "$PRIVATE_SUBNET_ID" == "None" ]; then

    # Create Subnet
    PRIVATE_SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PRIVATE_SUBNET_CIDR \
    --availability-zone ${REGION}a \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PRIVATE_SUBNET_NAME}]" \
    --output text --query 'Subnet.SubnetId')

    echo "Subnet created: Private=$PRIVATE_SUBNET_ID"
else
    echo "Subnet with the name $PRIVATE_SUBNET_NAME already exists. Subnet ID: $SUBNET_ID"
fi

# Check if IGW with the specified name exists
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=tag:Name,Values=$IGW_NAME" \
  --output text --query "InternetGateways[0].InternetGatewayId")

# If no IGW exists with that name, create a new one
if [ "$IGW_ID" == "None" ]; then

    # Internet Gateway
    IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME}]" \
    --output text --query 'InternetGateway.InternetGatewayId')

    aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
    echo "Created and attached IGW: $IGW_ID"
else 
    echo "Internet Gateway with the name $IGW_NAME already exists. IGW ID: $IGW_ID" 
fi

# Check if a Route Table with the specified name exists
PUBLIC_RT_ID=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=$PUBLIC_RT_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[0].RouteTableId" \
  --output text)

# If no Route Table exists with that name, create a new one
if [ "$PUBLIC_RT_ID" == "None" ]; then
  
    # Route Tables
    PUBLIC_RT_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PUBLIC_RT_NAME}]" \
    --output text --query 'RouteTable.RouteTableId')

    aws ec2 create-route \
    --route-table-id $PUBLIC_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID

    aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET_ID --route-table-id $PUBLIC_RT_ID

    # Enable Auto-Assign Public IP on Public Subnet
    aws ec2 modify-subnet-attribute --subnet-id $PUBLIC_SUBNET_ID --map-public-ip-on-launch
else 
    echo "Route Table with the name $PUBLIC_RT_NAME already exists. Route Table ID: $PUBLIC_RT_ID"
fi    

# Check if a NAT Gateway with the specified name exists
NAT_GW_ID=$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=$NAT_GW_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "NatGateways[0].NatGatewayId" \
  --output text)

# If no NAT Gateway exists with that name, create a new one
if [ "$NAT_GW_ID" == "None" ]; then

    # Elastic IP for NAT Gateway
    EIP_ALLOC_ID=$(aws ec2 allocate-address --domain vpc --output text --query 'AllocationId')

    # NAT Gateway
    NAT_GW_ID=$(aws ec2 create-nat-gateway \
    --subnet-id $PUBLIC_SUBNET_ID \
    --allocation-id $EIP_ALLOC_ID \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$NAT_GW_NAME}]" \
    --output text --query 'NatGateway.NatGatewayId')

    echo "Waiting for NAT Gateway to become available..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW_ID
    echo "NAT Gateway ready: $NAT_GW_ID"
else
  echo "NAT Gateway with the name $NAT_GW_NAME already exists. NAT Gateway ID: $NAT_GW_ID"
fi

# Check if a Route Table with the specified name exists
PRIVATE_RT_ID=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=$PRIVATE_RT_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[0].RouteTableId" \
  --output text)

# If no Route Table exists with that name, create a new one
if [ "$PRIVATE_RT_ID" == "None" ]; then

    # Private Route Table
    PRIVATE_RT_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PRIVATE_RT_NAME}]" \
    --query 'RouteTable.RouteTableId' \
    --output text)

    aws ec2 create-route \
    --route-table-id $PRIVATE_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id $NAT_GW_ID

    aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET_ID --route-table-id $PRIVATE_RT_ID

else 
    echo "Route Table with the name $PRIVATE_RT_NAME already exists. Route Table ID: $PRIVATE_RT_ID"
fi  

# Check if the Security Group with the specified name exists
WEB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=$WEB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text)

# If no Security Group exists with that name, create a new one
if [ "$WEB_SG_ID" == "None" ]; then

    # Security Groups
    WEB_SG_ID=$(aws ec2 create-security-group \
    --group-name "$WEB_SG_NAME" \
    --description "Allow HTTP, HTTPS, SSH" \
    --vpc-id $VPC_ID \
    --query 'GroupId' \
    --output text)

    aws ec2 authorize-security-group-ingress --group-id $WEB_SG_ID \
    --protocol tcp --port 22 --cidr $USER_IP/32
    

    aws ec2 authorize-security-group-ingress --group-id $WEB_SG_ID \
    --protocol tcp --port 80 --cidr 0.0.0.0/0

    aws ec2 authorize-security-group-ingress --group-id $WEB_SG_ID \
    --protocol tcp --port 443 --cidr 0.0.0.0/0

else
  echo "Security Group with the name $WEB_SG_NAME already exists. Security Group ID: $WEB_SG_ID"
fi

# Check if the Security Group with the specified name exists
APP_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=$APP_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text)

# If no Security Group exists with that name, create a new one
if [ "$APP_SG_ID" == "None" ]; then

    APP_SG_ID=$(aws ec2 create-security-group \
    --group-name "$APP_SG_NAME" \
    --description "Allow only from web SG" \
    --vpc-id $VPC_ID \
    --query 'GroupId' \
    --output text)

    aws ec2 authorize-security-group-ingress --group-id $APP_SG_ID \
    --protocol tcp --port 22 \
    --source-group $WEB_SG_ID

else
  echo "Security Group with the name $APP_SG_NAME already exists. Security Group ID: $APP_SG_ID"
fi

# Check if the EC2 instance with the specified name exists
WEB_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$WEB_INSTANCE_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)

# If no EC2 instance exists with that name, create a new one
if [ "$WEB_INSTANCE_ID" == "None" ]; then

    # Launch EC2 Instances
    WEB_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_NAME \
    --security-group-ids $WEB_SG_ID \
    --subnet-id $PUBLIC_SUBNET_ID \
    --user-data "$USER_DATA_SCRIPT" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$WEB_INSTANCE_NAME}]" \
    --output text --query 'Instances[0].InstanceId')

    echo "Web Instance ID: $WEB_INSTANCE_ID"
else 
  echo "EC2 Instance with the name $INSTANCE_NAME already exists. Instance ID: $INSTANCE_ID"
fi

# Wait until the instance is running
echo "Waiting for Web EC2 Instance to be in running state..."
aws ec2 wait instance-running --instance-ids $WEB_INSTANCE_ID
echo "EC2 Instance is now running."

# Check if the EC2 instance with the specified name exists
APP_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$APP_INSTANCE_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)

# If no EC2 instance exists with that name, create a new one
if [ "$APP_INSTANCE_ID" == "None" ]; then

    APP_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_NAME \
    --security-group-ids $APP_SG_ID \
    --subnet-id $PRIVATE_SUBNET_ID \
    --user-data "$USER_DATA_SCRIPT" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$APP_INSTANCE_NAME}]" \
    --output text --query 'Instances[0].InstanceId')

    echo "App Instance ID: $APP_INSTANCE_ID"
else 
  echo "EC2 Instance with the name $APP_INSTANCE_NAME already exists. Instance ID: $APP_INSTANCE_ID"
fi
# Wait until the instance is running
echo "Waiting for Web EC2 Instance to be in running state..."
aws ec2 wait instance-running --instance-ids $APP_INSTANCE_ID
echo "EC2 Instance is now running."

echo "AWS infrastructure setup complete."
