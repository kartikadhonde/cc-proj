This blueprint provides a zero-ambiguity, end-to-end engineering specification for the **Cloud-Based Video Upload, Transcoding, and Streaming Platform with Automated CI/CD**. It is optimized for a **standard AWS Free Tier / Student Credit account**, stripping out expensive bloat (no NAT Gateways, no separate thumbnail container, single-page vanilla frontend) while fulfilling every functional, CI/CD, and architectural requirement in your project documentation.

You can copy and paste this entire blueprint directly into any coding AI (Cursor, Claude Code, GitHub Copilot, Windsurf) and instruct it: *"Generate all files in this specification one directory at a time."*  
---

Part 1: Division of Labor (What You Do vs. What AI Does)  
To prevent getting lost in the AWS Console, **95% of the AWS setup will be automated via Terraform** (written by the AI). You only perform a one-time bootstrap on AWS and GitHub.

| Phase | Who Does It? | Exact Action Required |
| :---- | :---- | :---- |
| **1\. AWS Account & CLI Bootstrap** | **You (Human)** | Create AWS account, set up a \$5 budget alert, create 1 Admin IAM User, generate local access keys for your laptop, and create 1 S3 bucket manually to store Terraform state. |
| **2\. All Application & Infra Code** | **AI** | Writes all Python (FastAPI \+ Worker) code, HTML/JS frontend, Dockerfiles, docker-compose.yml, all 10 Terraform .tf files, and all 3 GitHub Actions .yml workflows. |
| **3\. Provisioning AWS Resources** | **You (running AI code)** | Run terraform init and terraform apply in your terminal. This single command builds the VPC, S3, SQS, DynamoDB, ECR, ECS, ALB, CloudFront, and IAM Roles automatically. |
| **4\. Connecting GitHub to AWS** | **You (Human)** | Copy 4 output values from your terminal after terraform apply and paste them into your GitHub Repository Variables. |
| **5\. Automated Deployment** | **Automated (CI/CD)** | You run git push origin main. GitHub Actions automatically tests, builds Docker images, pushes to ECR, deploys to ECS, and syncs the frontend to S3/CloudFront. |
| **6\. Teardown (Cost Protection)** | **You (Human)** | Run terraform destroy when you finish testing for the day so your ALB and ECS tasks consume **\$0.00** while you sleep. |

Part 2: Complete Repository & File Structure  
Every file listed below has a strict, non-overlapping responsibility. No extra files are needed.

