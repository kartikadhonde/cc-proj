"""Boto3 helpers: DynamoDB CRUD and S3 presigned upload URLs."""

from datetime import UTC, datetime
from decimal import Decimal
from functools import lru_cache
from typing import Any

import boto3
from botocore.config import Config

from app.config import settings


@lru_cache
def _ddb_table():
    resource = boto3.resource(
        "dynamodb", region_name=settings.aws_region, endpoint_url=settings.aws_endpoint_url
    )
    return resource.Table(settings.ddb_table)


@lru_cache
def _presign_client():
    # Presigned URLs are opened by the browser, so they must point at an endpoint the
    # browser can reach. On AWS that is the regional virtual-hosted endpoint (avoids the
    # 307 redirect that breaks CORS preflight on new buckets); locally it is LocalStack.
    if settings.s3_public_endpoint_url or settings.aws_endpoint_url:
        endpoint = settings.s3_public_endpoint_url or settings.aws_endpoint_url
        addressing = "path"
    else:
        endpoint = f"https://s3.{settings.aws_region}.amazonaws.com"
        addressing = "virtual"
    return boto3.client(
        "s3",
        region_name=settings.aws_region,
        endpoint_url=endpoint,
        config=Config(signature_version="s3v4", s3={"addressing_style": addressing}),
    )


def utc_now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _plain(value: Any) -> Any:
    """Convert DynamoDB Decimals into ints/floats so the item is JSON-friendly."""
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_plain(v) for v in value]
    return value


def put_video(item: dict[str, Any]) -> None:
    _ddb_table().put_item(Item=item)


def get_video(video_id: str) -> dict[str, Any] | None:
    response = _ddb_table().get_item(Key={"video_id": video_id})
    item = response.get("Item")
    return _plain(item) if item else None


def list_videos() -> list[dict[str, Any]]:
    table = _ddb_table()
    items: list[dict[str, Any]] = []
    kwargs: dict[str, Any] = {}
    while True:
        response = table.scan(**kwargs)
        items.extend(_plain(i) for i in response.get("Items", []))
        if "LastEvaluatedKey" not in response:
            return items
        kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]


def presigned_upload_url(key: str) -> str:
    return _presign_client().generate_presigned_url(
        "put_object",
        Params={"Bucket": settings.uploads_bucket, "Key": key, "ContentType": "video/mp4"},
        ExpiresIn=settings.presign_expiry_seconds,
    )
