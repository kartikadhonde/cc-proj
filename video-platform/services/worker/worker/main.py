"""Background worker: listens for uploaded videos in SQS, converts them, and saves the output."""

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

# Flag to stop the worker loop gracefully
shutting_down = False


def handle_sigterm(signum, frame):
    # When AWS tells the server to shut down, don't crash mid-video - finish the current video first
    global shutting_down
    logger.info("received signal %s, finishing current job then exiting", signum)
    shutting_down = True


def utc_now() -> str:
    # Get current time in standard UTC format (e.g. 2026-11-02T10:00:00Z)
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_message(body: str) -> list[str]:
    # Read the SQS message and check if it's a new video upload from S3 (ignores test pings)
    payload = json.loads(body)
    if payload.get("Event") == "s3:TestEvent":
        return []
    keys = []
    for record in payload.get("Records", []):
        if not record.get("eventName", "").startswith("ObjectCreated"):
            continue
        # Decode special characters in the filename (e.g. spaces or brackets)
        key = unquote_plus(record["s3"]["object"]["key"])
        # Only process MP4 files uploaded to the "raw/" folder
        if key.startswith("raw/") and key.endswith(".mp4"):
            keys.append(key)
    return keys


def video_id_from_key(key: str) -> str:
    # Grab the unique video ID from the file path (e.g. "raw/abc-123.mp4" -> "abc-123")
    return Path(key).stem


def output_keys(video_id: str) -> dict[str, str]:
    # File paths where the converted videos and thumbnail will be stored in S3
    return {
        "720p": f"processed/{video_id}/720p.mp4",
        "480p": f"processed/{video_id}/480p.mp4",
        "thumbnail": f"thumbnails/{video_id}/thumb.jpg",
    }


class Worker:
    def __init__(self, sqs=None, s3=None, table=None):
        # Connect to AWS services (SQS queue, S3 storage, and DynamoDB database)
        kw = {"region_name": settings.aws_region, "endpoint_url": settings.aws_endpoint_url}
        self.sqs = sqs or boto3.client("sqs", **kw)
        self.s3 = s3 or boto3.client("s3", **kw)
        self.table = table or boto3.resource("dynamodb", **kw).Table(settings.ddb_table)

    def poll_once(self) -> None:
        # Wait up to 20 seconds for a new video job to arrive (long polling saves money by reducing empty checks)
        response = self.sqs.receive_message(
            QueueUrl=settings.sqs_queue_url,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=20,
        )
        for message in response.get("Messages", []):
            self.handle_message(message)

    def handle_message(self, message: dict) -> None:
        # Take a job from the queue, process it, and only remove it if everything succeeds
        receipt = message["ReceiptHandle"]
        try:
            keys = parse_message(message["Body"])
        except (json.JSONDecodeError, KeyError, TypeError):
            # If message is corrupted/garbage, drop it so it doesn't get stuck forever
            logger.warning("discarding malformed message %s", message.get("MessageId"))
            self.delete(receipt)
            return

        try:
            for key in keys:
                self.process(key)
        except Exception as exc:
            # If conversion fails, mark as failed in the database and leave it in SQS for automatic retry
            logger.exception("job failed for %s", keys)
            for key in keys:
                self.mark_failed(video_id_from_key(key), str(exc))
            return

        # Done! Now safely delete the message from the queue
        self.delete(receipt)

    def process(self, source_key: str) -> None:
        # The main pipeline: download -> convert -> upload -> update database
        video_id = video_id_from_key(source_key)

        # Step 1: If video was already converted earlier, skip it (handles duplicate messages)
        item = self.table.get_item(Key={"video_id": video_id}).get("Item")
        if item and item.get("status") == "ready":
            logger.info("video %s already ready, skipping duplicate delivery", video_id)
            return

        # Step 2: Update status to "processing" in DynamoDB so frontend shows a loading spinner
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

        # Temporary folder on the server to work with the video files
        job_dir = Path(settings.work_dir) / video_id
        job_dir.mkdir(parents=True, exist_ok=True)
        try:
            # Step 3: Download the original uploaded video from S3
            input_path = str(job_dir / "input.mp4")
            self.s3.download_file(settings.uploads_bucket, source_key, input_path)

            # Step 4: Convert the video into 720p, 480p, and snap a thumbnail image
            files = transcoder.transcode(input_path, str(job_dir), settings.ffmpeg_timeout_seconds)

            # Step 5: Upload the converted videos and thumbnail back to S3
            keys = output_keys(video_id)
            for name, path in files.items():
                content_type = "image/jpeg" if name == "thumbnail" else "video/mp4"
                self.s3.upload_file(
                    path, settings.processed_bucket, keys[name],
                    ExtraArgs={"ContentType": content_type},
                )  # fmt: skip

            # Step 6: Mark status as "ready" in DynamoDB with the new stream links
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
            # Step 7: Delete temporary files from disk to keep the server clean
            shutil.rmtree(job_dir, ignore_errors=True)

    def mark_failed(self, video_id: str, error: str) -> None:
        # If conversion broke, save the error in DynamoDB so user sees why it failed
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
        # Remove the finished job from SQS so no other worker picks it up
        self.sqs.delete_message(QueueUrl=settings.sqs_queue_url, ReceiptHandle=receipt)


def main() -> None:
    # Listen for stop signals (like Ctrl+C or AWS shutdown)
    signal.signal(signal.SIGTERM, handle_sigterm)
    signal.signal(signal.SIGINT, handle_sigterm)
    if not settings.sqs_queue_url:
        raise SystemExit("SQS_QUEUE_URL is not set")

    worker = Worker()
    logger.info("worker started, polling %s", settings.sqs_queue_url)
    # Main loop: keep checking for new video jobs until told to stop
    while not shutting_down:
        try:
            worker.poll_once()
        except Exception:
            # If AWS has a quick hiccup, wait 5 seconds and try again instead of crashing
            logger.exception("poll failed, retrying in 5s")
            time.sleep(5)
    logger.info("worker stopped")


if __name__ == "__main__":
    main()
