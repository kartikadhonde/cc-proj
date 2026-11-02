"""FastAPI backend: handles video uploads, metadata, and listing videos."""

import logging
import uuid
from typing import Any

from fastapi import APIRouter, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from app import aws
from app.config import settings
from app.models import CreateVideoRequest, CreateVideoResponse, HealthResponse, Video

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("api")

app = FastAPI(title="Video Platform API", version="1.0.0")

# Allow the frontend website to make requests to this backend without CORS blocks
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

router = APIRouter()


def with_urls(item: dict[str, Any]) -> dict[str, Any]:
    # Attach fast CloudFront CDN streaming links for ready videos so browser can play them
    item = dict(item)
    item.setdefault("outputs", {})
    if item.get("status") == "ready":
        item["playback_urls"] = {
            res: f"{settings.media_base}/{key}" for res, key in item["outputs"].items()
        }
        if item.get("thumbnail_key"):
            item["thumbnail_url"] = f"{settings.media_base}/{item['thumbnail_key']}"
    return item


@router.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    # Health check: AWS load balancer pings this to see if our backend is alive and healthy
    return HealthResponse(status="healthy")


@router.post("/videos", response_model=CreateVideoResponse, status_code=201)
def create_video(body: CreateVideoRequest) -> CreateVideoResponse:
    # 1. Create a unique ID for the new video
    video_id = str(uuid.uuid4())
    source_key = f"raw/{video_id}.mp4"
    now = aws.utc_now()

    # 2. Save the video entry into DynamoDB database with status "uploaded"
    aws.put_video(
        {
            "video_id": video_id,
            "title": body.title,
            "status": "uploaded",
            "source_key": source_key,
            "outputs": {},
            "thumbnail_key": None,
            "attempts": 0,
            "error": None,
            "created_at": now,
            "updated_at": now,
        }
    )

    # 3. Create a temporary upload link so the browser can upload straight to S3
    upload_url = aws.presigned_upload_url(source_key)
    logger.info("created video %s", video_id)
    return CreateVideoResponse(video_id=video_id, upload_url=upload_url)


@router.get("/videos", response_model=list[Video])
def list_videos() -> list[dict[str, Any]]:
    # Get all videos from DynamoDB, showing newest uploads first
    items = aws.list_videos()
    items.sort(key=lambda i: i.get("created_at", ""), reverse=True)
    return [with_urls(i) for i in items]


@router.get("/videos/{video_id}", response_model=Video)
def get_video(video_id: str) -> dict[str, Any]:
    # Look up a specific video by its ID
    item = aws.get_video(video_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Video not found")
    return with_urls(item)


# Serve routes both at root and with /api prefix (for CloudFront routing)
app.include_router(router)
app.include_router(router, prefix="/api")
