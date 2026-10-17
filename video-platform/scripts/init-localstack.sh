#!/bin/bash
# Runs inside the LocalStack container once it is ready (mounted into
# /etc/localstack/init/ready.d/). Mirrors the AWS resources Terraform creates.
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
UPLOADS=video-platform-uploads
PROCESSED=video-platform-processed
TABLE=video-platform-videos

echo "[init] creating buckets"
awslocal s3api create-bucket --bucket "$UPLOADS" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
awslocal s3api create-bucket --bucket "$PROCESSED" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

# Browser uploads go straight to S3 via presigned PUT; playback reads from processed.
CORS='{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["PUT","GET","HEAD"],"AllowedHeaders":["*"],"ExposeHeaders":["ETag"],"MaxAgeSeconds":3000}]}'
awslocal s3api put-bucket-cors --bucket "$UPLOADS" --cors-configuration "$CORS"
awslocal s3api put-bucket-cors --bucket "$PROCESSED" --cors-configuration "$CORS"

echo "[init] creating queues"
DLQ_URL=$(awslocal sqs create-queue --queue-name video-jobs-dlq --query QueueUrl --output text)
DLQ_ARN=$(awslocal sqs get-queue-attributes --queue-url "$DLQ_URL" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)

cat > /tmp/queue-attrs.json <<EOF
{
  "VisibilityTimeout": "300",
  "RedrivePolicy": "{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"
}
EOF
QUEUE_URL=$(awslocal sqs create-queue --queue-name video-jobs \
  --attributes file:///tmp/queue-attrs.json --query QueueUrl --output text)
QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)

echo "[init] wiring S3 -> SQS notification"
cat > /tmp/notification.json <<EOF
{
  "QueueConfigurations": [{
    "QueueArn": "$QUEUE_ARN",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": {"Key": {"FilterRules": [
      {"Name": "prefix", "Value": "raw/"},
      {"Name": "suffix", "Value": ".mp4"}
    ]}}
  }]
}
EOF
awslocal s3api put-bucket-notification-configuration --bucket "$UPLOADS" \
  --notification-configuration file:///tmp/notification.json

echo "[init] creating DynamoDB table"
awslocal dynamodb create-table --table-name "$TABLE" \
  --attribute-definitions AttributeName=video_id,AttributeType=S \
  --key-schema AttributeName=video_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST >/dev/null

echo "[init] done"
