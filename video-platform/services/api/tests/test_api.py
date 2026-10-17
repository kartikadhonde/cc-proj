from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app

client = TestClient(app)


@pytest.mark.parametrize("path", ["/health", "/api/health"])
def test_health(path):
    response = client.get(path)
    assert response.status_code == 200
    assert response.json() == {"status": "healthy"}


@patch("app.main.aws.presigned_upload_url", return_value="https://example.com/signed")
@patch("app.main.aws.put_video")
def test_create_video(mock_put, mock_presign):
    response = client.post("/videos", json={"title": "My Video"})

    assert response.status_code == 201
    body = response.json()
    assert body["upload_url"] == "https://example.com/signed"

    item = mock_put.call_args.args[0]
    assert item["video_id"] == body["video_id"]
    assert item["title"] == "My Video"
    assert item["status"] == "uploaded"
    assert item["source_key"] == f"raw/{body['video_id']}.mp4"
    assert item["outputs"] == {}
    assert item["attempts"] == 0
    mock_presign.assert_called_once_with(f"raw/{body['video_id']}.mp4")


def test_create_video_rejects_empty_title():
    response = client.post("/videos", json={"title": ""})
    assert response.status_code == 422


def _item(video_id, status, created_at, **extra):
    item = {
        "video_id": video_id,
        "title": f"Video {video_id}",
        "status": status,
        "source_key": f"raw/{video_id}.mp4",
        "outputs": {},
        "thumbnail_key": None,
        "attempts": 0,
        "error": None,
        "created_at": created_at,
        "updated_at": created_at,
    }
    item.update(extra)
    return item


@patch("app.main.aws.list_videos")
def test_list_videos_sorted_with_urls(mock_list):
    mock_list.return_value = [
        _item("old", "uploaded", "2026-10-17T10:00:00Z"),
        _item(
            "new",
            "ready",
            "2026-10-17T11:00:00Z",
            outputs={"720p": "processed/new/720p.mp4", "480p": "processed/new/480p.mp4"},
            thumbnail_key="thumbnails/new/thumb.jpg",
            attempts=1,
        ),
    ]

    response = client.get("/api/videos")

    assert response.status_code == 200
    videos = response.json()
    assert [v["video_id"] for v in videos] == ["new", "old"]
    base = settings.media_base
    assert videos[0]["playback_urls"] == {
        "720p": f"{base}/processed/new/720p.mp4",
        "480p": f"{base}/processed/new/480p.mp4",
    }
    assert videos[0]["thumbnail_url"] == f"{base}/thumbnails/new/thumb.jpg"
    assert videos[1]["playback_urls"] == {}
    assert videos[1]["thumbnail_url"] is None


@patch("app.main.aws.get_video", return_value=None)
def test_get_video_not_found(mock_get):
    response = client.get("/videos/missing")
    assert response.status_code == 404
