"""FastAPI entrypoint for the video platform API.

Routes are served both at the root (used by the ALB health check and local dev) and
under /api (used by the frontend through CloudFront, so the page and API share one
HTTPS origin and the browser never makes a mixed-content request).
"""

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
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

router = APIRouter()


def with_urls(item: dict[str, Any]) -> dict[str, Any]:
    """Attach full CloudFront URLs for ready videos."""
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
    return HealthResponse(status="healthy")


@router.post("/videos", response_model=CreateVideoResponse, status_code=201)
def create_video(body: CreateVideoRequest) -> CreateVideoResponse:
    video_id = str(uuid.uuid4())
    source_key = f"raw/{video_id}.mp4"
    now = aws.utc_now()
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
    upload_url = aws.presigned_upload_url(source_key)
    logger.info("created video %s", video_id)
    return CreateVideoResponse(video_id=video_id, upload_url=upload_url)


@router.get("/videos", response_model=list[Video])
def list_videos() -> list[dict[str, Any]]:
    items = aws.list_videos()
    items.sort(key=lambda i: i.get("created_at", ""), reverse=True)
    return [with_urls(i) for i in items]


@router.get("/videos/{video_id}", response_model=Video)
def get_video(video_id: str) -> dict[str, Any]:
    item = aws.get_video(video_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Video not found")
    return with_urls(item)


app.include_router(router)
app.include_router(router, prefix="/api")
