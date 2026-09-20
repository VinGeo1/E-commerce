#!/bin/bash
export AWS_DEFAULT_REGION=us-east-1
set +e

echo "=========================================="
echo "STEP 1: Delete orphaned target groups"
echo "=========================================="
for TG in arn:aws:elasticloadbalancing:us-east-1:414100287492:targetgroup/tf-3eb1c25ed8865bbfb4826d6ac8/29033f19f9a746e1 \
          arn:aws:elasticloadbalancing:us-east-1:414100287492:targetgroup/tf-95864babe5b13c4e695d88358f/3332e8408ca33e48; do
  echo "Deleting: $TG"
  aws elbv2 delete-target-group --target-group-arn "$TG" 2>&1 || echo "  (already gone)"
done

echo ""
echo "=========================================="
echo "STEP 2: Delete the 3 orphaned VPCs"
echo "=========================================="

for VPC in vpc-0f5e6c57b06b51e23 vpc-0bfc4df8502d29015 vpc-0ab75af22b15f084c; do
  echo ""
  echo "--- Cleaning VPC: $VPC ---"

  # 1. Delete non-main route tables
  for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" \
    --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text); do
    echo "  Deleting route table: $RT"
    # Dissociate from any subnets first
    for A in $(aws ec2 describe-route-tables --route-table-ids "$RT" \
      --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text); do
      aws ec2 disassociate-route-table --association-id "$A" 2>/dev/null || true
    done
    aws ec2 delete-route-table --route-table-id "$RT" 2>&1 | head -1
  done

  # 2. Delete subnets (should already be gone)
  for SN in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
    --query 'Subnets[].SubnetId' --output text); do
    echo "  Deleting subnet: $SN"
    aws ec2 delete-subnet --subnet-id "$SN" 2>&1 | head -1
  done

  # 3. Delete IGW (should already be gone)
  for IGW in $(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC" \
    --query 'InternetGateways[].InternetGatewayId' --output text); do
    echo "  Detaching IGW: $IGW"
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC" 2>&1 | head -1
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" 2>&1 | head -1
  done

  # 4. Delete non-default security groups
  for SG in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
    echo "  Deleting SG: $SG"
    aws ec2 delete-security-group --group-id "$SG" 2>&1 | head -1
  done

  # 5. Delete the VPC
  echo "  Deleting VPC: $VPC"
  aws ec2 delete-vpc --vpc-id "$VPC" 2>&1 | head -2
done

echo ""
echo "=========================================="
echo "STEP 3: Verify — should be empty"
echo "=========================================="
aws ec2 describe-vpcs --filters "Name=cidr-block,Values=10.0.0.0/16" \
  --query 'Vpcs[].VpcId' --output text
echo "(if blank above, all VPCs are gone)"