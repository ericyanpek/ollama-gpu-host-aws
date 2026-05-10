#!/usr/bin/env bash
# destroy.sh — Tear down the Ollama GPU Host stack.
# The artifact S3 bucket is Retain — if you want to wipe it too, do it by hand.

set -euo pipefail

STACK_NAME="${STACK_NAME:-ollama-host-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "=== Destroying stack: $STACK_NAME ($AWS_REGION) ==="
echo "Note: the artifact S3 bucket is retained. To delete it:"
echo
# shellcheck disable=SC2016  # JMESPath literal; intentionally not shell-expanded
BUCKET="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ArtifactBucketName`].OutputValue' \
  --output text 2>/dev/null || true)"
if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  echo "  aws s3 rb s3://$BUCKET --force --region $AWS_REGION"
fi
echo

read -r -p "Proceed with stack deletion? [y/N] " ans
case "$ans" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 0 ;;
esac

aws cloudformation delete-stack \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION"

echo "Delete initiated. Waiting for completion..."
aws cloudformation wait stack-delete-complete \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION"

echo "Stack deleted."
