#!/usr/bin/env bash

set -uo pipefail

# aws_capability_tester.sh
# Directly tests AWS service capabilities by attempting actual operations
# Focuses on what you CAN do, not IAM policy details

if ! command -v aws >/dev/null 2>&1; then
  echo "[ERROR] aws CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
  exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="aws_capability_test_${timestamp}"
mkdir -p "${OUT_DIR}"

echo "================================================"
echo "AWS Capability Tester - Direct Permission Check"
echo "================================================"
echo "Output directory: ${OUT_DIR}"
echo ""

# Get basic identity (this usually works)
echo "[INFO] Getting caller identity..."
if aws sts get-caller-identity > "${OUT_DIR}/identity.json" 2>"${OUT_DIR}/identity_error.txt"; then
  account_id="$(cat "${OUT_DIR}/identity.json" | grep -o '"Account"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)"
  caller_arn="$(cat "${OUT_DIR}/identity.json" | grep -o '"Arn"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)"
  echo "✓ Account: ${account_id}"
  echo "✓ Identity: ${caller_arn}"
else
  echo "✗ Cannot get caller identity"
  cat "${OUT_DIR}/identity_error.txt"
fi
echo ""

# Initialize results file
cat > "${OUT_DIR}/results.json" <<EOF
{
  "timestamp": "${timestamp}",
  "account_id": "${account_id:-unknown}",
  "caller_arn": "${caller_arn:-unknown}",
  "tests": []
}
EOF

# Function to test a capability
test_capability() {
  local service="$1"
  local operation="$2"
  local command="$3"
  local description="$4"
  
  echo -n "Testing ${service}:${operation} - ${description}... "
  
  # Create test files
  local test_file="${OUT_DIR}/${service}_${operation}"
  local success="false"
  local error_msg=""
  
  # Execute the test
  if eval "${command}" > "${test_file}_output.txt" 2>"${test_file}_error.txt"; then
    echo "✓ ALLOWED"
    success="true"
  else
    error_msg="$(cat "${test_file}_error.txt" | head -n1)"
    if [[ "${error_msg}" == *"DryRunOperation"* ]] || [[ "${error_msg}" == *"Request would have succeeded"* ]]; then
      echo "✓ ALLOWED (dry-run success)"
      success="true"
    elif [[ "${error_msg}" == *"AccessDenied"* ]] || [[ "${error_msg}" == *"UnauthorizedOperation"* ]] || [[ "${error_msg}" == *"is not authorized"* ]]; then
      echo "✗ DENIED"
    else
      echo "⚠ ERROR: ${error_msg}"
    fi
  fi
  
  # Log result
  cat >> "${OUT_DIR}/test_log.jsonl" <<EOF
{"service":"${service}","operation":"${operation}","description":"${description}","success":${success},"error":"${error_msg}"}
EOF
}

echo "=== EC2 Capabilities ===" | tee -a "${OUT_DIR}/summary.txt"
echo ""

# EC2 Read Operations
test_capability "ec2" "describe_instances" \
  "aws ec2 describe-instances --max-results 1" \
  "List EC2 instances"

test_capability "ec2" "describe_regions" \
  "aws ec2 describe-regions" \
  "List available regions"

test_capability "ec2" "describe_vpcs" \
  "aws ec2 describe-vpcs --max-results 1" \
  "List VPCs"

test_capability "ec2" "describe_security_groups" \
  "aws ec2 describe-security-groups --max-results 1" \
  "List security groups"

test_capability "ec2" "describe_images" \
  "aws ec2 describe-images --owners amazon --filters 'Name=name,Values=amzn2-ami-hvm-*' --max-results 1" \
  "List AMIs"

# EC2 Write Operations (dry-run)
test_capability "ec2" "run_instances" \
  "aws ec2 run-instances --image-id ami-0c02fb55731490381 --instance-type t2.micro --dry-run" \
  "Launch EC2 instance (dry-run)"

test_capability "ec2" "create_security_group" \
  "aws ec2 create-security-group --group-name test-${timestamp} --description 'Test SG' --dry-run" \
  "Create security group (dry-run)"

test_capability "ec2" "allocate_address" \
  "aws ec2 allocate-address --dry-run" \
  "Allocate Elastic IP (dry-run)"

echo ""
echo "=== S3 Capabilities ===" | tee -a "${OUT_DIR}/summary.txt"
echo ""

# S3 Operations
test_capability "s3" "list_buckets" \
  "aws s3api list-buckets" \
  "List S3 buckets"

test_capability "s3" "create_bucket" \
  "aws s3api create-bucket --bucket test-capability-${timestamp}-${RANDOM} --create-bucket-configuration LocationConstraint=us-west-2 2>&1 | head -n1" \
  "Create S3 bucket"

