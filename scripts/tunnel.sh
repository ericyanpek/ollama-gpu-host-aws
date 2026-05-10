#!/usr/bin/env bash
# tunnel.sh — SSM Port Forwarding: MacBook localhost:11434 → EC2 Ollama.
#
# Requires: AWS CLI v2 + Session Manager Plugin
#   brew install --cask session-manager-plugin

set -euo pipefail

STACK_NAME="${STACK_NAME:-ollama-host-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
LOCAL_PORT="${LOCAL_PORT:-11434}"

if ! command -v session-manager-plugin >/dev/null 2>&1; then
  echo "ERROR: session-manager-plugin not installed." >&2
  echo "Install: brew install --cask session-manager-plugin" >&2
  exit 1
fi

# shellcheck disable=SC2016  # JMESPath literal; intentionally not shell-expanded
INSTANCE_ID="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
  --output text)"

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "ERROR: InstanceId not found on stack $STACK_NAME in $AWS_REGION." >&2
  exit 1
fi

# Check instance state before trying to tunnel.
STATE="$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null || echo unknown)"
if [ "$STATE" != "running" ]; then
  echo "Instance $INSTANCE_ID is in state: $STATE" >&2
  if [ "$STATE" = "stopped" ]; then
    echo "Starting it..." >&2
    aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
    echo "Running. Give Ollama ~30s to restart, then the tunnel will work."
  else
    exit 1
  fi
fi

echo "Starting SSM port-forward: localhost:${LOCAL_PORT} → ${INSTANCE_ID}:11434"
echo
echo "Once connected, from another terminal:"
echo "  curl http://localhost:${LOCAL_PORT}/api/tags"
echo "  curl http://localhost:${LOCAL_PORT}/v1/models"
echo
echo "Ctrl+C to close the tunnel."
echo

exec aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"11434\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
