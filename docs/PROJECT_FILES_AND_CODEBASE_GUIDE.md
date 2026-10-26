# Cloud-Based Video Platform: Complete Codebase & File-by-File Technical Guide

**Document Version:** 1.0  
**Target Repository:** `kartikadhonde/cc-proj`  
**Architecture:** Event-Driven Serverless Microservices on AWS  
**Author / Engineering Team:** Cloud Computing Project Team  

---

## Executive Summary

This document provides an exhaustive, engineering-grade walkthrough of **every single file and folder** within this repository. It details:
1. **File Purpose:** What the file does and what code/configuration it contains.
2. **Architectural Rationale:** Why the file exists and why this specific technology/pattern was chosen.
3. **System Interconnections:** How the file interfaces with other microservices, cloud resources, and CI/CD automation.

---

## 1. High-Level Repository Architecture

The project is structured as a decoupled monorepo following modern microservices principles:

```
cc-proj/
├── .github/workflows/          # Automated DevSecOps CI/CD pipelines
├── docs/                       # Project documentation, guides, and compiled Word reports
├── scripts/                    # Automation and document compilation utilities
└── video-platform/             # Core application source code & infrastructure
    ├── infra/terraform/        # Terraform Infrastructure as Code (64 AWS resources)
    ├── scripts/                # One-click cloud bootstrap & cost teardown scripts
    └── services/
        ├── api/                # FastAPI backend microservice (ECS Fargate)
        ├── frontend/           # Vanilla JS/CSS Single-Page Application (S3 + CloudFront)
        └── worker/             # FFmpeg transcoding microservice (ECS Fargate + SQS)
```

---

## 2. Root Configuration & Project Files

### `.gitattributes`
* **Path:** `/.gitattributes`
* **What it does:** Enforces Line Feed (`LF`) line endings on all Unix shell scripts (`*.sh text eol=lf`).
* **Why it is essential:** Developers working on Windows systems check out files with Carriage Return + Line Feed (`CRLF`, `\r\n`). When a shell script with `CRLF` is mounted into a Linux container or run inside LocalStack/AWS, the bash interpreter fails with errors like `\r: command not found` or `bad interpreter`. This file prevents those cross-platform corruption errors.
* **Connections:** Protects `video-platform/scripts/bootstrap-aws.sh`, `teardown-aws.sh`, and `init-localstack.sh`.

---

### `.gitignore`
* **Path:** `/.gitignore`
* **What it does:** Specifies files and patterns that Git should completely ignore, including Python virtual environments (`.venv/`), compiled bytecode (`__pycache__/`, `*.pyc`), Terraform local state and plugin caches (`.terraform/`), and IDE configurations (`.vscode/`, `.idea/`).
* **Why it is essential:** Prevents committing bloated build artifacts, virtual environments, local sensitive files, and conflicting lockfiles into GitHub.
* **Connections:** Keeps the repository lightweight and prevents merge conflicts.

---

### `README.md`
* **Path:** `/README.md`
* **What it does:** The primary entrypoint and overview of the entire project on GitHub. Includes high-level architectural diagrams, features list (adaptive bitrate streaming, presigned uploads, passwordless OIDC), local Docker setup instructions, AWS cloud deployment instructions, and test walkthroughs.
* **Why it is essential:** Provides professors, recruiters, and open-source contributors with an immediate, high-impact understanding of the project.
* **Connections:** References all submodules and links to detailed guides.

---

### `PROJECT_REPORT.md` & `PROJECT_REPORT.docx`
* **Path:** `/PROJECT_REPORT.md` and `/PROJECT_REPORT.docx`
* **What it does:** Full academic research report containing literature reviews of distributed video transcoding, problem statements, mathematical formulations of video segment duration optimization, benchmark comparison tables, security models, and empirical cost analyses.
* **Why it is essential:** Satisfies college/course project submission guidelines and provides rigorous theoretical documentation of the engineering work.
* **Connections:** Generated and maintained via `scripts/build_project_report_docx.py`.

---

### `AWS_ARCHITECTURE_GUIDE.md` & `AWS_ARCHITECTURE_GUIDE.docx`
* **Path:** `/AWS_ARCHITECTURE_GUIDE.md` and `/AWS_ARCHITECTURE_GUIDE.docx`
* **What it does:** Complete AWS cloud manual explaining all 11 AWS services used in the project, design trade-offs against alternative cloud offerings, and a click-by-click navigation guide through the AWS Management Console (`us-east-1`).
* **Why it is essential:** Enables anyone evaluating the project to log into AWS and inspect, verify, and understand the live cloud resources.
* **Connections:** Generated via `scripts/build_aws_guide_docx.py`.

