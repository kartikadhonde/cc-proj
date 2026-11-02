# Member 4 Comprehensive Technical Defense Guide: Video Transcoding, Distributed Systems & DevSecOps CI/CD (A to Z)

**Role Title:** Transcoding, Distributed Systems & DevSecOps CI/CD Lead (Member 4)  
**Project:** StreamForge — Cloud-Based Video Upload, Transcoding, and Streaming Platform  
**Target Architecture:** Event-Driven Serverless Microservices on AWS  
**Active Production CloudFront URL:** [https://d31pege4389vaq.cloudfront.net](https://d31pege4389vaq.cloudfront.net)  
**Target Repository:** `kartikadhonde/cc-proj` (Branch: `main`)  

---

## Table of Contents
1. [Executive Summary & Role Identity](#1-executive-summary--role-identity)
2. [End-to-End System Architecture (Member 4 Subsystems)](#2-end-to-end-system-architecture-member-4-subsystems)
3. [Deep Dive into Worker Source Code (Line-by-Line)](#3-deep-dive-into-worker-source-code-line-by-line)
   - [3.1 `transcoder.py` — FFmpeg Execution & Parameters](#31-transcoderpy--ffmpeg-execution--parameters)
   - [3.2 `main.py` — SQS Long-Polling & Lifecycle Daemon](#32-mainpy--sqs-long-polling--lifecycle-daemon)
   - [3.3 `config.py` — Pydantic Settings](#33-configpy--pydantic-settings)
   - [3.4 `Dockerfile` — Multi-Stage Non-Root Build](#34-dockerfile--multi-stage-non-root-build)
   - [3.5 `tests/test_worker.py` — Pytest & Moto Mocks](#35-teststest_workerpy--pytest--moto-mocks)
4. [Infrastructure as Code (Terraform)](#4-infrastructure-as-code-terraform)
   - [4.1 `sqs.tf` — Queues, Redrive & Dead-Letter Queue (DLQ)](#41-sqstf--queues-redrive--dead-letter-queue-dlq)
   - [4.2 `autoscaling.tf` — Scale from 0 to 3 on Queue Backlog](#42-autoscalingtf--scale-from-0-to-3-on-queue-backlog)
   - [4.3 `ecs.tf` — Fargate Spot Strategy & Graceful Drain](#43-ecstf--fargate-spot-strategy--graceful-drain)
5. [Automated DevSecOps CI/CD Pipelines (GitHub Actions)](#5-automated-devsecops-cicd-pipelines-github-actions)
   - [5.1 `ci-deploy.yml` — Smart Filtering, Trivy, ECR & Rolling Deployment](#51-ci-deployyml--smart-filtering-trivy-ecr--rolling-deployment)
   - [5.2 `rollback.yml` — One-Click Instant Reversion](#52-rollbackyml--one-click-instant-reversion)
   - [5.3 `infra.yml` — Terraform IaC Automated Guardrails](#53-infrayml--terraform-iac-automated-guardrails)
6. [Live Presentation Script & Demonstration Playbook](#6-live-presentation-script--demonstration-playbook)
7. [Exhaustive Viva & Defense Question Bank (With Model Answers)](#7-exhaustive-viva--defense-question-bank-with-model-answers)

---

## 1. Executive Summary & Role Identity

As **Member 4**, your domain is the engine room and delivery highway of StreamForge:
1. **The Transcoding Core:** You built the background multimedia processing pipeline that converts heavy, unoptimized raw video uploads into dual-rendition (`720p` HD and `480p` SD) streaming formats with extracted JPEG thumbnails.
2. **Distributed Systems Decoupling:** You eliminated server bottlenecks by integrating an asynchronous, event-driven architecture using **Amazon S3 Event Notifications** and **Amazon Simple Queue Service (SQS)** with Dead-Letter Queue (DLQ) isolation.
3. **Elastic Cost Optimization:** You architected serverless compute on **AWS ECS Fargate Spot** (achieving a ~70% cost reduction) and configured dynamic **Application Auto Scaling (0 to 3 workers)** that scales down to zero when idle.
4. **DevSecOps & CI/CD Automation:** You engineered the automated **GitHub Actions** deployment pipeline featuring static code analysis (Ruff), automated unit testing (Pytest), container security vulnerability scanning (Aqua Security Trivy), zero-downtime rolling updates, and automated rollback triggers.

### Your 30-Second Elevator Pitch
> *"I am the Transcoding, Distributed Systems, and CI/CD Lead for StreamForge. Video encoding is extremely CPU-intensive; running it on an API server would freeze the entire platform. I solved this by building an asynchronous worker daemon decoupled via Amazon SQS. My engine runs FFmpeg to produce optimized 720p and 480p streaming files with `+faststart` for instant playback and automated JPEG thumbnail extraction. To minimize AWS cloud costs, I engineered auto-scaling from 0 to 3 workers running on Fargate Spot at a 70% discount. Finally, I authored our GitHub Actions DevSecOps pipeline with automated Trivy vulnerability scanning, ensuring secure, zero-downtime deployments."*

---

## 2. End-to-End System Architecture (Member 4 Subsystems)

The following diagram illustrates every component you own and how data flows through your subsystems:

```
[ User Browser ]
       │
       ▼ (Direct Binary PUT via Presigned URL)
[ S3: video-platform-uploads-242201307132 ]
       │
       ▼ (s3:ObjectCreated:* Event Notification)
[ Amazon SQS: video-jobs ] ◄── (Queue Depth Alarm: visible >= 1) ──► [ CloudWatch Metric Alarm ]
       │                                                                      │
       ▼ (WaitTimeSeconds = 20 Long-Polling)                                  ▼ (Triggers Step Scaling)
[ ECS Fargate Spot: video-platform-worker ] ◄──────────────────── [ AWS Application Auto Scaling ]
       │                                                                  (0 -> 1 -> 2 -> 3 tasks)
       ├──► 1. Checks DynamoDB (Idempotency: skip if already "ready")
       ├──► 2. Sets DynamoDB status = "processing", attempts += 1
       ├──► 3. Downloads raw MP4 to isolated scratch folder /tmp/{video_id}
       ├──► 4. Executes FFmpeg:
       │        ├── 720p (1280x720, libx264, preset=veryfast, crf=28, +faststart)
       │        ├── 480p (854x480,  libx264, preset=veryfast, crf=28, +faststart)
       │        └── Thumbnail (640px JPEG at 1.0s or frame 0)
       ├──► 5. Uploads renditions to S3: video-platform-processed-242201307132
       ├──► 6. Updates DynamoDB status = "ready", sets playback URLs
       ├──► 7. Deletes SQS message (ReceiptHandle)
       └──► 8. Purges temporary scratch directory
       │
[ If 3 Crashes Occur ] ──► Moved to [ SQS: video-jobs-dlq ] (14-day retention, prevents loops)
```

---

## 3. Deep Dive into Worker Source Code (Line-by-Line)

### 3.1 `transcoder.py` — FFmpeg Execution & Parameters
**File Location:** `video-platform/services/worker/worker/transcoder.py`

This module is responsible for constructing and executing FFmpeg commands via Python's `subprocess` engine.

```python
RENDITIONS = {"720p": 720, "480p": 480}
```
* **Why 720p and 480p?** Provides an optimal balance between visual quality, encoding speed, and storage footprint. 720p serves high-definition desktop clients, while 480p ensures smooth playback on constrained mobile data connections.

#### Rendition Command Construction
```python
def rendition_command(input_path: str, output_path: str, height: int) -> list[str]:
    return [
        "ffmpeg", "-y", "-i", input_path,
        "-vf", f"scale=-2:{height}",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "28",
        "-c:a", "aac",
        "-movflags", "+faststart",
        output_path,
    ]
```

**Examiner Defense of Every FFmpeg Flag:**
1. `-y`: Automatically overwrites output files without prompting. Essential for non-interactive headless containers.
2. `-i input_path`: Path to the downloaded source `.mp4` file.
3. `-vf scale=-2:{height}`:
   * Scales video to the target vertical resolution (720px or 480px).
   * `-2` automatically computes the width while preserving aspect ratio and **forces the width to be an even number** (divisible by 2). H.264 macroblock encoding crashes if dimensions are odd numbers.
4. `-c:v libx264`: Encodes video using the industry-standard H.264 codec, supported natively by 99.9% of web browsers and mobile devices.
5. `-preset veryfast`: Configures the x264 encoder algorithm. Trade-off: slightly larger file size in exchange for a massive reduction in CPU encoding time, enabling low-latency job completion on serverless Fargate.
6. `-crf 28`: Constant Rate Factor (0–51). `28` yields visually crisp video for web streaming while keeping bitrate and file size compact.
7. `-c:a aac`: Encodes audio using Advanced Audio Coding (AAC) for universal browser compatibility.
8. `-movflags +faststart`: **Critical streaming optimization.** Standard MP4 files place the `moov` atom (metadata/index header) at the end of the file. `+faststart` moves the `moov` atom to the very beginning of the MP4 container. This allows web browsers to begin playing video immediately as bytes download, eliminating buffering delays.

#### Thumbnail Generation
```python
def thumbnail_command(input_path: str, output_path: str) -> list[str]:
    return [
        "ffmpeg", "-y", "-i", input_path,
        "-ss", "00:00:01.000", "-vframes", "1",
        "-vf", "scale=640:-1",
        output_path,
    ]
```
* `-ss 00:00:01.000`: Fast-seeks to the 1-second timestamp to avoid black opening frames.
* `-vframes 1`: Extracts exactly one image frame.
* `-vf scale=640:-1`: Resizes thumbnail to 640px width while automatically scaling height proportionally.
* **Edge-case fallback handling (Lines 52–56):** If a user uploads a clip shorter than 1 second, seeking to `00:00:01` fails. The code catches `RuntimeError`, resets `-ss` to `0`, and captures the first available frame.

#### Error Handling & Execution
```python
def run(cmd: list[str], timeout: int) -> None:
    logger.info("running: %s", " ".join(cmd))
    result = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        tail = result.stderr.strip().splitlines()[-5:]
        raise RuntimeError(f"ffmpeg exited {result.returncode}: {' | '.join(tail)}")
```
* Captures standard error (`stderr`). If FFmpeg fails, extracts the last 5 lines of the error log and raises a descriptive `RuntimeError`, allowing the worker daemon to record the failure reason in DynamoDB.

---

### 3.2 `main.py` — SQS Long-Polling & Lifecycle Daemon
**File Location:** `video-platform/services/worker/worker/main.py`

#### 1. Graceful SIGTERM Shutdown
```python
shutting_down = False

def handle_sigterm(signum, frame):
    global shutting_down
    logger.info("received signal %s, finishing current job then exiting", signum)
    shutting_down = True
```
* AWS Fargate Spot sends a `SIGTERM` signal 2 minutes before reclaiming an instance. The worker catches this signal, sets `shutting_down = True`, finishes transcoding its active job, uploads results to S3, and exits cleanly.

#### 2. S3 Event Message Parsing
```python
def parse_message(body: str) -> list[str]:
    payload = json.loads(body)
    if payload.get("Event") == "s3:TestEvent":
        return []
    keys = []
    for record in payload.get("Records", []):
        if not record.get("eventName", "").startswith("ObjectCreated"):
            continue
        key = unquote_plus(record["s3"]["object"]["key"])
        if key.startswith("raw/") and key.endswith(".mp4"):
            keys.append(key)
    return keys
```
* Ignores AWS test events (`s3:TestEvent`).
* Filters strictly for `ObjectCreated` events.
* Uses `unquote_plus()` to decode URL-encoded keys (e.g., spaces converted to `+` or `%20`).
* Enforces file naming security: processes only objects residing in `raw/` ending with `.mp4`.

#### 3. Long-Polling Loop
```python
def poll_once(self) -> None:
    response = self.sqs.receive_message(
        QueueUrl=settings.sqs_queue_url,
        MaxNumberOfMessages=1,
        WaitTimeSeconds=20,
    )
    for message in response.get("Messages", []):
        self.handle_message(message)
```
* `WaitTimeSeconds = 20`: **SQS Long Polling.** Instead of polling continuously and burning CPU/network requests, the connection remains open for up to 20 seconds waiting for an incoming message. Reduces empty receive calls by >95% and minimizes AWS API billing.

#### 4. Idempotency & Fault Isolation
```python
def process(self, source_key: str) -> None:
    video_id = video_id_from_key(source_key)
    item = self.table.get_item(Key={"video_id": video_id}).get("Item")
    if item and item.get("status") == "ready":
        logger.info("video %s already ready, skipping duplicate delivery", video_id)
        return
```
* **Idempotency Guard:** SQS guarantees *at-least-once* delivery. If a network hiccup causes a duplicate message delivery for an already processed video, the worker detects `status == "ready"` and immediately skips redundant re-encoding.

#### 5. Atomic DynamoDB Status Updates
```python
self.table.update_item(
    Key={"video_id": video_id},
    UpdateExpression=(
        "SET #s = :s, updated_at = :u, source_key = :k, #e = :null "
        "ADD attempts :one"
    ),
    ExpressionAttributeNames={"#s": "status", "#e": "error"},
    ExpressionAttributeValues={
        ":s": "processing", ":u": utc_now(), ":k": source_key, ":null": None, ":one": 1,
    },
)
```
* Atomically sets status to `processing`, increments `attempts` by 1, and clears any previous error text.

#### 6. Upload & Success Transition
```python
files = transcoder.transcode(input_path, str(job_dir), settings.ffmpeg_timeout_seconds)
keys = output_keys(video_id)
for name, path in files.items():
    content_type = "image/jpeg" if name == "thumbnail" else "video/mp4"
    self.s3.upload_file(
        path, settings.processed_bucket, keys[name],
        ExtraArgs={"ContentType": content_type},
    )

self.table.update_item(
    Key={"video_id": video_id},
    UpdateExpression="SET #s = :s, outputs = :o, thumbnail_key = :t, updated_at = :u",
    ExpressionAttributeNames={"#s": "status"},
    ExpressionAttributeValues={
        ":s": "ready",
        ":o": {"720p": keys["720p"], "480p": keys["480p"]},
        ":t": keys["thumbnail"],
        ":u": utc_now(),
    },
)
```
* Uploads `720p.mp4`, `480p.mp4`, and `thumb.jpg` to the processed S3 bucket with correct MIME `ContentType` headers.
* Updates DynamoDB status to `ready`.
* **Deletes SQS Message:** Only after successful database commit is `self.delete(receipt)` executed. If the worker crashes halfway through, the message remains on SQS to be retried.

---

### 3.3 `config.py` — Pydantic Settings
**File Location:** `video-platform/services/worker/worker/config.py`
* Extends `pydantic_settings.BaseSettings`.
* Automatically reads environment variables injected by ECS Fargate:
  * `SQS_QUEUE_URL`: Queue endpoint.
  * `UPLOADS_BUCKET` & `PROCESSED_BUCKET`: Target S3 bucket names.
  * `DDB_TABLE`: DynamoDB table name.
  * `FFMPEG_TIMEOUT_SECONDS`: 600s (10-minute safeguard against hung processes).
  * `WORK_DIR`: `/tmp/transcoder` local scratch space.

---

### 3.4 `Dockerfile` — Multi-Stage Non-Root Build
**File Location:** `video-platform/services/worker/Dockerfile`

```dockerfile
# Stage 1: Download static FFmpeg binary
FROM alpine:3.20 AS ffmpeg-builder
RUN apk add --no-cache curl tar xz
RUN curl -sSL https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
    | tar -xJ --strip-components=1 -C /usr/local/bin

# Stage 2: Final runtime image
FROM python:3.11-slim
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
RUN useradd -m -u 1000 appuser
USER appuser
```
* **Why Multi-Stage?** Compiling or downloading FFmpeg requires tar and curl utilities. By using a builder stage, build tools are discarded, reducing the final container image size by over 200 MB.
* **Why Static FFmpeg Binary?** Pre-compiled standalone static binary from John Van Sickle contains all required codecs (x264, AAC) without needing complex shared C libraries.
* **Security Hardening:** Creates unprivileged user `appuser` (`UID 1000`). If a malicious video file exploits an FFmpeg zero-day buffer overflow, the attacker cannot gain root access to the container or host.

---

### 3.5 `tests/test_worker.py` — Pytest & Moto Mocks
**File Location:** `video-platform/services/worker/tests/test_worker.py`
* Uses `moto` (`mock_aws`) to simulate SQS, S3, and DynamoDB in memory.
* Tests covered:
  1. `test_parse_message()`: Verifies URL decoding and S3 test event filtering.
  2. `test_handle_message_success()`: Simulates end-to-end receipt, transcode execution, S3 upload, and DynamoDB status updating.
  3. `test_handle_message_error_leaves_on_queue()`: Proves that failed jobs do not delete the SQS message, allowing redelivery to the Dead-Letter Queue.

---

## 4. Infrastructure as Code (Terraform)

### 4.1 `sqs.tf` — Queues, Redrive & Dead-Letter Queue (DLQ)
**File Location:** `video-platform/infra/terraform/sqs.tf`

```hcl
resource "aws_sqs_queue" "jobs" {
  name                       = "${local.name}-jobs"
  visibility_timeout_seconds = 300 # 5 minutes (exceeds worker transcode time)
  message_retention_seconds  = 1209600 # 14 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name}-jobs-dlq"
  message_retention_seconds = 1209600
}
```

**Technical Insights for Defense:**
* **Visibility Timeout = 300s (5 minutes):** When a worker reads a message, SQS hides it from other workers for 5 minutes. If transcoding takes 2 minutes and succeeds, the message is deleted. If the worker crashes, the message reappears after 5 minutes for another worker.
* **Redrive Policy (`maxReceiveCount = 3`):** If a corrupted video repeatedly crashes workers, SQS moves it to `video-jobs-dlq` after 3 attempts. This stops "poison-pill" messages from creating infinite retry loops that waste CPU and run up AWS bills.
* **S3 Queue Policy:** Configures an IAM resource policy allowing `s3.amazonaws.com` to publish `s3:ObjectCreated:*` events into `video-jobs`.

---

### 4.2 `autoscaling.tf` — Scale from 0 to 3 on Queue Backlog
**File Location:** `video-platform/infra/terraform/autoscaling.tf`

```hcl
resource "aws_appautoscaling_target" "worker" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 0
  max_capacity       = 3
}
```

#### Step Scaling Policies:
1. **Scale-Out Policy (`video-platform-worker-scale-out`):**
   * Triggered by CloudWatch Alarm `video-platform-queue-backlog` evaluating `ApproximateNumberOfMessagesVisible >= 1`.
   * **Step Adjustments:**
     * 1 to 4 waiting messages ➔ Add **1** worker task.
     * 5 to 9 waiting messages ➔ Add **2** worker tasks.
     * 10+ waiting messages ➔ Add **3** worker tasks (capped at max 3).
2. **Scale-In Policy (`video-platform-worker-scale-in`):**
   * Triggered when visible messages == 0 **AND** in-flight messages == 0 for 5 consecutive minutes.
   * Sets desired count back to **0**.
   * **Why counting in-flight messages matters:** If only visible messages were checked, AWS would shut down workers while they were in the middle of transcoding a video! Checking `ApproximateNumberOfMessagesNotVisible == 0` ensures workers finish current jobs before scaling in.

---

### 4.3 `ecs.tf` — Fargate Spot Strategy & Graceful Drain
**File Location:** `video-platform/infra/terraform/ecs.tf`

```hcl
resource "aws_ecs_service" "worker" {
  name            = "${local.name}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 0 # Controlled dynamically by autoscaling

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }
}
```
* **Fargate Spot:** Uses spare AWS capacity sold at a **~70% discount**.
* **`stopTimeout = 120`:** Sets a 2-minute container stop timeout. When AWS reclaims Spot capacity, it sends a `SIGTERM`. The worker catches it, completes the active transcode, and uploads to S3 before AWS forcefully terminates the container.

---

## 5. Automated DevSecOps CI/CD Pipelines (GitHub Actions)

### 5.1 `ci-deploy.yml` — Smart Filtering, Trivy, ECR & Rolling Deployment
**File Location:** `.github/workflows/ci-deploy.yml`

This workflow runs on every `git push` to `main`:

```
[ Push to main ]
       │
       ▼
[ Job 1: Detect Changes (dorny/paths-filter) ]
       │── If only frontend changed ➔ Skips Docker builds & tests (Deploys in 15s)
       │── If worker changed ➔ Runs Job 2 & Job 3
       │
       ▼
[ Job 2: Lint & Test ]
       │── Python 3.11 + pip cache
       │── ruff check . & ruff format --check .
       │── pytest -v (with Moto AWS mocks)
       │
       ▼
[ Job 3: Build, Scan & Deploy ]
       │── 1. docker build -t local/worker:${{ github.sha }}
       │── 2. Trivy Container Vulnerability Scan
       │       └── Fails build on fixable CRITICAL CVEs
       │── 3. Configure AWS Credentials via OIDC (sts:AssumeRoleWithWebIdentity)
       │── 4. Push image to Amazon ECR (${{ github.sha }} & latest)
       │── 5. Render new Task Definition & Deploy to ECS Fargate
       │── 6. ECS Circuit Breaker Verification (confirms no automatic rollback)
       │
       ▼
[ Job 4: Smoke Test ]
       └── Probes ALB and CloudFront /api/health (Verifies HTTP 200)
```

#### Why Trivy Runs Before AWS Login (Security Architecture)
```yaml
- name: Scan image with Trivy (fail on fixable CRITICAL)
  run: |
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
      aquasec/trivy:0.56.2 image --severity CRITICAL --ignore-unfixed --exit-code 1 \
      "local/$SERVICE:${{ github.sha }}"

- uses: aws-actions/configure-aws-credentials@v4
```
* **DevSecOps Isolation:** Trivy executes in an isolated Docker container **before** `configure-aws-credentials` runs. Even if a third-party scanning action is compromised, it has zero access to AWS tokens.
* **Fail-Safe Policy:** `--ignore-unfixed --exit-code 1` ensures the build fails only if a critical CVE exists that has an available security patch.

#### Zero-Downtime Rolling Update & Circuit Breaker
* `wait-for-service-stability: true`: Waits for new tasks to pass health checks before terminating old tasks.
* **Deployment Circuit Breaker:** If a bad release crashes the new container, ECS automatically cancels the deployment and rolls back to the previous task definition revision. The workflow checks:
  ```bash
  if [ "$LIVE" != "${{ steps.deploy.outputs.task-definition-arn }}" ]; then
    echo "Deployment was rolled back by the ECS circuit breaker"
    exit 1
  fi
  ```

---

### 5.2 `rollback.yml` — One-Click Instant Reversion
**File Location:** `.github/workflows/rollback.yml`
* Triggered manually via `workflow_dispatch`.
* User selects service (`api` or `worker`) and target revision (or leaves blank to default to `current - 1`).
* Updates ECS service definition directly and waits for stability.
* **Recovery time:** Restores the previous stable production container in under **60 seconds**.

---

### 5.3 `infra.yml` — Terraform IaC Automated Guardrails
**File Location:** `.github/workflows/infra.yml`
* Runs on Pull Requests modifying `infra/**`.
* Executes `terraform fmt -check`, `terraform validate`, and `terraform plan`.
* Formats the plan output and posts it directly into the PR summary so changes can be peer-reviewed before merging.

---

## 6. Live Presentation Script & Demonstration Playbook

### Step-by-Step Presentation Walkthrough (When It's Your Turn to Speak)

1. **Take the Screen & Introduce Yourself:**
   > *"Good morning/afternoon professors. I am the Transcoding, Distributed Systems, and CI/CD Lead for StreamForge. I designed the asynchronous processing engine and our automated DevSecOps release pipeline."*

2. **Explain the Distributed Decoupling (Show Architecture Diagram):**
   > *"Video transcoding is computationally heavy. If encoding ran synchronously on our web server, uploading a single 4K video would monopolize CPU and crash the website for everyone. I solved this by decoupling the architecture using Amazon SQS. When an upload lands in S3, an S3 Event Notification drops a job message into our `video-jobs` queue. Our worker daemon uses SQS long-polling to retrieve messages asynchronously."*

3. **Open AWS Console — SQS Queues:**
   * Navigate to **Amazon SQS** ➔ Click **`video-jobs`**.
   * Show `Messages available` and point out the linked Dead-Letter Queue **`video-jobs-dlq`**.
   > *"Notice our Dead-Letter Queue configuration with `maxReceiveCount = 3`. If a user uploads a malformed video that crashes FFmpeg, SQS retries twice before quarantining the file in the DLQ, ensuring corrupted files never cause infinite retry loops."*

4. **Open CloudWatch Logs — Worker Live Output:**
   * Navigate to **CloudWatch** ➔ **Log groups** ➔ **`/ecs/video-platform-worker`**.
   * Open the latest log stream and highlight the FFmpeg execution:
   > *"Here in our CloudWatch worker logs, you can see our FFmpeg execution. We transcode into two resolutions: 720p HD and 480p SD, using `-preset veryfast` and Constant Rate Factor 28. Notice we inject `-movflags +faststart`, which moves the MP4 metadata header to the beginning of the file so users can stream instantly without downloading the full video first. We also extract a 640px JPEG thumbnail."*

5. **Explain Auto-Scaling & Spot Cost Savings:**
   > *"To keep AWS costs minimal, our workers run on ECS Fargate Spot at a 70% discount. Furthermore, our Application Auto Scaling policy scales workers dynamically between 0 and 3 based on SQS queue backlog. When no jobs are waiting, the workers scale down to zero, meaning idle compute cost is exactly $0.00."*

6. **Open GitHub Actions — CI/CD Pipeline:**
   * Open GitHub Actions ➔ Show [Run #41385999610](https://github.com/kartikadhonde/cc-proj/actions/runs/41385999610).
   * Point out the green checkmarks:
   > *"Finally, here is our GitHub Actions pipeline. On every commit, it runs Ruff formatting, Pytest unit tests, and scans our Docker container with Aqua Security Trivy for CRITICAL vulnerabilities before pushing to ECR and rolling out to ECS Fargate with zero downtime."*

---

## 7. Exhaustive Viva & Defense Question Bank (With Model Answers)

#### Q1: Why did you use Amazon SQS instead of calling the worker directly via HTTP?
**Answer:** An HTTP call is synchronous and tight-coupled. If the worker is busy, crashes, or takes 3 minutes to encode, the HTTP connection would time out or run out of sockets. SQS provides asynchronous decoupling: it acts as a shock absorber that buffers hundreds of incoming uploads safely without dropping any, allowing workers to process jobs steadily at their own capacity.

#### Q2: Why did you use ECS Fargate instead of AWS Lambda for transcoding?
**Answer:** AWS Lambda has a hard 15-minute execution limit and restricted local disk space (up to 10 GB ephemeral storage). Transcoding high-definition or longer videos frequently exceeds 15 minutes and requires custom FFmpeg binaries and flexible scratch disk allocations. ECS Fargate provides full Linux container flexibility without runtime timeouts.

#### Q3: What is the purpose of `-movflags +faststart` in FFmpeg?
**Answer:** In standard MP4 containers, the `moov` atom (which contains video indexing and duration metadata) is written at the very end of the file after encoding completes. Without `+faststart`, a web browser cannot begin playback until 100% of the video file is downloaded. The `+faststart` flag relocates the `moov` atom to the very beginning of the container, allowing web browsers to start streaming playback immediately after receiving the first few kilobytes.

#### Q4: What is SQS Long Polling and why did you set `WaitTimeSeconds = 20`?
**Answer:** Standard (short) polling queries SQS and returns immediately, even if the queue is empty, generating thousands of empty API calls that waste CPU and increase AWS billing. Long polling (`WaitTimeSeconds = 20`) causes SQS to wait up to 20 seconds for a message to arrive before sending a response. This reduces empty responses by >95%, lowers API request costs, and enables instant job pickup when a message arrives.

#### Q5: What is SQS Visibility Timeout and why is it set to 300 seconds?
**Answer:** When a worker picks up a message, SQS doesn't delete it immediately; it hides it from other workers for the duration of the visibility timeout (300 seconds / 5 minutes). If the worker finishes transcoding within 2 minutes, it explicitly deletes the message. If the worker container crashes midway, the message becomes visible again after 5 minutes so another worker can retry it.

#### Q6: How does the Dead-Letter Queue (DLQ) protect the system?
**Answer:** If an uploaded file is corrupted, unreadable, or contains malicious payloads that repeatedly crash FFmpeg, the message would normally loop indefinitely. Our redrive policy sets `maxReceiveCount = 3`. After 3 failed processing attempts, SQS routes the message to `video-jobs-dlq`, isolating the "poison pill" and keeping the main queue clean.

#### Q7: How does worker auto-scaling work? Why do you monitor both visible and in-flight messages?
**Answer:** CloudWatch monitors SQS queue depth. When uploads arrive, alarm `video-platform-queue-backlog` evaluates `ApproximateNumberOfMessagesVisible >= 1` and scales worker tasks from 0 up to 3. For scaling in, alarm `video-platform-queue-empty` checks that visible messages == 0 **AND** in-flight messages (`ApproximateNumberOfMessagesNotVisible`) == 0 for 5 minutes. Checking in-flight messages ensures workers finish encoding active videos before AWS scales them down.

#### Q8: What is Fargate Spot and how do you handle instance termination?
**Answer:** Fargate Spot uses spare AWS compute capacity sold at up to a 70% discount. When AWS needs the capacity back, it sends a `SIGTERM` warning 2 minutes prior to termination. Our worker registers a Python signal handler (`handle_sigterm`) and sets `stopTimeout = 120` in ECS. The worker finishes its active transcode, uploads results, and exits gracefully before the container is terminated.

#### Q9: Why does Trivy scan run *before* configuring AWS credentials in GitHub Actions?
**Answer:** Security principle of least privilege and isolation. Running the vulnerability scanner before AWS credentials exist in the runner environment guarantees that even if a scanning tool or container dependency contains malicious code, it cannot exfiltrate AWS tokens or credentials.

#### Q10: How does your CI/CD pipeline achieve zero-downtime deployments?
**Answer:** ECS uses rolling updates with deployment circuit breakers. When a new image is deployed, ECS launches a new task alongside the running task, waits for health checks to pass (`/health`), shifts traffic over, and only then terminates the old task. If the new container fails health checks, the circuit breaker automatically aborts the rollout and restores the previous task revision.

#### Q11: What is the difference between `-preset veryfast` and `-crf 28`?
**Answer:** `-preset` dictates the encoding *speed vs compression efficiency* (how long the CPU takes to compress data). `veryfast` optimizes for low CPU encoding time. `-crf` (Constant Rate Factor) dictates *visual quality vs bitrate*. Lower CRF means higher quality; 28 is the sweet spot for crisp 720p/480p web video streaming without excessive bandwidth consumption.

#### Q12: Why did you scale video with `scale=-2:{height}` instead of `-1:{height}`?
**Answer:** H.264 video encoding algorithms operate on 2x2 or 16x16 pixel macroblocks and require both width and height to be even numbers. Using `-1` can produce an odd width (e.g., 853x480), which causes FFmpeg to exit with an error. Using `-2` automatically computes proportional width while rounding to the nearest even number.

