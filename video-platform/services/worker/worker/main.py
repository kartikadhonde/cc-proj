"""SQS long-polling worker: transcodes uploaded videos and extracts thumbnails."""

import json
import logging
import shutil
import signal
import time
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import unquote_plus

import boto3

from worker import transcoder
from worker.config import settings

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("worker")

shutting_down = False


def handle_sigterm(signum, frame):
    """Graceful shutdown handler: allows in-progress transcode to finish before Fargate Spot stops."""
    global shutting_down
    logger.info("received signal %s, finishing current job then exiting", signum)
    shutting_down = True


def utc_now() -> str:
    """Return ISO 8601 UTC timestamp string."""
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_message(body: str) -> list[str]:
    """Parse S3 Event Notification from SQS body; filter for ObjectCreated on raw/*.mp4 keys."""
    payload = json.loads(body)
    if payload.get("Event") == "s3:TestEvent":
        return []
    keys = []
    for record in payload.get("Records", []):
        if not record.get("eventName", "").startswith("ObjectCreated"):
            continue
        # Unquote key names (e.g., spaces or special characters encoded by S3)
        key = unquote_plus(record["s3"]["object"]["key"])
        if key.startswith("raw/") and key.endswith(".mp4"):
            keys.append(key)
    return keys


def video_id_from_key(key: str) -> str:
    """Extract UUID video_id from S3 object key (e.g. raw/<video_id>.mp4)."""
    return Path(key).stem


def output_keys(video_id: str) -> dict[str, str]:
    """Define destination S3 keys in the processed bucket for all output renditions."""
    return {
        "720p": f"processed/{video_id}/720p.mp4",
        "480p": f"processed/{video_id}/480p.mp4",
        "thumbnail": f"thumbnails/{video_id}/thumb.jpg",
    }


class Worker:
    def __init__(self, sqs=None, s3=None, table=None):
        kw = {"region_name": settings.aws_region, "endpoint_url": settings.aws_endpoint_url}
        self.sqs = sqs or boto3.client("sqs", **kw)
        self.s3 = s3 or boto3.client("s3", **kw)
        self.table = table or boto3.resource("dynamodb", **kw).Table(settings.ddb_table)

    def poll_once(self) -> None:
        """Poll SQS using 20s Long Polling to minimize empty receive API calls and costs."""
        response = self.sqs.receive_message(
            QueueUrl=settings.sqs_queue_url,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=20,
        )
        for message in response.get("Messages", []):
            self.handle_message(message)

    def handle_message(self, message: dict) -> None:
        """Process SQS message; only delete receipt handle after successful database commit."""
        receipt = message["ReceiptHandle"]
        try:
            keys = parse_message(message["Body"])
        except (json.JSONDecodeError, KeyError, TypeError):
            logger.warning("discarding malformed message %s", message.get("MessageId"))
            self.delete(receipt)
            return

        try:
            for key in keys:
                self.process(key)
        except Exception as exc:  # any failure must be recorded, not crash the loop
            # Leave the message on the queue: SQS redelivers after the visibility timeout
            # and moves it to the DLQ after maxReceiveCount attempts.
            logger.exception("job failed for %s", keys)
            for key in keys:
                self.mark_failed(video_id_from_key(key), str(exc))
            return
        # Delete from SQS only when transcoding & DynamoDB updates succeeded
        self.delete(receipt)

    def process(self, source_key: str) -> None:
        """Download raw video, execute FFmpeg renditions, upload outputs, and update DynamoDB."""
        video_id = video_id_from_key(source_key)

        # 1. Idempotency guard: skip if video was already marked ready by a previous run
        item = self.table.get_item(Key={"video_id": video_id}).get("Item")
        if item and item.get("status") == "ready":
            logger.info("video %s already ready, skipping duplicate delivery", video_id)
            return

        # 2. Atomic DynamoDB state transition: set status to 'processing' and increment attempts
        self.table.update_item(
            Key={"video_id": video_id},
            UpdateExpression=(
                "SET #s = :s, updated_at = :u, source_key = :k, #e = :null "
                "ADD attempts :one"
            ),
            ExpressionAttributeNames={"#s": "status", "#e": "error"},
            ExpressionAttributeValues={
                ":s": "processing", ":u": utc_now(), ":k": source_key, ":null": None, ":one": 1,
            },
        )  # fmt: skip
        logger.info("processing video %s", video_id)

        job_dir = Path(settings.work_dir) / video_id
        job_dir.mkdir(parents=True, exist_ok=True)
        try:
            # 3. Download raw MP4 from uploads bucket
            input_path = str(job_dir / "input.mp4")
            self.s3.download_file(settings.uploads_bucket, source_key, input_path)

            # 4. Transcode to 720p, 480p, and extract thumbnail
            files = transcoder.transcode(input_path, str(job_dir), settings.ffmpeg_timeout_seconds)

            # 5. Upload renditions to processed S3 bucket with correct Content-Type headers
            keys = output_keys(video_id)
            for name, path in files.items():
                content_type = "image/jpeg" if name == "thumbnail" else "video/mp4"
                self.s3.upload_file(
                    path, settings.processed_bucket, keys[name],
                    ExtraArgs={"ContentType": content_type},
                )  # fmt: skip

            # 6. Atomic DynamoDB state transition: mark 'ready' with CloudFront output keys
            self.table.update_item(
                Key={"video_id": video_id},
                UpdateExpression="SET #s = :s, outputs = :o, thumbnail_key = :t, updated_at = :u",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={
                    ":s": "ready",
                    ":o": {"720p": keys["720p"], "480p": keys["480p"]},
                    ":t": keys["thumbnail"],
                    ":u": utc_now(),
                },
            )
            logger.info("video %s ready", video_id)
        finally:
            # 7. Clean up temporary scratch files from container disk
            shutil.rmtree(job_dir, ignore_errors=True)

    def mark_failed(self, video_id: str, error: str) -> None:
        """Record transcode failure reason in DynamoDB for frontend error display."""
        try:
            self.table.update_item(
                Key={"video_id": video_id},
                UpdateExpression="SET #s = :s, #e = :e, updated_at = :u",
                ExpressionAttributeNames={"#s": "status", "#e": "error"},
                ExpressionAttributeValues={":s": "failed", ":e": error[:1000], ":u": utc_now()},
            )
        except Exception:
            logger.exception("could not mark video %s as failed", video_id)

    def delete(self, receipt: str) -> None:
        """Acknowledge and remove message from SQS queue."""
        self.sqs.delete_message(QueueUrl=settings.sqs_queue_url, ReceiptHandle=receipt)


def main() -> None:
    # Register graceful shutdown signals (SIGTERM from ECS/Fargate Spot, SIGINT from Ctrl+C)
    signal.signal(signal.SIGTERM, handle_sigterm)
    signal.signal(signal.SIGINT, handle_sigterm)
    if not settings.sqs_queue_url:
        raise SystemExit("SQS_QUEUE_URL is not set")

    worker = Worker()
    logger.info("worker started, polling %s", settings.sqs_queue_url)
    while not shutting_down:
        try:
            worker.poll_once()
        except Exception:  # transient AWS errors should not kill the worker
            logger.exception("poll failed, retrying in 5s")
            time.sleep(5)
    logger.info("worker stopped")


if __name__ == "__main__":
    main()
