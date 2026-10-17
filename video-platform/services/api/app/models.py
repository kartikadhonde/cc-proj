"""Pydantic request/response schemas."""

from typing import Literal

from pydantic import BaseModel, Field

VideoStatus = Literal["uploaded", "processing", "ready", "failed"]


class CreateVideoRequest(BaseModel):
    title: str = Field(..., min_length=1, max_length=200)


class CreateVideoResponse(BaseModel):
    video_id: str
    upload_url: str


class HealthResponse(BaseModel):
    status: str


class Video(BaseModel):
    video_id: str
    title: str = "Untitled"
    status: VideoStatus
    source_key: str
    outputs: dict[str, str] = Field(default_factory=dict)
    thumbnail_key: str | None = None
    attempts: int = 0
    error: str | None = None
    created_at: str = ""
    updated_at: str = ""
    playback_urls: dict[str, str] = Field(default_factory=dict)
    thumbnail_url: str | None = None
