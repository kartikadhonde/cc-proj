"""Runtime configuration for the API service, read from environment variables."""

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
    ddb_table: str = _env("DDB_TABLE", "video-platform-videos")
    uploads_bucket: str = _env("UPLOADS_BUCKET", "video-platform-uploads")
    cloudfront_domain: str = _env("CLOUDFRONT_DOMAIN", "")
    # Optional: custom endpoint for all AWS calls (LocalStack inside docker-compose).
    aws_endpoint_url: str | None = _opt("AWS_ENDPOINT_URL")
    # Optional: endpoint the *browser* uses for presigned uploads (LocalStack via localhost).
    s3_public_endpoint_url: str | None = _opt("S3_PUBLIC_ENDPOINT_URL")
    # Optional: overrides https://{CLOUDFRONT_DOMAIN} as the base for playback URLs.
    media_base_url: str | None = _opt("MEDIA_BASE_URL")
    presign_expiry_seconds: int = 900

    @property
    def media_base(self) -> str:
        if self.media_base_url:
            return self.media_base_url.rstrip("/")
        return f"https://{self.cloudfront_domain}"


settings = Settings()
