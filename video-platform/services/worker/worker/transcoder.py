"""FFmpeg command construction and execution."""

import logging
import subprocess
from pathlib import Path

logger = logging.getLogger("worker.transcoder")

# Multi-resolution streaming targets: 720p (HD) and 480p (SD standard)
RENDITIONS = {"720p": 720, "480p": 480}


def rendition_command(input_path: str, output_path: str, height: int) -> list[str]:
    """Construct FFmpeg command for H.264 video transcoding with web optimization."""
    return [
        "ffmpeg", "-y", "-i", input_path,
        # scale=-2 maintains aspect ratio while ensuring width is divisible by 2 for H.264
        "-vf", f"scale=-2:{height}",
        # veryfast preset reduces Fargate Spot CPU runtime; CRF 28 provides efficient web streaming quality
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "28",
        "-c:a", "aac",
        # +faststart shifts moov metadata atom to the start so browser playback starts immediately
        "-movflags", "+faststart",
        output_path,
    ]  # fmt: skip


def thumbnail_command(input_path: str, output_path: str) -> list[str]:
    """Construct FFmpeg command to extract a single video frame as a JPEG thumbnail."""
    return [
        "ffmpeg", "-y", "-i", input_path,
        # Fast-seek to 1s mark and grab 1 frame scaled to 640px width (preserving aspect ratio)
        "-ss", "00:00:01.000", "-vframes", "1",
        "-vf", "scale=640:-1",
        output_path,
    ]  # fmt: skip


def run(cmd: list[str], timeout: int) -> None:
    """Execute FFmpeg CLI command with strict timeout and stderr error capture."""
    logger.info("running: %s", " ".join(cmd))
    result = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        tail = result.stderr.strip().splitlines()[-5:]
        raise RuntimeError(f"ffmpeg exited {result.returncode}: {' | '.join(tail)}")


def transcode(input_path: str, out_dir: str, timeout: int) -> dict[str, str]:
    """Produce 720p/480p MP4s and a JPEG thumbnail. Returns {name: local_path}."""
    out = Path(out_dir)
    files: dict[str, str] = {}

    # 1. Encode video into each resolution rendition
    for name, height in RENDITIONS.items():
        path = str(out / f"{name}.mp4")
        run(rendition_command(input_path, path, height), timeout)
        files[name] = path

    # 2. Extract thumbnail (with 0s fallback if video is shorter than 1 second)
    thumb = str(out / "thumb.jpg")
    try:
        run(thumbnail_command(input_path, thumb), timeout)
    except RuntimeError:
        # Clips shorter than 1s have no frame at 00:00:01; fall back to the first frame.
        cmd = thumbnail_command(input_path, thumb)
        cmd[cmd.index("-ss") + 1] = "0"
        run(cmd, timeout)
    files["thumbnail"] = thumb
    return files