---

### `cc project.md`
* **Path:** `/cc project.md`
* **What it does:** The original college project requirements specification, syllabus requirements, evaluation rubric, and milestones.
* **Why it is essential:** Preserved as the source of truth to ensure every single project criteria and rubric requirement is completely fulfilled.

---

### `IEEE_RESEARCH_PAPER.tex`, `IEEE_RESEARCH_PAPER.md` & `.docx`
* **Path:** `/IEEE_RESEARCH_PAPER.*`
* **What it does:** Two-column IEEE Transactions/Conference format research paper detailing the design, implementation, and empirical benchmark evaluation of the distributed video transcoding platform.
* **Why it is essential:** Formatted specifically for submission to computer science academic conferences or IEEE journals.

---

### `RESEARCH_PAPER.md` & `RESEARCH_PAPER.docx`
* **Path:** `/RESEARCH_PAPER.md` and `/RESEARCH_PAPER.docx`
* **What it does:** Comprehensive extended research paper diving deeply into adaptive bitrate algorithms, HLS chunking mechanics, SQS message queuing dynamics, and DevSecOps automated vulnerability scanning.

---

## 3. Automation & Compilation Scripts (`scripts/`)

| File | Exact Purpose & Internal Mechanics | Why It Is Important |
| :--- | :--- | :--- |
| **`scripts/build_aws_guide_docx.py`** | Python script utilizing `python-docx` to read `AWS_ARCHITECTURE_GUIDE.md` and compile it into a styled Word document (`AWS_ARCHITECTURE_GUIDE.docx`) with 1-inch margins, navy headers, Consolas code blocks, and custom table shading (`#EBF2F7`). | Automates generating professional offline Word manuals without manual copy-pasting. |
| **`scripts/build_project_report_docx.py`** | Python script that reads `PROJECT_REPORT.md` and compiles it into `PROJECT_REPORT.docx` with academic typography, table formatting, and code styling. | Enables instant recompilation of the master project report Word file whenever documentation is updated. |
| **`scripts/build_ieee_docx.py`** | Compiles `IEEE_RESEARCH_PAPER.md` into formatted Word document `IEEE_RESEARCH_PAPER.docx`. | Generates IEEE-styled academic paper deliverables. |
| **`scripts/build_paper_docx.py`** | Compiles `RESEARCH_PAPER.md` into formatted Word document `RESEARCH_PAPER.docx`. | Automates compilation for the extended research paper. |

---

## 4. GitHub Actions DevSecOps CI/CD (`.github/workflows/`)

### `.github/workflows/ci-deploy.yml` (Main Deployment Pipeline)
* **Trigger:** Pushes to the `main` branch or manual `workflow_dispatch`.
* **Internal Mechanics & Jobs:**
  1. **`changes` (Path Filtering):** Uses `dorny/paths-filter@v3` to inspect git diffs. If only `services/frontend/` changed, it deploys the frontend in 15 seconds, skipping Docker builds and Python tests entirely.
  2. **`test` (Lint & Pytest):** Sets up Python 3.11 with pip caching. Runs `ruff check .` for static analysis, `ruff format --check .` for code formatting, and `pytest -v` for unit tests.
  3. **`deploy` (Container Build & DevSecOps Scan):**
     * Builds Docker images tagged with the Git commit SHA (`${{ github.sha }}`).
     * **Trivy Vulnerability Scan:** Runs Aqua Security's Trivy scanner inside an isolated container *before* AWS credentials exist in the runner. Exits with code 1 if any fixable **CRITICAL** vulnerability is detected.
     * **AWS OIDC Login:** Assumes IAM role `video-platform-github-actions` via STS token exchange (zero static passwords/keys).
     * **ECR Push:** Pushes the verified image to Amazon ECR.
     * **ECS Rolling Deploy:** Initiates rolling update on ECS Fargate using `amazon-ecs-deploy-task-definition@v2`. Fargate launches the new task, verifies health check `/health`, shifts traffic, and gracefully stops the old task.
  4. **`frontend` (Static S3 Sync & CDN Invalidation):**
     * Injects the runtime API URL into `config.js` (`window.API_BASE_URL = "/api"`).
     * Syncs `services/frontend/` to the S3 bucket with `--delete` and cache-control headers.
     * Creates a CloudFront invalidation for `/*` so edge caches serve the new code immediately.
  5. **`smoke-test`:**
     * Performs automated HTTP health checks against both the ALB (`http://$ALB/health`) and the CloudFront CDN (`https://$CF/api/health`).

