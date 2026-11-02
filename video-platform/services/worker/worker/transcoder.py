"""FFmpeg helpers: builds and runs the commands to convert videos and extract thumbnails."""

import logging
import subprocess
from pathlib import Path

logger = logging.getLogger("worker.transcoder")

# Resolutions we support: 720p (HD quality) and 480p (standard quality for slower internet)
RENDITIONS = {"720p": 720, "480p": 480}


def rendition_command(input_path: str, output_path: str, height: int) -> list[str]:
    # Build the FFmpeg command to resize and compress the video
    return [
        "ffmpeg", "-y", "-i", input_path,
        # Resize height to 720 or 480; width auto-adjusts to keep the aspect ratio right
        "-vf", f"scale=-2:{height}",
        # Use standard H.264 video codec with fast compression settings
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "28",
        # Use standard AAC audio codec
        "-c:a", "aac",
        # Put metadata at the start of the file so video starts playing instantly in browser
        "-movflags", "+faststart",
        output_path,
    ]  # fmt: skip


def thumbnail_command(input_path: str, output_path: str) -> list[str]:
    # Build the FFmpeg command to grab a preview image (thumbnail)
    return [
        "ffmpeg", "-y", "-i", input_path,
        # Jump to the 1-second mark and grab exactly 1 frame
        "-ss", "00:00:01.000", "-vframes", "1",
        # Resize thumbnail to 640px wide
        "-vf", "scale=640:-1",
        output_path,
    ]  # fmt: skip


def run(cmd: list[str], timeout: int) -> None:
    # Run the FFmpeg command in the terminal; if it fails, throw an error with the last few lines of output
    logger.info("running: %s", " ".join(cmd))
    result = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        tail = result.stderr.strip().splitlines()[-5:]
        raise RuntimeError(f"ffmpeg exited {result.returncode}: {' | '.join(tail)}")


def transcode(input_path: str, out_dir: str, timeout: int) -> dict[str, str]:
    # Convert input video into 720p, 480p, and a thumbnail picture
    out = Path(out_dir)
    files: dict[str, str] = {}

    # 1. Convert video into both 720p and 480p versions
    for name, height in RENDITIONS.items():
        path = str(out / f"{name}.mp4")
        run(rendition_command(input_path, path, height), timeout)
        files[name] = path

    # 2. Grab a thumbnail at 1 second (or frame 0 if video is shorter than 1 second)
    thumb = str(out / "thumb.jpg")
    try:
        run(thumbnail_command(input_path, thumb), timeout)
    except RuntimeError:
        # Very short clip fallback: grab frame right at 0 seconds
        cmd = thumbnail_command(input_path, thumb)
        cmd[cmd.index("-ss") + 1] = "0"
        run(cmd, timeout)
    files["thumbnail"] = thumb

    # Return paths to all generated files
    return files
