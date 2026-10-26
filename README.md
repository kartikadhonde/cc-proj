# StreamForge — Cloud-Native Video Transcoding & Streaming Platform

[![AWS Fargate](https://img.shields.io/badge/AWS-Fargate%20%26%20Fargate%20Spot-orange?logo=amazon-aws)](https://aws.amazon.com/fargate/)
[![Terraform](https://img.shields.io/badge/IaC-Terraform%201.10%2B-purple?logo=terraform)](https://www.terraform.io/)
[![FastAPI](https://img.shields.io/badge/API-FastAPI%20(Python%203.11)-009688?logo=fastapi)](https://fastapi.tiangolo.com/)
[![FFmpeg](https://img.shields.io/badge/Transcoder-FFmpeg%207.1-green?logo=ffmpeg)](https://ffmpeg.org/)
[![Docker](https://img.shields.io/badge/Containers-Docker%20Multi--Stage-blue?logo=docker)](https://www.docker.com/)
[![CI/CD](https://img.shields.io/badge/CI%2FCD-GitHub%20Actions%20OIDC-black?logo=github-actions)](https://github.com/features/actions)
[![Security](https://img.shields.io/badge/Security-Trivy%20Vulnerability%20Scan-red?logo=aquasec)](https://www.aquasec.com/products/trivy/)
[![License](https://img.shields.io/badge/License-MIT-brightgreen.svg)](LICENSE)

An enterprise-grade, event-driven, serverless media pipeline that ingests raw MP4 video uploads directly to Amazon S3, coordinates asynchronous transcoding via SQS and DynamoDB, processes multi-bitrate renditions (720p HD, 480p SD, and JPEG thumbnails) on elastic AWS Fargate Spot workers using FFmpeg, and streams content globally via Amazon CloudFront with Origin Access Control (OAC).

The platform includes a **modern YouTube-inspired cinema viewing interface**, full local development emulation via **Docker Compose & LocalStack**, and a hardened **automated CI/CD pipeline** with vulnerability scanning, OIDC keyless authentication, and deployment circuit breakers.

---

## 📑 Table of Contents
1. [System Architecture](#-system-architecture)
2. [End-to-End Processing Workflow](#-end-to-end-processing-workflow)
3. [Key Engineering Highlights](#-key-engineering-highlights)
4. [Technology Stack](#-technology-stack)
5. [Repository Structure](#-repository-structure)
6. [Quickstart 1: Running Locally (Docker Compose + LocalStack)](#-quickstart-1-running-locally-free-no-aws-needed)
7. [Quickstart 2: Deploying to AWS Cloud (Terraform)](#-quickstart-2-deploying-to-aws-cloud)
8. [YouTube-Inspired Frontend Experience](#-youtube-inspired-frontend-experience)
9. [Automated CI/CD & Release Engineering](#-automated-cicd--release-engineering)
10. [Cost Engineering & Free-Tier Optimization](#-cost-engineering--free-tier-optimization)
11. [REST API Specification](#-rest-api-specification)
12. [Disaster Recovery & Clean Teardown](#-disaster-recovery--clean-teardown)
13. [Troubleshooting & Gotchas](#-troubleshooting--gotchas)

---

## 🏛 System Architecture

```mermaid
flowchart TD
  subgraph Clients["Clients & Edge Tier"]
    User["Client Browser"]
    CF["Amazon CloudFront CDN<br/>(Global Edge Network)"]
    OAC["Origin Access Control (OAC)"]
  end

  subgraph Ingestion["Ingestion & Control Plane"]
    ALB["Application Load Balancer (ALB)<br/>(Path Routing: /api/*)"]
    API["FastAPI Control Service<br/>(ECS Fargate Service)"]
    DDB[("DynamoDB Table<br/>(video-platform-videos)")]
    S3_UP[("S3 Uploads Bucket<br/>(raw/{video_id}.mp4)")]
  end

  subgraph AsyncProcessing["Asynchronous Processing Plane"]
    SQS["SQS Video Jobs Queue<br/>(Visibility: 300s)"]
    DLQ["SQS Dead-Letter Queue<br/>(Max Receive: 3)"]
    CW["CloudWatch Queue Alarms"]
    AAS["Application Auto Scaling<br/>(0 to 3 Workers)"]
    Worker["Transcoding Worker Pool<br/>(ECS Fargate Spot + FFmpeg 7.1)"]
  end

  subgraph StorageDelivery["Storage & Delivery Plane"]
    S3_PR[("S3 Processed Bucket<br/>(720p, 480p, Thumbnails)")]
    S3_FE[("S3 Frontend Static Bucket<br/>(HTML, CSS, JS)")]
  end

  %% Client Requests
  User -->|1. HTTPS Request| CF
  CF -->|2a. Route /*| S3_FE
  CF -->|2b. Route /api/*| ALB
  CF -->|2c. Route /processed/*| OAC
  OAC --> S3_PR

  %% Upload Ingress
  ALB --> API
  API -->|3. Register Metadata| DDB
  API -.->|4. Presigned S3 PUT URL| User
  User -->|5. Direct PUT upload| S3_UP

  %% Event Queue & Worker
  S3_UP -->|6. s3:ObjectCreated:*| SQS
  SQS -->|Failed 3x| DLQ
  SQS -.->|Backlog Metric| CW
  CW -->|Trigger Scaling| AAS
  AAS -->|Scale Out/In (0-3)| Worker
  SQS -->|7. Long-Poll Receive| Worker

  %% Transcoding & Completion
  Worker -->|8. Fetch Raw Video| S3_UP
  Worker -->|9. FFmpeg Transcode| Worker
  Worker -->|10. Upload 720p, 480p, thumb| S3_PR
  Worker -->|11. Update Status: ready| DDB
  Worker -->|12. Delete SQS Message| SQS
```

---

## 🔄 End-to-End Processing Workflow

```
[Client Browser] 
       │ 
       ├── 1. POST /api/videos {"title": "My Clip"} ─────────► [FastAPI API]
       │                                                              │
       │                                                Creates video record:
       │                                                status = "uploaded"
       │                                                              ▼
       │◄── 2. Returns {video_id, upload_url} ────────────── [DynamoDB]
       │
       ├── 3. Direct HTTP PUT (Raw MP4) ────────────────────► [S3 Uploads Bucket]
       │      (with real-time progress tracking)                      │
       │                                                       S3 Event Notification
       │                                                              ▼
       │                                                     [SQS: video-jobs]
       │                                                              │
       │                                                       Long-polling / Scale out
       │                                                              ▼
       │                                                     [ECS Worker: FFmpeg]
       │                                                              │
       │                                                       Transcodes to 720p,
       │                                                       480p & JPEG thumbnail
       │                                                              ▼
       │                                                     [S3 Processed Bucket]
       │                                                              │
       │                                                       Updates status: "ready"
       │                                                              ▼
       ├── 4. GET /api/videos (Poll every 5s) ──────────────► [DynamoDB]
       │
       └── 5. Streams 720p/480p via CloudFront CDN ◄───────── [CloudFront OAC]
```

1. **Client Registration:** Client submits video title to the FastAPI endpoint (`POST /api/videos`). The API inserts an item into DynamoDB with status `uploaded` and generates a cryptographically signed Amazon S3 presigned PUT URL expiring in 15 minutes.
2. **Direct-to-S3 Ingress:** The browser performs a direct `PUT` to `s3://video-platform-uploads/raw/{video_id}.mp4`, bypassing API containers entirely. This eliminates memory saturation, socket starvation, and multi-megabyte request proxying.
3. **Event Notification & Queueing:** Amazon S3 emits an `ObjectCreated:*` event directly to the Amazon SQS `video-jobs` queue.
4. **Elastic Worker Provisioning:** Amazon CloudWatch tracks queue backlog metrics. AWS Application Auto Scaling provisions containerized worker tasks on **AWS Fargate Spot** (scaling elastically from `0` up to `3` workers).
5. **Multi-Rendition Transcoding:** The worker pulls the raw MP4 from S3 into an ephemeral scratch workspace, invokes **FFmpeg 7.1** using `libx264` (video) and `aac` (audio) to generate:
   - **720p HD:** `1280x720`, `-crf 23`, `-preset fast`, `maxrate 2.8M`, `bufsize 5.6M`
   - **480p SD:** `854x480`, `-crf 26`, `-preset fast`, `maxrate 1.4M`, `bufsize 2.8M`
   - **JPEG Thumbnail:** Extracted at timestamp `00:00:01`
6. **Delivery & Playback:** Outputs are uploaded to `s3://video-platform-processed/processed/{video_id}/`. The worker sets status to `ready` in DynamoDB with output keys and deletes the SQS message. The client automatically renders the video card and streams over Amazon CloudFront with sub-second buffering.

---

## ⚡ Key Engineering Highlights

| Feature | Engineering Implementation | Benefit |
|---|---|---|
| **Presigned Ingress** | Boto3 generates time-limited presigned PUT URLs (`raw/{id}.mp4`) | Bypasses API memory; enables multi-gigabyte uploads without gateway timeouts |
| **Scale-to-Zero Workers** | CloudWatch alarm on `ApproximateNumberOfMessagesVisible == 0` triggers scale-in to `0` | **$0.00 compute costs** during idle hours; runs only when work exists |
| **Fargate Spot Instances** | Workers run on ECS Fargate Spot capacity provider | **~70% cost reduction** compared to on-demand container instances |
| **Zero NAT Gateway** | Containers run in public subnets with strict Security Groups | **Saves ~$32/month**; inbound access is completely blocked except for ALB -> API |
| **Single CloudFront Origin** | Multi-origin distribution routing `/*` (S3 frontend), `/api/*` (ALB), `/processed/*` (S3) | Eliminates CORS issues, unifies domain under HTTPS, leverages global edge caching |
| **Origin Access Control (OAC)** | S3 buckets block all public access; readable only by CloudFront OAC principal | Complete zero-trust storage security; media cannot be accessed directly from S3 |
| **Dead-Letter Queue (DLQ)** | SQS redrive policy moves poison-pill videos to `video-jobs-dlq` after 3 failed attempts | Prevents infinite retry loops and runaway worker compute billing |
| **OIDC Keyless CI/CD** | GitHub Actions assumes IAM role via OpenID Connect token exchange | **Zero long-lived AWS keys stored in GitHub Secrets**; eliminates credential leak risks |
| **Security Scanning** | Aqua Security Trivy container scanning in CI/CD blocks critical CVEs | Hardens container supply chain before deployment |
| **Deployment Circuit Breaker** | ECS rolling deployment monitors task health; automatically rolls back upon container failure | Zero-downtime releases with automated rollback recovery |

---

## 🛠 Technology Stack

### Cloud Infrastructure (AWS)
- **Container Orchestration:** Amazon Elastic Container Service (ECS) with AWS Fargate & Fargate Spot
- **Load Balancing:** Application Load Balancer (ALB) with HTTP/2 and health probes
- **Object Storage:** Amazon S3 (Uploads, Processed, Frontend Static, Terraform State)
- **Message Broker:** Amazon Simple Queue Service (SQS) with Dead-Letter Queue (DLQ)
- **Database:** Amazon DynamoDB (Pay-Per-Request on-demand billing, single-digit ms latency)
- **CDN:** Amazon CloudFront with Origin Access Control (OAC) and custom 403/404 error handling
- **Observability:** Amazon CloudWatch Metrics, Alarms, and Container Logs
- **Security:** AWS Identity and Access Management (IAM), OpenID Connect (OIDC) Identity Provider

### Application Services
- **Control Plane API:** Python 3.11, FastAPI, Uvicorn, Pydantic v2, Boto3
- **Media Transcoder:** Python 3.11, FFmpeg 7.1 (`libx264`, `aac`), multi-stage Docker runtime
- **Client Frontend:** Vanilla ES6+ JavaScript, CSS3 Glassmorphism, Semantic HTML5, Google Fonts (`Outfit`, `Inter`)
- **Testing & Quality:** Pytest, HTTPX, Ruff (Linter & Formatter), Aqua Security Trivy (CVE Scanner)

### DevOps & Infrastructure as Code
- **IaC:** Terraform v1.10+ (Modular, S3 remote state backend with state locking)
- **CI/CD:** GitHub Actions (Multi-job pipeline: test, lint, scan, push to ECR, deploy ECS, sync S3)
- **Local Emulation:** Docker Compose v2, LocalStack v3.8 (emulating S3, SQS, DynamoDB)

---

## 📂 Repository Structure

```
cc-proj/
├── .gitattributes                     # Enforces LF line endings for Linux/container scripts
├── .gitignore                         # Ignores Terraform state, caches, venv, and logs
├── README.md                          # Root repository documentation (this file)
├── PROJECT_REPORT.md                  # Comprehensive academic & engineering project report
├── .github/
│   └── workflows/
│       ├── ci-deploy.yml              # Automated CI/CD: test -> scan -> ECR -> ECS -> S3
│       ├── rollback.yml               # Manual GitOps workflow to revert ECS revisions
│       └── infra.yml                  # PR workflow: terraform fmt check & terraform plan
└── video-platform/
    ├── docker-compose.yml             # LocalStack + API + Worker + Frontend local environment
    ├── README.md                      # Local application cheatsheet
    ├── infra/
    │   └── terraform/                 # 100% Declarative Infrastructure as Code
    │       ├── main.tf                # AWS provider, S3 backend, local variables
    │       ├── variables.tf           # Configurable inputs (region, repo, resources)
    │       ├── network.tf             # VPC, dual public subnets, IGW, security groups
    │       ├── s3.tf                  # Buckets, CORS rules, lifecycle expirations, SQS events
    │       ├── sqs.tf                 # video-jobs & video-jobs-dlq with redrive policy
    │       ├── dynamodb.tf            # videos table (partition key: video_id, on-demand)
    │       ├── ecr.tf                 # ECR repos for api and worker with image pruning
    │       ├── iam.tf                 # OIDC role, ECS execution role, task least-privilege roles
    │       ├── ecs.tf                 # Fargate cluster, ALB, target groups, API & Worker services
    │       ├── autoscaling.tf         # CloudWatch alarms & Application Auto Scaling target
    │       ├── cloudfront.tf          # CDN distribution, OAC policy, multi-origin path routing
    │       └── outputs.tf             # Exports CloudFront URL, ALB DNS, and Role ARNs
    ├── scripts/
    │   ├── init-localstack.sh         # LocalStack container initialization (S3/SQS/DDB)
    │   ├── bootstrap-aws.sh           # One-click cloud deployment script
    │   └── teardown-aws.sh            # Complete cloud teardown script ($0.00 cost guarantee)
    └── services/
        ├── api/                       # Control Plane Microservice
        │   ├── Dockerfile             # Multi-stage Python 3.11-slim container
        │   ├── requirements.txt       # Production dependencies (FastAPI, Uvicorn, Boto3)
        │   ├── requirements-dev.txt   # Testing dependencies (Pytest, Ruff, HTTPX)
        │   ├── app/
        │   │   ├── main.py            # FastAPI routes (/health, /videos, /videos/{id})
        │   │   ├── aws.py             # Boto3 DynamoDB operations & presigned PUT generation
        │   │   ├── config.py          # Environment settings
        │   │   └── models.py          # Pydantic validation models
        │   └── tests/
        │       └── test_api.py        # Automated unit tests with mocked AWS SDK
        ├── worker/                    # Media Transcoding Worker
        │   ├── Dockerfile             # Multi-stage image with FFmpeg 7.1 runtime
        │   ├── requirements.txt       # Boto3
        │   ├── requirements-dev.txt   # Pytest, Ruff
        │   ├── worker/
        │   │   ├── main.py            # SQS long-polling loop & SIGTERM graceful shutdown
        │   │   ├── transcoder.py      # FFmpeg 720p/480p encoding & thumbnail extraction
        │   │   └── config.py          # Worker configuration settings
        │   └── tests/
        │       └── test_worker.py     # Worker unit tests
        └── frontend/                  # YouTube-Style Web Client
            ├── index.html             # Single-page application structure
            ├── style.css              # Obsidian dark theme, cinema player, YouTube styling
            ├── app.js                 # State machine, player resolution switching, comments
            └── config.js              # Injected API endpoint configuration
```

---

## 💻 Quickstart 1: Running Locally (Free, No AWS Needed)

You can run the entire platform on your laptop using **Docker Desktop** and **LocalStack** (which mocks S3, SQS, and DynamoDB).

### Prerequisites
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running.

### 1. Launch the Stack
```powershell
cd d:\MyProjects\cc-proj\video-platform
docker compose up --build -d
```

### 2. Verify Container Health
```powershell
docker compose ps
```
You will see 4 healthy containers:
- `video-platform-frontend-1` on port `3001`
- `video-platform-api-1` on port `8000`
- `video-platform-localstack-1` on port `4566`
- `video-platform-worker-1` (polling SQS)

### 3. Open the Application
- **Frontend UI:** Open **[http://localhost:3001](http://localhost:3001)** in your browser.
- **FastAPI Interactive Docs:** [http://localhost:8000/docs](http://localhost:8000/docs)
- **LocalStack Health:** [http://localhost:4566/_localstack/health](http://localhost:4566/_localstack/health)

### 4. Test the Pipeline
1. On the frontend, click **`+ Upload`**.
2. Select any `.mp4` video and click **Upload Video**.
3. Watch the upload progress bar reach 100%.
4. Within seconds, the video card transitions: **`uploaded` ➔ `processing` ➔ `ready`**.
5. Click the card to open the **Cinema Watch View** with active **720p HD** / **480p SD** resolution switching!

### 5. Stop Local Stack
```powershell
docker compose down
```

---

## ☁️ Quickstart 2: Deploying to AWS Cloud

Deploy the entire cloud architecture with automated Terraform scripts.

### Prerequisites
1. An **AWS Account** with configured CLI credentials (`aws configure`).
2. **GitHub CLI** (`gh auth login`) to automatically configure repository variables.
3. **Terraform** (`terraform version`).

### Step 1: One-Command Bootstrap
Run the bootstrap script from Git Bash or PowerShell:
```powershell
cd d:\MyProjects\cc-proj\video-platform
bash scripts/bootstrap-aws.sh
```

### Step 2: What Happens Automatically
1. Creates your encrypted remote state bucket: `video-platform-tfstate-<account_id>` in `us-east-1`.
2. Generates `terraform.tfvars` with your region and repository.
3. Executes `terraform apply` to provision all 64 AWS resources.
   - *When prompted in terminal, type `yes` to confirm.*
4. Registers GitHub repository variables (`AWS_ROLE_ARN`, `AWS_REGION`, `TF_STATE_BUCKET`).
5. Triggers the automated GitHub Actions CI/CD workflow (`ci-deploy.yml`).
6. Outputs your live **CloudFront URL** (e.g., `https://d2nsdikkubmfh8.cloudfront.net`).

---

## 📺 YouTube-Inspired Frontend Experience

The frontend has been completely engineered to match a sleek, modern YouTube dark-mode experience:

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│  ▶ StreamForge [PRO]       [ 🔍 Search videos by title... ]       + Upload  🔔 [SF]│
├──────────────────────────────────────────────────────────────────────────────────┤
│  (All) (Ready to Watch) (Processing) (Recently Added)              ● Live Sync   │
│                                                                                  │
│  ┌───────────────────────┐  ┌───────────────────────┐  ┌──────────────────────┐  │
│  │ [Thumbnail 16:9]      │  │ [Thumbnail 16:9]      │  │ [Thumbnail 16:9]     │  │
│  │ [READY]      [720p HD]│  │ [READY]      [720p HD]│  │ [TRANSCODING]        │  │
│  │ (Play overlay on hover│  │                       │  │                      │  │
│  ├───────────────────────┤  ├───────────────────────┤  ├──────────────────────┤  │
│  │ (O) Video Title One   │  │ (O) Video Title Two   │  │ (O) Drone Reel 4K    │  │
│  │     StreamForge • 2h  │  │     StreamForge • 1d  │  │     Processing...    │  │
│  └───────────────────────┘  └───────────────────────┘  └──────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### Features:
- **YouTube Cinema Watch View:** Clicking any card smoothly transitions into a full watch view with a 16:9 cinema video container.
- **In-Flight Resolution Switcher:** Toggles between **`720p HD`** and **`480p SD`** without restarting playback (preserves `player.currentTime`).
- **Creator Bar & Action Pills:** Verified channel badge, interactive **Subscribe** toggle, **Like / Dislike** counter, **Share** (copies link with toast notification), and direct MP4 **Download**.
- **Collapsible Technical Description:** Displays video metadata, unique UUID, transcode engine details (FFmpeg 7.1 H.264/AAC), and storage bucket paths.
- **Interactive Public Comments:** Add, read, and like comments in real time with local persistence.
- **"Up Next" Sidebar Queue:** YouTube-style queue on the right sidebar allowing instant switching between videos in your library.

---

## 🚀 Automated CI/CD & Release Engineering

The project implements a full GitOps CI/CD delivery lifecycle via GitHub Actions:

```
[Git Commit: Push to main]
            │
            ▼
┌───────────────────────┐
│     Detect Changes    │ (paths-filter: api, worker, frontend)
└───────────┬───────────┘
            ├─── If api/worker changed
            │         │
            │         ▼
            │   ┌───────────────────────┐
            │   │   Lint & Unit Tests   │ (Python 3.11, Ruff, Pytest)
            │   └───────────┬───────────┘
            │               │
            │               ▼
            │   ┌───────────────────────┐
            │   │  Docker Build & Scan  │ (Aqua Security Trivy vulnerability scan)
            │   └───────────┬───────────┘
            │               │
            │               ▼
            │   ┌───────────────────────┐
            │   │  ECR Push & ECS Deploy│ (Keyless AWS OIDC, Rolling update)
            │   └───────────┬───────────┘
            │               │
            │               ▼
            │   ┌───────────────────────┐
            │   │ Circuit Breaker Check │ (Verifies PRIMARY task definition active)
            │   └───────────┬───────────┘
            │               │
            └─── If frontend changed
                      │
                      ▼
                ┌───────────────────────┐
                │ S3 Sync & CF Flush    │ (Injects /api origin, s3 sync, cache invalidation)
                └───────────┬───────────┘
                            │
                            ▼
                ┌───────────────────────┐
                │   Live Smoke Tests    │ (HTTP /health on ALB and CloudFront /api/health)
                └───────────────────────┘
```

### Pipeline Safeguards:
1. **OIDC Keyless Authentication:** Eliminates static `AWS_ACCESS_KEY_ID` secrets in GitHub. AWS STS exchanges the GitHub OIDC token for temporary, short-lived session credentials scoped strictly to this repository (`repo:kartikadhonde/cc-proj:*`).
2. **Container Security Auditing:** Trivy scans every newly built container image before pushing to ECR. Any fixable `CRITICAL` vulnerability terminates the build.
3. **Deployment Circuit Breaker:** Amazon ECS monitors task launch health. If a new container revision crashes or fails health checks, ECS terminates the deployment and automatically rolls back to the prior working task definition.
4. **Automated Smoke Tests:** After deployment, GitHub Actions issues automated curl requests to verify HTTP 200 responses from both the internal ALB and the public CloudFront edge.
5. **One-Click Manual Rollback:** Triggerable via GitHub Actions `rollback.yml` (`workflow_dispatch`) to immediately revert API or Worker services to any target revision.

---

## 💰 Cost Engineering & Free-Tier Optimization

Designed specifically for **AWS Free Tier and student credit budgets**, stripping out unnecessary commercial enterprise bloat:

| Resource | Standard Architecture | StreamForge Architecture | Cost Impact |
|---|---|---|---|
| **VPC NAT Gateways** | 2 NAT Gateways (~$65/mo) | **0 NAT Gateways** (Public subnets + Security Groups) | **Saves ~$65.00 / month** |
| **Worker Compute** | Provisioned EC2 / On-Demand Fargate | **Fargate Spot + Scale to Zero** | **Saves ~70% on compute**; $0.00 idle |
| **Ingress Bandwidth** | Uploads buffered through EC2/ALB | **Direct S3 Presigned PUT Uploads** | **$0.00** ingress data transfer fees |
| **Storage Lifecycle** | Infinite retention of raw files | **S3 Lifecycle: Expire raw files after 3 days** | Storage footprint stays near zero |
| **Container Registry** | Unlimited image versions | **ECR Lifecycle: Retain only 5 latest images** | Minimal storage fees |
| **CloudFront Delivery** | Multiple distributions | **Single distribution with path-based routing** | Consolidated free tier bandwidth |

### Estimated Running Cost for a 2–4 Hour Demo:
- **Application Load Balancer (ALB):** ~$0.0225 / hour ➔ **~$0.09**
- **ECS Fargate API Task:** ~$0.012 / hour ➔ **~$0.05**
- **ECS Fargate Spot Worker:** ~$0.004 / hour ➔ **~$0.01**
- **S3 / SQS / DynamoDB / CloudFront:** Covered by Free Tier ➔ **$0.00**
- **Total Session Cost:** **~$0.15 (15 cents total)**

---

## 📡 REST API Specification

Base URL: `https://<cloudfront-domain>/api` (or `http://localhost:8000` locally)

### 1. Health Probe
```http
GET /health
GET /api/health
```
**Response (200 OK):**
```json
{
  "status": "healthy"
}
```

### 2. Register Video & Request Upload URL
```http
POST /api/videos
Content-Type: application/json

{
  "title": "4K Drone Cinematic Reel"
}
```
**Response (201 Created):**
```json
{
  "video_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "upload_url": "https://video-platform-uploads.s3.amazonaws.com/raw/a1b2c3d4.mp4?X-Amz-Signature=..."
}
```

### 3. List All Videos
```http
GET /api/videos
```
**Response (200 OK):**
```json
[
  {
    "video_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "title": "4K Drone Cinematic Reel",
    "status": "ready",
    "source_key": "raw/a1b2c3d4.mp4",
    "outputs": {
      "720p": "processed/a1b2c3d4/720p.mp4",
      "480p": "processed/a1b2c3d4/480p.mp4"
    },
    "thumbnail_key": "processed/a1b2c3d4/thumbnail.jpg",
    "playback_urls": {
      "720p": "https://d2nsdikkubmfh8.cloudfront.net/processed/a1b2c3d4/720p.mp4",
      "480p": "https://d2nsdikkubmfh8.cloudfront.net/processed/a1b2c3d4/480p.mp4"
    },
    "thumbnail_url": "https://d2nsdikkubmfh8.cloudfront.net/processed/a1b2c3d4/thumbnail.jpg",
    "created_at": "2026-10-18T10:00:00Z",
    "updated_at": "2026-10-18T10:00:45Z"
  }
]
```

### 4. Get Video Details by ID
```http
GET /api/videos/{video_id}
```

---

## 🛑 Disaster Recovery & Clean Teardown

To guarantee that you are **never charged by AWS after your testing session**, run the teardown script:

```powershell
cd d:\MyProjects\cc-proj\video-platform
bash scripts/teardown-aws.sh
```
*(Or navigate to `infra/terraform` and run `terraform destroy -auto-approve`)*

### What Gets Permanently Deleted:
- ✂️ Application Load Balancer (ALB) and target groups *(terminates hourly idle charge)*
- ✂️ CloudFront distribution and Origin Access Controls
- ✂️ ECS Cluster, Fargate services, task definitions, and CloudWatch log groups
- ✂️ S3 buckets (`uploads`, `processed`, `frontend`) and all stored videos
- ✂️ SQS queues (`video-jobs` and `video-jobs-dlq`)
- ✂️ DynamoDB table (`video-platform-videos`)
- ✂️ ECR repositories and container images
- ✂️ VPC, subnets, route tables, and security groups
- **Active AWS hourly billing immediately drops to $0.00.**

---

## 💡 Troubleshooting & Gotchas

### 1. Windows Line Endings (CRLF vs LF)
- **Problem:** Running shell scripts (`init-localstack.sh`, `bootstrap-aws.sh`) inside Docker or Git Bash fails with `\r: command not found` or `/bin/bash^M: bad interpreter`.
- **Solution:** Enforced via repository `.gitattributes` (`*.sh text eol=lf`).

### 2. Port Collisions in Local Testing
- **Problem:** Port `3000` is often occupied by tools like Grafana.
- **Solution:** Frontend is mapped to `3001:80` in `docker-compose.yml`.

### 3. GitHub Actions OIDC Subject Claim Mismatch
- **Problem:** GitHub Actions fails to assume IAM role with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
- **Solution:** In some enterprise/individual accounts, GitHub includes account IDs in the token subject (`repo:owner@id/repo@id:ref:...`). The Terraform IAM role trust policy uses `StringLike` matching `repo:kartikadhonde*cc-proj*:*` to support both formats.

---

## 📄 License
This project is open-source and available under the [MIT License](LICENSE).
