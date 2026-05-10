#!/usr/bin/env bash
# deploy.sh — Create or update the Ollama GPU Host stack.
#
# Usage:
#   ./scripts/deploy.sh                          # defaults: us-east-1, g5.xlarge, on-demand, gemma4:26b
#   USE_SPOT=true ./scripts/deploy.sh            # Spot (~60% cheaper)
#   AWS_REGION=us-west-2 ./scripts/deploy.sh     # different region
#   INSTANCE_TYPE=g6e.xlarge ./scripts/deploy.sh # 48GB L40S
#   OLLAMA_MODEL=llama3.1:8b ./scripts/deploy.sh # different model
#
# Env vars:
#   STACK_NAME          (default: ollama-host-dev)
#   AWS_REGION          (default: us-east-1)
#   PROJECT_NAME        (default: ollama-host)
#   ENVIRONMENT         (default: dev)
#   INSTANCE_TYPE       (default: g5.xlarge)
#   USE_SPOT            (default: false)
#   ROOT_VOLUME_GB      (default: 100)
#   OLLAMA_MODEL        (default: gemma4:26b — any ollama.com/library tag works)
#   OLLAMA_NUM_PARALLEL (default: 4)
#   OLLAMA_KEEP_ALIVE   (default: 24h)
#   AUTO_SHUTDOWN_HOURS (default: 1)
#   VPC_ID              (default: auto-detect default VPC)
#   SUBNET_ID           (default: first subnet in an instance-compatible AZ)

set -euo pipefail

STACK_NAME="${STACK_NAME:-ollama-host-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-ollama-host}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.xlarge}"
USE_SPOT="${USE_SPOT:-false}"
ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-100}"
OLLAMA_MODEL="${OLLAMA_MODEL:-gemma4:26b}"
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-4}"
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-24h}"
AUTO_SHUTDOWN_HOURS="${AUTO_SHUTDOWN_HOURS:-1}"
VPC_ID="${VPC_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../cloudformation/ollama-host.yaml"

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: template not found at $TEMPLATE" >&2
  exit 1
fi

# ---- VPC/Subnet auto-detect ------------------------------------------------
if [ -z "$VPC_ID" ]; then
  VPC_ID="$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --region "$AWS_REGION" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
  if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    echo "ERROR: no default VPC in $AWS_REGION. Pass VPC_ID= and SUBNET_ID= explicitly." >&2
    exit 1
  fi
  echo "Auto-detected default VPC: $VPC_ID"
fi

if [ -z "$SUBNET_ID" ]; then
  OFFERED_AZS="$(aws ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
    --region "$AWS_REGION" \
    --query 'InstanceTypeOfferings[].Location' --output text 2>/dev/null || echo "")"
  if [ -z "$OFFERED_AZS" ]; then
    echo "ERROR: $INSTANCE_TYPE not offered in any AZ of $AWS_REGION." >&2
    exit 1
  fi
  AZ_FILTER="$(echo "$OFFERED_AZS" | tr '\t' ',' | tr ' ' ',')"
  SUBNET_ID="$(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="$VPC_ID" \
              Name=default-for-az,Values=true \
              "Name=availability-zone,Values=$AZ_FILTER" \
    --region "$AWS_REGION" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)"
  if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" = "None" ]; then
    SUBNET_ID="$(aws ec2 describe-subnets \
      --filters Name=vpc-id,Values="$VPC_ID" \
                "Name=availability-zone,Values=$AZ_FILTER" \
      --region "$AWS_REGION" \
      --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)"
  fi
  if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" = "None" ]; then
    echo "ERROR: no subnet in VPC $VPC_ID compatible with $INSTANCE_TYPE." >&2
    exit 1
  fi
  echo "Auto-detected subnet: $SUBNET_ID"
fi

echo "=== Ollama GPU Host deploy ==="
echo "Stack:         $STACK_NAME"
echo "Region:        $AWS_REGION"
echo "VPC / Subnet:  $VPC_ID / $SUBNET_ID"
echo "Instance:      $INSTANCE_TYPE ($( [ "$USE_SPOT" = "true" ] && echo 'Spot' || echo 'On-Demand' ))"
echo "Volume:        ${ROOT_VOLUME_GB}GB gp3"
echo "Ollama:        model=$OLLAMA_MODEL parallel=$OLLAMA_NUM_PARALLEL keep_alive=$OLLAMA_KEEP_ALIVE"
echo "Auto-shutdown: ${AUTO_SHUTDOWN_HOURS}h idle"
echo "==============================="
echo

echo "Validating template..."
aws cloudformation validate-template \
  --template-body "file://${TEMPLATE}" \
  --region "$AWS_REGION" >/dev/null

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --region "$AWS_REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ProjectName="$PROJECT_NAME" \
    Environment="$ENVIRONMENT" \
    InstanceType="$INSTANCE_TYPE" \
    UseSpotInstance="$USE_SPOT" \
    RootVolumeSizeGB="$ROOT_VOLUME_GB" \
    OllamaModel="$OLLAMA_MODEL" \
    OllamaNumParallel="$OLLAMA_NUM_PARALLEL" \
    OllamaKeepAlive="$OLLAMA_KEEP_ALIVE" \
    AutoShutdownHours="$AUTO_SHUTDOWN_HOURS" \
    VpcId="$VPC_ID" \
    SubnetId="$SUBNET_ID" \
  --tags Project="$PROJECT_NAME" Environment="$ENVIRONMENT"

echo
echo "=== Stack deployed. Outputs: ==="
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table

echo
echo "Next:"
echo "  1. Wait for bootstrap to finish (model pull + warm-up, 8–12 min):"
echo "     ./scripts/status.sh"
echo
echo "  2. Once ready, open the tunnel in another terminal:"
echo "     ./scripts/tunnel.sh"
echo
echo "  3. Test from your Mac:"
echo "     curl http://localhost:11434/api/tags"