```
video-platform/
├── .github/
│   └── workflows/
│       ├── ci-deploy.yml              # Push to main: test -> build -> Trivy scan -> ECR push -> ECS deploy -> S3 sync
│       ├── rollback.yml               # Manual trigger (workflow_dispatch): reverts ECS service to previous revision
│       └── infra.yml                  # PR trigger: runs `terraform fmt -check` and `terraform plan`
├── infra/
│   └── terraform/
│       ├── main.tf                    # AWS provider (ap-south-1), S3 backend config, common tags
│       ├── variables.tf               # Region, project_name, github_repo ("owner/repo"), container resources
│       ├── network.tf                 # Default/Custom VPC, 2 Public Subnets, IGW, ALB SG, ECS SG (No NAT Gateway!)
│       ├── s3.tf                      # 3 Buckets: uploads (CORS + SQS notification), processed, frontend
│       ├── sqs.tf                     # video-jobs queue (visibility=300s) + video-jobs-dlq (maxReceiveCount=3)
│       ├── dynamodb.tf                # videos table (PAY_PER_REQUEST, partition key: video_id)
│       ├── ecr.tf                     # 2 repos (api, worker) + lifecycle policy (keep last 5 images)
│       ├── iam.tf                     # GitHub OIDC Provider + Role, ECS Execution Role, API Task Role, Worker Task Role
│       ├── ecs.tf                     # Cluster, ALB, Target Group, Listener, API Service, Worker Service (Fargate Spot)
│       ├── autoscaling.tf             # Application Auto Scaling (0 to 3 workers) + CloudWatch Alarms (DLQ & 5xx)
│       ├── cloudfront.tf              # CloudFront distribution with 2 Origins (frontend S3 + processed S3 via OAC)
│       └── outputs.tf                 # Prints ALB_URL, CLOUDFRONT_URL, GITHUB_ROLE_ARN, S3 bucket names
├── services/
│   ├── api/
│   │   ├── app/
│   │   │   ├── __init__.py
│   │   │   ├── main.py                # FastAPI app, CORS, routes: POST /videos, GET /videos, GET /videos/{id}, GET /health
│   │   │   ├── config.py              # Reads env vars (AWS_REGION, DDB_TABLE, UPLOADS_BUCKET, CLOUDFRONT_DOMAIN, etc.)
│   │   │   ├── models.py              # Pydantic schemas for request/response validation
│   │   │   └── aws.py                 # Boto3 helper functions for DynamoDB CRUD & S3 presigned PUT URL generation
│   │   ├── tests/
│   │   │   └── test_api.py            # Pytest unit tests mocking boto3 calls and testing /health & /videos
│   │   ├── Dockerfile                 # Multi-stage Python 3.11-slim build, non-root user, runs uvicorn on port 8000
│   │   └── requirements.txt           # fastapi, uvicorn, boto3, pydantic, pytest, httpx, ruff
│   ├── worker/
│   │   ├── worker/
│   │   │   ├── __init__.py
│   │   │   ├── main.py                # Infinite SQS long-polling loop, SIGTERM handler, idempotency check, status updates
│   │   │   ├── transcoder.py          # Runs subprocess FFmpeg for 720p MP4, 480p MP4, and 1 JPEG thumbnail
│   │   │   └── config.py              # Reads env vars (SQS_QUEUE_URL, DDB_TABLE, UPLOADS_BUCKET, PROCESSED_BUCKET)
│   │   ├── tests/
│   │   │   └── test_worker.py         # Pytest unit tests verifying FFmpeg command construction & SQS JSON parsing
│   │   ├── Dockerfile                 # Python 3.11-slim + apt-get install ffmpeg, non-root user, runs python -m worker.main
│   │   └── requirements.txt           # boto3, pytest, ruff
│   └── frontend/
│       ├── index.html                 # Clean single-page UI: Upload form, Video Grid, Status Badges, HTML5 Video Modal
│       ├── style.css                  # Responsive modern CSS grid layout
│       └── app.js                     # Calls API, uploads file via PUT to S3 presigned URL, polls status every 5s
├── scripts/
│   └── init-localstack.sh             # Automatically creates local S3 buckets, SQS queues, and DDB table on docker-compose up
├── docker-compose.yml                 # LocalStack + api + worker + nginx frontend for 100% free local testing
└── README.md                          # Project overview, architecture diagram, and run instructions
```

## Part 3: End-to-End System Flow & Component Specifications

### 1\. Exact Data Contracts (DynamoDB & S3)

To ensure the API, Worker, and Frontend work together seamlessly without mismatches, every component must adhere to these exact naming conventions:  
**S3 uploads Bucket Key Format:** raw/{video\_id}.mp4  
**S3 processed Bucket Key Formats:**  
720p Video: processed/{video\_id}/720p.mp4  
480p Video: processed/{video\_id}/480p.mp4  
Thumbnail: thumbnails/{video\_id}/thumb.jpg  
**DynamoDB Table Name:** video-platform-videos (Partition Key: video\_id \[String\])  
**DynamoDB Item Schema:**

```json
{
  "video_id": "550e8400-e29b-41d4-a716-446655440000",
  "title": "Sample Test Clip",
  "status": "uploaded | processing | ready | failed",
  "source_key": "raw/550e8400-e29b-41d4-a716-446655440000.mp4",
  "outputs": {
    "720p": "processed/550e8400-e29b-41d4-a716-446655440000/720p.mp4",
    "480p": "processed/550e8400-e29b-41d4-a716-446655440000/480p.mp4"
  },
  "thumbnail_key": "thumbnails/550e8400-e29b-41d4-a716-446655440000/thumb.jpg",
  "attempts": 1,
  "error": null,
  "created_at": "2026-10-17T10:00:00Z",
  "updated_at": "2026-10-17T10:01:15Z"
}
```

### 2\. Backend Service 1: FastAPI Service (services/api)