---

### `.github/workflows/infra.yml` (Terraform CI Pipeline)
* **Trigger:** Pull Requests modifying `video-platform/infra/**`.
* **Internal Mechanics:** Sets up Terraform 1.10.5, runs `terraform fmt -check`, `terraform validate`, and generates a `terraform plan` against the remote S3 state bucket. It posts the diff directly into the PR review summary.
* **Why it is essential:** Prevents broken infrastructure definitions or accidental resource deletions from being merged into production.

---

### `.github/workflows/rollback.yml` (One-Click Emergency Rollback)
* **Trigger:** Manual execution via `workflow_dispatch` selecting service (`api` or `worker`) and optional revision number.
* **Internal Mechanics:** Computes `target_revision = current_revision - 1`. Updates the ECS service with the previous task definition revision, waits for service stability, and runs automated health checks.
* **Why it is essential:** Provides immediate production recovery in under 60 seconds if a bug bypasses testing.

---

## 5. Infrastructure as Code (`video-platform/infra/terraform/`)

Every cloud resource is declared declaratively across modular `.tf` files:

### `main.tf`
* **What it does:** Declares the minimum Terraform version (`>= 1.5.0`), required provider `hashicorp/aws (~> 5.80)`, S3 remote backend configuration, and sets common resource tags (`Project = "video-platform"`).
* **Why it is there:** Centralizes provider initialization and ensures all resources inherit consistent naming conventions.

### `variables.tf`
* **What it does:** Declares input variables: `aws_region` (default `us-east-1`), `github_repo`, `tf_state_bucket`, and `use_learner_lab`.
* **Why it is there:** Decouples configuration from code, making the infrastructure portable to any AWS account.

### `terraform.tfvars`
* **What it does:** Supplies concrete values for our active environment:
  ```hcl
  aws_region      = "us-east-1"
  github_repo     = "kartikadhonde/cc-proj"
  tf_state_bucket = "video-platform-tfstate-242201307132"
  ```
* **Why it is there:** Provides the active parameters used by Terraform during execution.

### `outputs.tf`
* **What it does:** Exports computed cloud resource values: `cloudfront_url`, `alb_dns_name`, `github_actions_role_arn`, S3 bucket names, ECR URLs, and SQS queue URLs.
* **Why it is there:** Passes dynamically created AWS resource ARNs to GitHub Actions and user terminal scripts.

### `network.tf`
* **What it does:** Creates `video-platform-vpc` (`10.0.0.0/16`), two public subnets in `us-east-1a` and `us-east-1b`, Internet Gateway, route tables, and 3 security groups:
  1. `alb_sg`: Inbound HTTP 80 from everywhere (`0.0.0.0/0`).
  2. `api_sg`: Inbound HTTP 8000 *strictly* from `alb_sg`.
  3. `worker_sg`: Outbound-only traffic to AWS service endpoints.
* **Why it is there:** Enforces network isolation and defense-in-depth firewalls.

### `s3.tf`
* **What it does:** Creates the 3 S3 buckets:
  1. `frontend`: Static UI with public access blocked; reads allowed exclusively via CloudFront OAC.
  2. `uploads`: Raw upload buffer with SQS event notification on `raw/*` and a 7-day automatic file expiration lifecycle rule.
  3. `processed`: Transcoded HLS playlists and `.ts` chunks with CloudFront OAC read policies.
* **Why it is there:** Segregates storage concerns, protects raw assets, and saves costs via automatic file expiration.

### `sqs.tf`
* **What it does:** Provisions `video-jobs` queue (30-second visibility timeout, 14-day retention) and `video-jobs-dlq` (Dead Letter Queue) with a redrive policy (`maxReceiveCount = 3`). Grants S3 permission to publish `s3:ObjectCreated:*` events.
* **Why it is there:** Implements reliable asynchronous decoupling and isolates corrupted video files to prevent infinite retry loops.

### `dynamodb.tf`
* **What it does:** Provisions the `video-platform-videos` DynamoDB table with `id` (String) as Partition Key and `PAY_PER_REQUEST` on-demand billing.
* **Why it is there:** Stores video metadata and coordinates the lifecycle state machine with single-digit millisecond latency and $0.00 idle cost.

### `ecs.tf`
* **What it does:** Creates `video-platform-cluster`, Fargate task definitions for API (0.25 vCPU, 512MB) and Worker (0.25 vCPU, 512MB), ECS services, Application Load Balancer (`video-platform-alb`), listener rules, and Target Groups with `/health` checks.
* **Why it is there:** Runs Docker containers serverlessly without managing underlying Linux virtual machines.

