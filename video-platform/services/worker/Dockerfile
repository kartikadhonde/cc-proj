# --- Build stage: install Python dependencies into an isolated virtualenv ---
FROM python:3.11-slim AS builder
WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && pip install --no-cache-dir -r requirements.txt

# --- Runtime stage: slim image with FFmpeg, non-root user ---
FROM python:3.11-slim
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 workeruser
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY worker ./worker
USER workeruser
CMD ["python", "-m", "worker.main"]