test_capability "s3" "head_bucket" \
  "aws s3api head-bucket --bucket aws-cloudtrail-logs-${account_id}-do-not-delete 2>&1" \
  "Access CloudTrail bucket"

echo ""
echo "=== Lambda Capabilities ===" | tee -a "${OUT_DIR}/summary.txt"
echo ""

# Lambda Operations
test_capability "lambda" "list_functions" \
  "aws lambda list-functions --max-items 1" \
  "List Lambda functions"

test_capability "lambda" "create_function" \
  "aws lambda create-function --function-name test-${timestamp} --runtime python3.9 --role arn:aws:iam::${account_id}:role/nonexistent --handler index.handler --zip-file fileb://<(echo 'def handler(e,c): return 1') 2>&1" \
  "Create Lambda function"

echo ""
echo "=== RDS Capabilities ===" | tee -a "${OUT_DIR}/summary.txt"
echo ""

# RDS Operations
test_capability "rds" "describe_db_instances" \
  "aws rds describe-db-instances --max-records 1" \
  "List RDS instances"

test_capability "rds" "create_db_instance" \
  "aws rds create-db-instance --db-instance-identifier test-${timestamp} --db-instance-class db.t3.micro --engine mysql --master-username admin --master-user-password TestPass123! --allocated-storage 20 2>&1 | head -n1" \
  "Create RDS instance"

echo ""
echo "=== DynamoDB Capabilities ===" | tee -a "${OUT_DIR}/summary.txt"
echo ""

# DynamoDB Operations
test_capability "dynamodb" "list_tables" \
  "aws dynamodb list-tables --max-items 1" \
  "List DynamoDB tables"

test_capability "dynamodb" "create_table" \
  "aws dynamodb create-table --table-name test-${timestamp} --attribute-definitions AttributeName=id,AttributeType=S --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST 2>&1 | head -n1" \
  "Create DynamoDB table"

echo ""
echo "=== ECS/EKS/ECR Capabilities ===" | tee -a "${OUT_DIR}/summary.txt"
echo ""

# Container Services
test_capability "ecs" "list_clusters" \
  "aws ecs list-clusters --max-results 1" \
  "List ECS clusters"

test_capability "ecs" "create_cluster" \
  "aws ecs create-cluster --cluster-name test-${timestamp} 2>&1 | head -n1" \
  "Create ECS cluster"

test_capability "eks" "list_clusters" \
  "aws eks list-clusters --max-results 1" \
  "List EKS clusters"

test_capability "ecr" "describe_repositories" \
  "aws ecr describe-repositories --max-results 1" \
  "List ECR repositories"

test_capability "ecr" "create_repository" \
  "aws ecr create-repository --repository-name test-${timestamp} 2>&1 | head -n1" \
  "Create ECR repository"

echo ""
echo "=== CloudFormation Capabilities ===" | tee -a "${OUT_DIR}/summary.txt"
echo ""

# CloudFormation Operations
test_capability "cloudformation" "list_stacks" \
  "aws cloudformation list-stacks --max-items 1" \
  "List CloudFormation stacks"

test_capability "cloudformation" "create_stack" \
  "aws cloudformation create-stack --stack-name test-${timestamp} --template-body '{\"AWSTemplateFormatVersion\":\"2010-09-09\",\"Resources\":{\"MyBucket\":{\"Type\":\"AWS::S3::Bucket\"}}}' 2>&1 | head -n1" \
  "Create CloudFormation stack"

echo ""
echo "=== API Gateway Capabilities ===" | tee -a "${OUT_DIR}/summary.txt"
echo ""

# API Gateway Operations
test_capability "apigateway" "get_rest_apis" \
  "aws apigateway get-rest-apis --max-items 1" \
  "List REST APIs"

test_capability "apigatewayv2" "get_apis" \
  "aws apigatewayv2 get-apis --max-results 1" \
  "List HTTP APIs"

echo ""
echo "=== SNS/SQS Capabilities ===" | tee -a "${OUT_DIR}/summary.txt"
echo ""

# Messaging Services
test_capability "sns" "list_topics" \
  "aws sns list-topics" \
  "List SNS topics"

test_capability "sns" "create_topic" \
  "aws sns create-topic --name test-${timestamp} 2>&1 | head -n1" \
  "Create SNS topic"

test_capability "sqs" "list_queues" \
  "aws sqs list-queues" \
  "List SQS queues"

test_capability "sqs" "create_queue" \
  "aws sqs create-queue --queue-name test-${timestamp} 2>&1 | head -n1" \
  "Create SQS queue"

echo ""
echo "=== CloudWatch Capabilities ===" | tee -a "${OUT_DIR}/summary.txt"
echo ""

# CloudWatch Operations
test_capability "cloudwatch" "list_metrics" \
  "aws cloudwatch list-metrics --max-items 1" \
  "List CloudWatch metrics"

