import json
from unittest.mock import MagicMock, patch

from worker import transcoder
from worker.main import Worker, output_keys, parse_message, video_id_from_key

VIDEO_ID = "550e8400-e29b-41d4-a716-446655440000"


def s3_event(key: str, event_name: str = "ObjectCreated:Put") -> str:
    return json.dumps(
        {
            "Records": [
                {
                    "eventName": event_name,
                    "s3": {"bucket": {"name": "uploads"}, "object": {"key": key}},
                }
            ]
        }
    )


def test_parse_message_extracts_raw_key():
    assert parse_message(s3_event(f"raw/{VIDEO_ID}.mp4")) == [f"raw/{VIDEO_ID}.mp4"]


def test_parse_message_skips_test_event():
    body = json.dumps({"Service": "Amazon S3", "Event": "s3:TestEvent", "Bucket": "uploads"})
    assert parse_message(body) == []


def test_parse_message_ignores_other_prefixes_and_events():
    assert parse_message(s3_event("other/file.mp4")) == []
    assert parse_message(s3_event(f"raw/{VIDEO_ID}.mp4", "ObjectRemoved:Delete")) == []


def test_parse_message_url_decodes_key():
    assert parse_message(s3_event("raw/my+clip%281%29.mp4")) == ["raw/my clip(1).mp4"]


def test_video_id_and_output_keys():
    assert video_id_from_key(f"raw/{VIDEO_ID}.mp4") == VIDEO_ID
    assert output_keys(VIDEO_ID) == {
        "720p": f"processed/{VIDEO_ID}/720p.mp4",
        "480p": f"processed/{VIDEO_ID}/480p.mp4",
        "thumbnail": f"thumbnails/{VIDEO_ID}/thumb.jpg",
    }


def test_rendition_command():
    cmd = transcoder.rendition_command("/tmp/in.mp4", "/tmp/720p.mp4", 720)
    assert cmd[:4] == ["ffmpeg", "-y", "-i", "/tmp/in.mp4"]
    assert cmd[cmd.index("-vf") + 1] == "scale=-2:720"
    assert cmd[cmd.index("-c:v") + 1] == "libx264"
    assert cmd[cmd.index("-preset") + 1] == "veryfast"
    assert cmd[cmd.index("-crf") + 1] == "28"
    assert cmd[cmd.index("-c:a") + 1] == "aac"
    assert cmd[-1] == "/tmp/720p.mp4"


def test_thumbnail_command():
    cmd = transcoder.thumbnail_command("/tmp/in.mp4", "/tmp/thumb.jpg")
    assert cmd[cmd.index("-ss") + 1] == "00:00:01.000"
    assert cmd[cmd.index("-vframes") + 1] == "1"
    assert cmd[cmd.index("-vf") + 1] == "scale=640:-1"
    assert cmd[-1] == "/tmp/thumb.jpg"


def make_worker(item=None):
    table = MagicMock()
    table.get_item.return_value = {"Item": item} if item else {}
    return Worker(sqs=MagicMock(), s3=MagicMock(), table=table)


def message(body: str) -> dict:
    return {"MessageId": "m1", "ReceiptHandle": "r1", "Body": body}


def test_ready_video_is_skipped_and_message_deleted():
    worker = make_worker({"video_id": VIDEO_ID, "status": "ready"})
    worker.handle_message(message(s3_event(f"raw/{VIDEO_ID}.mp4")))

    worker.table.update_item.assert_not_called()
    worker.s3.download_file.assert_not_called()
    worker.sqs.delete_message.assert_called_once()


def test_test_event_is_deleted():
    worker = make_worker()
    worker.handle_message(message(json.dumps({"Event": "s3:TestEvent"})))
    worker.sqs.delete_message.assert_called_once()


@patch("worker.main.transcoder.transcode")
def test_successful_job_uploads_outputs_and_marks_ready(mock_transcode, tmp_path, monkeypatch):
    monkeypatch.setattr("worker.main.settings", _settings(tmp_path))
    mock_transcode.return_value = {
        "720p": "/x/720p.mp4",
        "480p": "/x/480p.mp4",
        "thumbnail": "/x/thumb.jpg",
    }
    worker = make_worker({"video_id": VIDEO_ID, "status": "uploaded"})

    worker.handle_message(message(s3_event(f"raw/{VIDEO_ID}.mp4")))

    uploaded = {c.args[2] for c in worker.s3.upload_file.call_args_list}
    assert uploaded == set(output_keys(VIDEO_ID).values())
    final = worker.table.update_item.call_args_list[-1].kwargs
    assert final["ExpressionAttributeValues"][":s"] == "ready"
    worker.sqs.delete_message.assert_called_once()
    assert not (tmp_path / VIDEO_ID).exists()


@patch("worker.main.transcoder.transcode", side_effect=RuntimeError("ffmpeg exited 1"))
def test_failed_job_marks_failed_and_keeps_message(mock_transcode, tmp_path, monkeypatch):
    monkeypatch.setattr("worker.main.settings", _settings(tmp_path))
    worker = make_worker({"video_id": VIDEO_ID, "status": "uploaded"})

    worker.handle_message(message(s3_event(f"raw/{VIDEO_ID}.mp4")))

    final = worker.table.update_item.call_args_list[-1].kwargs
    assert final["ExpressionAttributeValues"][":s"] == "failed"
    assert final["ExpressionAttributeValues"][":e"] == "ffmpeg exited 1"
    worker.sqs.delete_message.assert_not_called()


def _settings(tmp_path):
    from worker.config import Settings

    return Settings(work_dir=str(tmp_path), sqs_queue_url="https://sqs/queue")