### `ecr.tf`
* **What it does:** Provisions private Docker registries `video-platform-api` and `video-platform-worker` with image retention policies keeping the last 10 images.
* **Why it is there:** Stores immutable container images pushed by CI/CD.

### `cloudfront.tf`
* **What it does:** Provisions CloudFront distribution `E12B1QG780JDSL` with Origin Access Control (OAC) and 3 routing behaviors:
  * `/api/*` ➔ ALB (no caching, forwards all HTTP headers)
  * `/hls/*` ➔ Processed S3 bucket (optimized media caching)
  * Default `*` ➔ Frontend S3 bucket (SPA web caching)
* **Why it is there:** Provides global edge caching, HTTPS termination, and eliminates CORS by hosting frontend and backend on one domain.

### `autoscaling.tf`
* **What it does:** Configures AWS Application Auto Scaling to scale `video-platform-worker` between 0 and 3 tasks based on CloudWatch SQS queue backlog alarms (`video-platform-queue-backlog` and `video-platform-queue-empty`).
* **Why it is there:** Automatically matches compute resources to user upload volume, scaling to 0 when idle to eliminate costs.

### `iam.tf`
* **What it does:** Implements Least-Privilege IAM Roles:
  * `ecs_execution`: Pulls images from ECR and writes logs to CloudWatch.
  * `api_task`: Accesses DynamoDB and generates presigned PUT URLs for `raw/*`.
  * `worker_task`: Polls SQS, downloads raw S3 objects, uploads HLS streams, updates DynamoDB.
  * `github_actions`: Configures OIDC trust policy supporting wildcard repo matching for secure GitHub Actions deployment.
* **Why it is there:** Enforces enterprise security and eliminates hardcoded AWS access keys.

---

## 6. Local Development & Deployment Scripts (`video-platform/`)

| File | What It Does | Why We Have It |
| :--- | :--- | :--- |
| **`video-platform/docker-compose.yml`** | Defines local multi-container stack: LocalStack (mocking S3 and SQS on port 4566), DynamoDB Local (port 8000), API (port 8001), Worker, and Frontend (port 3001). | Allows full offline development and testing without internet access or AWS cloud charges. |
| **`video-platform/scripts/init-localstack.sh`** | Bash script executed inside LocalStack on startup. Creates mock S3 buckets (`video-platform-uploads`, `video-platform-processed`), SQS queue (`video-jobs`), and DynamoDB table (`video-platform-videos`). | Seeds the local environment with identical cloud resources automatically. |
| **`video-platform/scripts/bootstrap-aws.sh`** | Automated cloud setup script: validates AWS and GitHub CLI logins, creates S3 remote state bucket, runs `terraform apply -auto-approve`, updates GitHub Actions secrets/variables, pushes code, and starts the deployment workflow. | Re-provisions the entire production cloud architecture with a single terminal command. |
| **`video-platform/scripts/teardown-aws.sh`** | Automated cloud teardown script: empties all S3 buckets (including versioned objects) and runs `terraform destroy -auto-approve`. | Deletes all 64 cloud resources cleanly to return active hourly billing to **$0.00**. |

---

## 7. Frontend Web Application (`video-platform/services/frontend/`)

### `index.html`
* **What it does:** Semantic HTML5 Single-Page Application layout. Contains the navigation header, live system health pill, video card grid, upload modal with drag-and-drop, and full-screen video player with resolution controls.
* **Why it is there:** The user interface rendered in the browser.

### `style.css`
* **What it does:** Modern dark-theme design system using Vanilla CSS. Implements glassmorphism, HSL color tokens, CSS grid layouts, smooth modal transitions, and strict `[hidden] { display: none !important; }` rules.
* **Why it is there:** Delivers a clean, responsive UI without relying on heavy frontend frameworks like Bootstrap or Tailwind.

### `app.js`
* **What it does:** Client-side JavaScript:
  1. Calls `GET /api/videos` to render video cards.
  2. Handles uploads: calls `POST /api/videos/upload-url` to receive an S3 presigned PUT URL, uploads binary video directly to S3 via `XMLHttpRequest` with progress tracking.
  3. Polls video status every 3 seconds until state reaches `ready`.
  4. Initializes `hls.js` to render multi-bitrate HLS streaming with manual/auto quality selection.
* **Why it is there:** Connects user actions directly to the API and S3.

### `config.js`
* **What it does:** Runtime configuration declaring `window.API_BASE_URL = "/api";`.
* **Why it is there:** Decouples frontend JavaScript from hardcoded backend URLs, allowing seamless switching between local Docker (`http://localhost:8001`) and CloudFront CDN.

