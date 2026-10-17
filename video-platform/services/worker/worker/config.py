"""Runtime configuration for the worker, read from environment variables."""

import os
from dataclasses import dataclass, field


def _env(name: str, default: str = ""):
    return field(default_factory=lambda: os.getenv(name, default))


def _optional(name: str) -> str | None:
    value = os.getenv(name, "").strip()
    return value or None


def _opt(name: str):
    return field(default_factory=lambda: _optional(name))


@dataclass(frozen=True)
class Settings:
    aws_region: str = _env("AWS_REGION", "ap-south-1")
    sqs_queue_url: str = _env("SQS_QUEUE_URL", "")
    ddb_table: str = _env("DDB_TABLE", "video-platform-videos")
    uploads_bucket: str = _env("UPLOADS_BUCKET", "video-platform-uploads")
    processed_bucket: str = _env("PROCESSED_BUCKET", "video-platform-processed")
    # Optional: custom endpoint for all AWS calls (LocalStack inside docker-compose).
    aws_endpoint_url: str | None = _opt("AWS_ENDPOINT_URL")
    work_dir: str = _env("WORK_DIR", "/tmp")
    ffmpeg_timeout_seconds: int = field(
        default_factory=lambda: int(os.getenv("FFMPEG_TIMEOUT_SECONDS", "280"))
    )


settings = Settings()
