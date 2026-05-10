#!/usr/bin/env bash
# status.sh — Quick status check for the Ollama host.
# Shows: instance state, bootstrap progress, model availability.

set -euo pipefail

STACK_NAME="${STACK_NAME:-ollama-host-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# shellcheck disable=SC2016  # JMESPath literal; intentionally not shell-expanded
INSTANCE_ID="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
  --output text 2>/dev/null || echo "")"

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "Stack $STACK_NAME not found or missing InstanceId output." >&2
  exit 1
fi

echo "=== Stack: $STACK_NAME ($AWS_REGION) ==="
STACK_STATUS="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].StackStatus' --output text)"
echo "Stack status:    $STACK_STATUS"

INFO="$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].[State.Name,InstanceType,LaunchTime]' \
  --output text)"
STATE="$(echo "$INFO" | awk '{print $1}')"
echo "Instance:        $INSTANCE_ID ($STATE)"
echo "  Type:          $(echo "$INFO" | awk '{print $2}')"
echo "  Launched:      $(echo "$INFO" | awk '{print $3}')"

if [ "$STATE" != "running" ]; then
  echo
  echo "Instance is not running; skipping bootstrap / model checks."
  exit 0
fi

# Run Command to peek inside the instance.
echo
echo "=== Bootstrap & model status ==="
CMD_ID="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --document-name 'AWS-RunShellScript' \
  --comment 'ollama-host status check' \
  --parameters 'commands=[
    "echo --- markers ---",
    "ls -l /var/lib/cloud/instance/ollama-ready 2>/dev/null || echo ollama-ready: not yet",
    "echo --- ollama service ---",
    "systemctl is-active ollama 2>/dev/null || echo ollama: not active",
    "echo --- loaded models ---",
    "curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || echo api not reachable",
    "echo --- last 20 lines of user-data.log ---",
    "tail -n 20 /var/log/user-data.log 2>/dev/null || echo no log yet"
  ]' \
  --query 'Command.CommandId' --output text 2>/dev/null || true)"

if [ -z "$CMD_ID" ]; then
  echo "Could not send SSM command; instance may still be initialising."
  exit 0
fi

# Wait for the command, then show output.
for _ in $(seq 1 20); do
  STATUS="$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Status' --output text 2>/dev/null || echo Pending)"
  case "$STATUS" in
    Success|Failed|Cancelled|TimedOut) break ;;
  esac
  sleep 2
done

aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --query 'StandardOutputContent' --output text 2>/dev/null || true
