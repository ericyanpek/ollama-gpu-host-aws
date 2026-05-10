#!/usr/bin/env bash
# ssm-shell.sh — Open an interactive SSM shell on the Ollama host.

set -euo pipefail

STACK_NAME="${STACK_NAME:-ollama-host-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"

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

echo "Connecting to $INSTANCE_ID ($AWS_REGION)..."
echo "Useful commands once inside:"
echo "  tail -f /var/log/user-data.log"
echo "  journalctl -u ollama -f"
echo "  ollama list"
echo "  nvidia-smi"
echo

exec aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