test_capability "logs" "describe_log_groups" \
  "aws logs describe-log-groups --max-items 1" \
  "List CloudWatch log groups"

echo ""
echo "=== Secrets Manager / Systems Manager ===" | tee -a "${OUT_DIR}/summary.txt"
echo ""

# Secrets and Parameters
test_capability "secretsmanager" "list_secrets" \
  "aws secretsmanager list-secrets --max-items 1" \
  "List secrets"

test_capability "ssm" "describe_parameters" \
  "aws ssm describe-parameters --max-items 1" \
  "List SSM parameters"

test_capability "ssm" "get_parameter" \
  "aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2" \
  "Get public SSM parameter"

echo ""
echo "================================================"
echo "                SUMMARY REPORT                  "
echo "================================================"
echo ""

# Generate summary
echo "Analyzing results..." | tee -a "${OUT_DIR}/summary.txt"
echo "" | tee -a "${OUT_DIR}/summary.txt"

# Count successes and failures
if [ -f "${OUT_DIR}/test_log.jsonl" ]; then
  total_tests=$(wc -l < "${OUT_DIR}/test_log.jsonl" | tr -d ' ')
  allowed_count=$(grep '"success":true' "${OUT_DIR}/test_log.jsonl" | wc -l | tr -d ' ')
  denied_count=$(grep '"success":false' "${OUT_DIR}/test_log.jsonl" | wc -l | tr -d ' ')
  
  echo "Total tests run: ${total_tests}" | tee -a "${OUT_DIR}/summary.txt"
  echo "✓ Allowed operations: ${allowed_count}" | tee -a "${OUT_DIR}/summary.txt"
  echo "✗ Denied operations: ${denied_count}" | tee -a "${OUT_DIR}/summary.txt"
  echo "" | tee -a "${OUT_DIR}/summary.txt"
  
  echo "=== ALLOWED OPERATIONS ===" | tee -a "${OUT_DIR}/summary.txt"
  grep '"success":true' "${OUT_DIR}/test_log.jsonl" | while IFS= read -r line; do
    service=$(echo "$line" | grep -o '"service":"[^"]*"' | cut -d'"' -f4)
    operation=$(echo "$line" | grep -o '"operation":"[^"]*"' | cut -d'"' -f4)
    description=$(echo "$line" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
    echo "  ✓ ${service}:${operation} - ${description}" | tee -a "${OUT_DIR}/summary.txt"
  done
  
  echo "" | tee -a "${OUT_DIR}/summary.txt"
  echo "=== DENIED OPERATIONS ===" | tee -a "${OUT_DIR}/summary.txt"
  grep '"success":false' "${OUT_DIR}/test_log.jsonl" | while IFS= read -r line; do
    service=$(echo "$line" | grep -o '"service":"[^"]*"' | cut -d'"' -f4)
    operation=$(echo "$line" | grep -o '"operation":"[^"]*"' | cut -d'"' -f4)
    description=$(echo "$line" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
    echo "  ✗ ${service}:${operation} - ${description}" | tee -a "${OUT_DIR}/summary.txt"
  done
fi

echo ""
echo "================================================"
echo "Full results saved to: ${OUT_DIR}/"
echo "Summary available at: ${OUT_DIR}/summary.txt"
echo "================================================"

# Create a final recommendations file
cat > "${OUT_DIR}/recommendations.txt" <<EOF
AWS Capability Test - Recommendations
======================================

Based on the test results, here are key findings:

1. EC2 CAPABILITIES:
   - If EC2 RunInstances is ALLOWED: You can launch EC2 instances
   - If EC2 DescribeInstances is ALLOWED: You can monitor existing instances
   - If both are DENIED: You have no EC2 access

2. S3 CAPABILITIES:
   - If S3 CreateBucket is ALLOWED: You can create new S3 buckets
   - If S3 ListBuckets is ALLOWED: You can see existing buckets
   - If S3 GetObject/PutObject are tested separately, they show data access

3. SERVERLESS CAPABILITIES:
   - Lambda CreateFunction: Shows if you can deploy serverless functions
   - API Gateway access: Shows if you can create APIs

4. DATABASE CAPABILITIES:
   - RDS CreateDBInstance: Shows if you can create databases
   - DynamoDB CreateTable: Shows if you can create NoSQL tables

5. CONTAINER CAPABILITIES:
   - ECS/EKS/ECR permissions show container deployment abilities

WHAT YOU CAN DO WITH ALLOWED PERMISSIONS:
- Any operation marked as "✓ ALLOWED" can be executed
- Dry-run successes indicate the actual operation would work
- Focus on services where you have both read and write permissions

NEXT STEPS:
1. For allowed operations, remove --dry-run flags to execute
2. For critical denied operations, request specific IAM permissions
3. Use allowed read operations to audit existing resources
EOF

echo ""
echo "Recommendations saved to: ${OUT_DIR}/recommendations.txt"