**Framework & Port:** Python 3.11, FastAPI, running on uvicorn at 0.0.0.0:8000.  
**CORS:** Enabled for \* (allows CloudFront and local browser requests).  
**Endpoints:**  
GET /health → Returns 200 OK with {"status": "healthy"}. Used by ALB Health Checks and CI/CD smoke tests.  
POST /videos → Accepts {"title": "My Video"}.  
Generates a UUID4 video\_id.  
Writes initial item to DynamoDB (status \= "uploaded", source\_key \= "raw/{video\_id}.mp4").  
Calls s3\_client.generate\_presigned\_url('put\_object', Params={'Bucket': UPLOADS\_BUCKET, 'Key': source\_key, 'ContentType': 'video/mp4'}, ExpiresIn=900).  
Returns {"video\_id": video\_id, "upload\_url": presigned\_url}.  
GET /videos → Performs dynamodb.scan(), sorts items by created\_at descending, and attaches full CloudFront URLs (https\://{CLOUDFRONT\_DOMAIN}/{key}) to outputs and thumbnail\_key.  
GET /videos/{video\_id} → Performs dynamodb.get\_item() and returns the single video object with full CloudFront playback URLs.

### 3\. Backend Service 2: Transcoding & Thumbnail Worker (services/worker)

**Cost & Simplicity Optimization:** As explicitly allowed in Section 3.1 of your project doc (*"or a second step in the same worker image"*), the worker extracts the thumbnail immediately after transcoding the video inside the same container. This cuts ECS management overhead and container costs in half.  
**Execution Model:** Standalone Python script running an infinite while not shutting\_down: loop polling SQS (WaitTimeSeconds=20, MaxNumberOfMessages=1).  
**Graceful Shutdown:** Registers Python signal.signal(signal.SIGTERM, handle\_sigterm) so if Fargate Spot or scale-in stops the container, it finishes the current loop cleanly.  
**Step-by-Step Message Processing:**  
Parse S3 Event Notification JSON from SQS message body (ignore s3:TestEvent messages).  
Extract source\_key (raw/{video\_id}.mp4) and parse video\_id from the filename.  
**Idempotency Check (NFR-3):** Fetch record from DynamoDB. If status \== "ready", delete the SQS message immediately and skip.  
Update DynamoDB: set status \= "processing", increment attempts by 1\.  
Download raw/{video\_id}.mp4 from uploads bucket to /tmp/input.mp4.  
Run FFmpeg via subprocess.run(..., check=True):  
**720p:** ffmpeg \-y \-i /tmp/input.mp4 \-vf scale=-2:720 \-c:v libx264 \-preset veryfast \-crf 28 \-c:a aac /tmp/720p.mp4  
**480p:** ffmpeg \-y \-i /tmp/input.mp4 \-vf scale=-2:480 \-c:v libx264 \-preset veryfast \-crf 28 \-c:a aac /tmp/480p.mp4  
**Thumbnail:** ffmpeg \-y \-i /tmp/input.mp4 \-ss 00:00:01.000 \-vframes 1 \-vf scale=640:-1 /tmp/thumb.jpg  
Upload /tmp/720p.mp4, /tmp/480p.mp4, and /tmp/thumb.jpg to the processed S3 bucket.  
Update DynamoDB: set status \= "ready", populate outputs map and thumbnail\_key.  
Call sqs.delete\_message() and delete /tmp/\* files.  
**Failure Handling (FR-9):** If any exception occurs, catch it, update DynamoDB status \= "failed" and error \= str(e), and **do not delete** the SQS message. After the visibility timeout (300s), SQS retries the job up to 3 times before moving it to video-jobs-dlq.

### 4\. Frontend (services/frontend)

**Tech Stack:** Pure HTML5, CSS3, and Vanilla JavaScript (zero Node.js build headaches, instant S3 deployment).  
**Configuration:** Top of app.js defines const API\_BASE\_URL \= "http\://\<ALB\_DNS\_NAME\>"; (automatically injected during CI/CD deploy).  
**UI Features:**  
**Upload Section:** Text input for Video Title, file picker accepting .mp4, and an "Upload Video" button with a progress indicator.  
**Upload Flow:** Calls POST /videos → receives upload\_url → performs fetch(upload\_url, { method: 'PUT', body: file, headers: {'Content-Type': 'video/mp4'} }).  
**Dashboard Grid:** Polls GET /videos every 5 seconds. Displays cards with title, status badge (uploaded \= blue, processing \= yellow pulse, ready \= green, failed \= red), thumbnail image, and resolution selector buttons (Play 720p, Play 480p) that load the CloudFront URL into an HTML5 \<video controls\> player.

## Part 4: AWS Free-Tier & Low-Cost Architecture Decisions

To ensure your student credits last the entire semester and cost almost nothing:  
**Zero NAT Gateways (Saves \~\$32/month):** ECS tasks are placed in **2 Public Subnets** across 2 Availability Zones (ap-south-1a, ap-south-1b) with assign\_public\_ip \= true. Security groups block all inbound traffic to the workers and only allow traffic from the ALB to the API.  
**Single CloudFront Distribution with 2 Origins:** Instead of paying for multiple distributions, one CloudFront distribution serves the static frontend S3 bucket as its Default Behavior (/\*) and routes /processed/\* and /thumbnails/\* to the processed S3 bucket via Origin Access Control (OAC).  
**Scale-to-Zero Fargate Spot Workers:**  
**API Service:** 0.25 vCPU (256 CPU units), 0.5 GB (512 MiB) RAM, desired\_count \= 1 (can be set to 2 during production demo).  
**Worker Service:** 1 vCPU (1024 CPU units), 2 GB (2048 MiB) RAM on **Fargate Spot** (\~70% cheaper than regular Fargate), with desired\_count \= 0 when the SQS queue is empty.  
**Auto-Scaling Rule:** Step/Target scaling on ApproximateNumberOfMessagesVisible. When messages \>= 1, scale out to 1–3 workers; when messages \== 0 for 5 minutes, scale back to 0.  
**S3 & ECR Lifecycle Policies:** uploads bucket automatically deletes raw videos after **3 days**; ECR deletes untagged/old images beyond the most recent **5 images**.

## Part 5: Step-by-Step AWS Manual Configuration (What You Do Yourself)

Before running Terraform or triggering GitHub Actions, perform these **4 one-time setup steps**:

### Step 1: Secure Your Account & Set a Budget Alert (5 Mins)

Log into the AWS Console. Select your region in the top-right corner: **Mumbai (ap-south-1)** (or us-east-1 if you prefer—just stay consistent everywhere).  
Go to **AWS Budgets** → **Create budget** → Choose **Zero spend budget** (or set a monthly budget of **\$5.00**) and enter your email. You will get an email immediately if anything ever accrues charges.

### Step 2: Create an Admin IAM User & Configure Local AWS CLI (5 Mins)

Go to **IAM** → **Users** → **Create user** → Name it terraform-admin.  
Select **Attach policies directly** → Check AdministratorAccess → Create user.  
Click the user → **Security credentials** tab → **Create access key** → Choose **Command Line Interface (CLI)** → Download the Access Key ID and Secret Access Key.  
On your laptop, install AWS CLI and Terraform, then run:

```sh
aws configure
# Paste your Access Key ID, Secret Access Key, default region: ap-south-1, output: json
```

Step 3: Create the Terraform State S3 Bucket (1 Min)  
Terraform needs one tiny S3 bucket to remember what infrastructure it created so both your laptop and GitHub Actions can manage it. Run this single command in your terminal:

```sh
aws s3api create-bucket \
  --bucket video-platform-tfstate-<YOUR_ROLL_NO_OR_INITIALS> \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1
```

*(Put this bucket name into infra/terraform/main.tf under the backend "s3" block).*  
Step 4: Apply Terraform & Connect GitHub Variables (5 Mins)  
Once the AI generates the repository files:  
Run Terraform from your terminal:

```sh
cd infra/terraform
terraform init
terraform apply -var="github_repo=YOUR_GITHUB_USERNAME/YOUR_REPO_NAME"
```

Type yes. Terraform will create everything (including the GitHub OIDC Identity Provider and IAM Role) and print outputs at the end.  
In your GitHub repository, go to **Settings** → **Secrets and variables** → **Actions** → **Variables** tab, and add these Repository Variables from the Terraform output:  
AWS\_REGION: ap-south-1  
AWS\_ROLE\_ARN: *(copy github\_actions\_role\_arn from Terraform output)*  
ECS\_CLUSTER: video-platform-cluster  
ALB\_DNS\_NAME: *(copy alb\_dns\_name from Terraform output)*  
FRONTEND\_BUCKET: *(copy frontend\_bucket\_name from Terraform output)*  
CLOUDFRONT\_DIST\_ID: *(copy cloudfront\_distribution\_id from Terraform output)*  
(Note: If you ever switch to an **AWS Academy Learner Lab** account where IAM Role creation is blocked, simply set use\_learner\_lab \= true in Terraform to use LabRole, and paste AWS\_ACCESS\_KEY\_ID, AWS\_SECRET\_ACCESS\_KEY, and AWS\_SESSION\_TOKEN into GitHub Secrets instead of OIDC).

## Part 6: Master AI Prompt (Copy-Paste to Any Coding AI)

Copy the entire block below and paste it into your coding AI to generate the project without a single follow-up question:

```
You are a Senior Cloud & DevOps Architect. Build the complete codebase for a "Cloud-Based Video Upload, Transcoding and Streaming Platform with Automated CI/CD" on AWS.
Follow these exact specifications with zero placeholders or missing logic:
### 1. Repository Structure
Generate the exact file tree below:
- `services/api/app/{__init__.py, main.py, config.py, models.py, aws.py}`
- `services/api/tests/test_api.py`
- `services/api/{Dockerfile, requirements.txt}`
- `services/worker/worker/{__init__.py, main.py, transcoder.py, config.py}`
- `services/worker/tests/test_worker.py`
- `services/worker/{Dockerfile, requirements.txt}`
- `services/frontend/{index.html, style.css, app.js}`
- `infra/terraform/{main.tf, variables.tf, network.tf, s3.tf, sqs.tf, dynamodb.tf, ecr.tf, iam.tf, ecs.tf, autoscaling.tf, cloudfront.tf, outputs.tf}`
- `.github/workflows/{ci-deploy.yml, rollback.yml, infra.yml}`
- `scripts/init-localstack.sh`
- `docker-compose.yml`
- `README.md`
### 2. Service 1: API (`services/api`)
- Python 3.11 + FastAPI + boto3 + pydantic.
- Environment variables in `config.py`: `AWS_REGION` (default `ap-south-1`), `DDB_TABLE`, `UPLOADS_BUCKET`, `CLOUDFRONT_DOMAIN`, `AWS_ENDPOINT_URL` (optional, used for LocalStack).
- Endpoints:
  - `GET /health`: returns `200 OK` `{"status": "healthy"}`.
  - `POST /videos`: body `{"title": str}`. Creates UUID `video_id`, writes item to DynamoDB with `status="uploaded"`, `source_key=f"raw/{video_id}.mp4"`, `outputs={}`, `thumbnail_key=None`, `attempts=0`, `created_at`, `updated_at`. Generates S3 presigned `put_object` URL for `UPLOADS_BUCKET` (`ExpiresIn=900`, `ContentType="video/mp4"`). Returns `{"video_id": video_id, "upload_url": url}`.
  - `GET /videos`: scans DynamoDB table, returns list sorted by `created_at` desc, dynamically adding `playback_urls` (`https://{CLOUDFRONT_DOMAIN}/{key}`) and `thumbnail_url` when `status == "ready"`.
  - `GET /videos/{video_id}`: fetches single item from DynamoDB and attaches CloudFront URLs.
- Multi-stage `Dockerfile` running as non-root user `appuser` on port `8000` with `HEALTHCHECK`.
- `tests/test_api.py`: unit tests using `unittest.mock` to test `/health`, `POST /videos`, and `GET /videos`.
### 3. Service 2: Worker (`services/worker`)
- Python 3.11 + boto3 + FFmpeg installed via `apt-get` in `Dockerfile` (non-root user `workeruser`).
- Polls SQS queue (`WaitTimeSeconds=20`, `MaxNumberOfMessages=1`) with graceful `SIGTERM` signal handling.
- Parses S3 Event Notification records from SQS message body (skips `s3:TestEvent`).
- Extracts `source_key` (`raw/{video_id}.mp4`) and derives `video_id`.
- Idempotency check: queries DynamoDB for `video_id`; if `status == "ready"`, deletes SQS message and continues.
- Sets `status = "processing"` and increments `attempts` in DynamoDB.
- Downloads source file from `UPLOADS_BUCKET` to `/tmp/{video_id}.mp4`.
- Runs 3 FFmpeg commands via `subprocess.run`:
  1. 720p: `ffmpeg -y -i input -vf scale=-2:720 -c:v libx264 -preset veryfast -crf 28 -c:a aac /tmp/720p.mp4`
  2. 480p: `ffmpeg -y -i input -vf scale=-2:480 -c:v libx264 -preset veryfast -crf 28 -c:a aac /tmp/480p.mp4`
  3. Thumbnail: `ffmpeg -y -i input -ss 00:00:01.000 -vframes 1 -vf scale=640:-1 /tmp/thumb.jpg`
- Uploads outputs to `PROCESSED_BUCKET` at `processed/{video_id}/720p.mp4`, `processed/{video_id}/480p.mp4`, and `thumbnails/{video_id}/thumb.jpg`.
- Updates DynamoDB `status = "ready"`, `outputs = {"720p": ..., "480p": ...}`, `thumbnail_key = ...`.
- Deletes SQS message and cleans up `/tmp` files.
- On exception: updates DynamoDB `status = "failed"` and `error = str(e)`, logs error, and does NOT delete the SQS message so SQS retries and routes to DLQ after 3 attempts.
### 4. Frontend (`services/frontend`)
- Pure HTML/CSS/JS.
- `app.js` uses `window.API_BASE_URL || "http://localhost:8000"`.
- Features: Upload form (Title + MP4 file), step-by-step upload status text, direct `PUT` upload to S3 presigned URL, auto-refreshing video list every 5 seconds, status badges (`uploaded`, `processing`, `ready`, `failed`), thumbnail preview, and HTML5 video player with 720p / 480p resolution switcher.
### 5. Local Development (`docker-compose.yml` & `scripts/init-localstack.sh`)
- `localstack/localstack` container enabling `s3,sqs,dynamodb`.
- `init-localstack.sh` mounted into `/etc/localstack/init/ready.d/` to create buckets (`uploads`, `processed`), queues (`video-jobs-dlq`, `video-jobs`), S3-to-SQS notification, and DynamoDB `videos` table.
- Runs `api`, `worker`, and an `nginx:alpine` container serving `services/frontend` on port `3000`.
### 6. Terraform Infrastructure (`infra/terraform`)
- Optimized for AWS Free Tier / Student Credits:
  - VPC with 2 public subnets across 2 AZs, Internet Gateway, public route table. NO NAT Gateway.
  - Security Groups: ALB SG (inbound 80 from `0.0.0.0/0`), API ECS SG (inbound 8000 from ALB SG only, outbound all), Worker ECS SG (no inbound, outbound all).
  - S3: `uploads` bucket (CORS allowing PUT from `*`, lifecycle rule expiring objects after 3 days, `aws_s3_bucket_notification` sending `s3:ObjectCreated:*` to SQS), `processed` bucket (private, OAC policy for CloudFront), `frontend` bucket (private, OAC policy for CloudFront).
  - SQS: `video-jobs-dlq` and `video-jobs` (`visibility_timeout_seconds = 300`, `redrive_policy` with `maxReceiveCount = 3`, queue policy allowing S3 bucket to `sqs:SendMessage`).
  - DynamoDB: `PAY_PER_REQUEST` table with hash key `video_id` (String).
  - ECR: `video-platform-api` and `video-platform-worker` repositories with lifecycle policy keeping last 5 images.
  - ECS Cluster with `FARGATE` and `FARGATE_SPOT` capacity providers.
  - ECS API Service: 256 CPU, 512 Memory, `desired_count = 1`, `assign_public_ip = true`, behind ALB Target Group (health check `/health`), `deployment_circuit_breaker { enable = true, rollback = true }`.
  - ECS Worker Service: 1024 CPU, 2048 Memory, `FARGATE_SPOT` capacity provider, `desired_count = 0`, `assign_public_ip = true`, `stopTimeout = 120`.
  - Application Auto Scaling on Worker Service: step scaling policy driven by CloudWatch Alarms on SQS `ApproximateNumberOfMessagesVisible` (`>= 1` scales out to 1-3 tasks; `== 0` scales in to 0 tasks).
  - CloudWatch Alarms: DLQ message count `> 0` and ALB 5xx count `> 5`.
  - CloudFront Distribution: Origin 1 (`frontend` S3 bucket as default behavior `/*`, default root object `index.html`), Origin 2 (`processed` S3 bucket with cache behaviors for `/processed/*` and `/thumbnails/*`).
  - IAM: GitHub OIDC Provider (`token.actions.githubusercontent.com`), GitHub Actions Deploy Role restricted to `var.github_repo`, ECS Execution Role, least-privilege API Task Role, and least-privilege Worker Task Role.
### 7. GitHub Actions Workflows (`.github/workflows`)
- `ci-deploy.yml` (on push to `main`):
  1. Path filtering (`dorny/paths-filter`) for `api`, `worker`, and `frontend`.
  2. Lint (`ruff`) and unit tests (`pytest`) for changed Python services.
  3. Build Docker image tagged with `${{ github.sha }}`, scan with Trivy (`aquasecurity/trivy-action`), push to ECR.
  4. Render and deploy updated ECS task definition with `wait-for-service-stability: true`.
  5. Sync `services/frontend` to `FRONTEND_BUCKET` (injecting `ALB_DNS_NAME` into `app.js`) and invalidate CloudFront cache.
  6. Run post-deploy smoke test `curl -f http://$ALB_DNS_NAME/health`.
- `rollback.yml` (`workflow_dispatch` with inputs `service` [api/worker] and optional `revision`):
  - Describes current ECS service task definition, computes previous revision `$((CURRENT_REV - 1))` if not specified, updates ECS service to that revision, waits for service stability, and runs smoke test.
- `infra.yml` (on pull_request modifying `infra/**`):
  - Runs `terraform fmt -check`, `terraform validate`, and `terraform plan`.
Start by generating the Backend Services (`services/api` and `services/worker`) and `docker-compose.yml` completely, then proceed to `services/frontend`, `infra/terraform`, and `.github/workflows`.
```

Part 7: Demo & Verification Checklist (For Your Evaluation)  
When demonstrating the project to your course evaluator, run through this sequence to hit every grading rubric item in your specification:  
**Show Local Portability (NFR-9):** Run docker-compose up \--build locally to prove the entire stack runs offline with LocalStack.  
**Provision Cloud Stack (CD-9):** Run terraform apply to bring the AWS environment online.  
**Show CI/CD Automation (CD-1 to CD-4):** Make a small text change in index.html or main.py, commit, and push to main. Show GitHub Actions authenticating via OIDC, running tests, scanning with Trivy, pushing the commit-SHA image to ECR, and deploying to ECS.  
**Show End-to-End Video Transcoding & Scale-From-Zero (FR-1 to FR-8, NFR-1):**  
Open the CloudFront URL. Show in the AWS ECS Console that Worker running tasks \= 0.  
Upload a 15-second 1080p MP4 clip.  
Show the SQS queue receiving the event, Application Auto Scaling spinning up a Fargate Spot worker from 0 to 1, the status changing from uploaded → processing → ready, and play both 720p and 480p resolutions on the frontend.  
**Show Automatic API Rollback (CD-5):** Push a commit where /health raises an HTTP 500 error. Show the ECS Deployment Circuit Breaker detecting failed ALB health checks and automatically rolling back to the previous revision.  
**Show Manual Worker Rollback & DLQ Redrive (FR-9, FR-10, CD-6):** Trigger rollback.yml from the GitHub Actions UI to revert a service in one click, and click "Start DLQ redrive" in the SQS Console to reprocess failed jobs.  
**Teardown (NFR-8):** Run terraform destroy at the end of your demo to drop ongoing AWS costs back to zero.