---

## 8. API Microservice (`video-platform/services/api/`)

### `app/main.py`
* **What it does:** FastAPI application exposing core REST endpoints:
  * `GET /health`: Health check endpoint queried by ALB and CloudFront.
  * `GET /videos`: Scans DynamoDB and returns all uploaded video records.
  * `POST /videos/upload-url`: Generates a UUID, records video state as `queued` in DynamoDB, and mints an S3 presigned PUT URL valid for 15 minutes.
  * `GET /videos/{id}`: Retrieves single video metadata.
* **Why it is there:** Serves as the gateway for all dynamic platform interactions.

### `app/aws.py`
* **What it does:** Boto3 client wrappers for Amazon DynamoDB and Amazon S3. Automatically configures custom endpoint URLs when running against LocalStack.
* **Why it is there:** Centralizes AWS SDK interactions and abstracts local vs cloud differences.

### `app/config.py`
* **What it does:** Uses `pydantic-settings` to load and validate environment variables: `UPLOADS_BUCKET`, `DYNAMODB_TABLE`, `AWS_REGION`, and optional `AWS_ENDPOINT_URL`.
* **Why it is there:** Follows Twelve-Factor App methodology for environment-driven configuration.

### `app/models.py`
* **What it does:** Pydantic schemas defining `VideoItem`, `UploadUrlRequest`, and `UploadUrlResponse`.
* **Why it is there:** Enforces strict type validation and automatic Swagger/OpenAPI documentation generation.

### `Dockerfile`
* **What it does:** Multi-stage Docker build packaging Python 3.11-slim, installing dependencies, and running Uvicorn as an unprivileged non-root user (`appuser`).
* **Why it is there:** Produces secure, lightweight container images deployed to ECS Fargate.

### `requirements.txt` & `requirements-dev.txt`
* **What it does:** `requirements.txt` specifies production dependencies (`fastapi`, `uvicorn`, `boto3`, `pydantic-settings`). `requirements-dev.txt` specifies testing packages (`pytest`, `httpx`, `ruff`, `moto`).
* **Why it is there:** Separates lean production image dependencies from development/testing tools.

### `tests/test_api.py`
* **What it does:** Pytest test suite using Moto to mock S3 and DynamoDB in-memory, testing `/health`, `/videos`, and `/videos/upload-url`.
* **Why it is there:** Validates API logic automatically in CI/CD before any deployment occurs.

---

## 9. Transcode Worker Microservice (`video-platform/services/worker/`)

### `worker/main.py`
* **What it does:** Background daemon process. Long-polls SQS queue `video-jobs` (`WaitTimeSeconds = 20`), parses S3 `ObjectCreated` event notifications, updates DynamoDB status to `processing`, triggers FFmpeg transcoding, and marks state as `ready` upon completion.
* **Why it is there:** Consumes background transcoding tasks asynchronously without blocking the user-facing web API.

### `worker/transcoder.py`
* **What it does:** The multimedia processing engine. Executes FFmpeg via Python `subprocess`:
  1. Probes input video stream dimensions.
  2. Generates 3 adaptive bitrate HLS renditions:
     * **1080p** (1920x1080, 5000 kbps)
     * **720p** (1280x720, 2800 kbps)
     * **360p** (640x360, 800 kbps)
  3. Segments video into 3-second `.ts` transport stream chunks.
  4. Generates variant playlists and master index `master.m3u8`.
  5. Uploads all generated files to the processed S3 bucket.
* **Why it is there:** Transforms raw MP4 video into industry-standard HTTP Live Streaming (HLS) formats for seamless adaptive streaming across all devices.

### `worker/config.py`
* **What it does:** Pydantic configuration loading `JOBS_QUEUE_URL`, `UPLOADS_BUCKET`, `PROCESSED_BUCKET`, `DYNAMODB_TABLE`, and `AWS_REGION`.
* **Why it is there:** Injects cloud and local queue/bucket coordinates into the worker.

### `Dockerfile`
* **What it does:** Multi-stage Docker build installing Python 3.11-slim, downloading and bundling the standalone static `ffmpeg` and `ffprobe` binaries, and configuring a non-root runner.
* **Why it is there:** Packages both Python runtime and FFmpeg multimedia tools into a single serverless container runnable on ECS Fargate.

### `tests/test_worker.py`
* **What it does:** Unit tests validating SQS event message parsing, FFmpeg command argument construction, and DynamoDB status transitions using Moto mocks.
* **Why it is there:** Ensures transcode worker logic is thoroughly regression-tested in CI before deployment.
