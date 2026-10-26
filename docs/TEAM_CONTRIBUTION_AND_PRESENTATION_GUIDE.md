# Cloud-Based Video Platform: 4-Member Team Contribution & Presentation Defense Guide

**Project Title:** Cloud-Based Video Upload, Transcoding, and Streaming Platform with Automated CI/CD  
**Architecture:** Event-Driven Serverless Microservices on AWS  
**Repository:** `kartikadhonde/cc-proj`  
**Target Environment:** Amazon Web Services (AWS) | Primary Region: `us-east-1`  
**Live Production URL:** [https://d13nzb4lwb8eqj.cloudfront.net](https://d13nzb4lwb8eqj.cloudfront.net)  

---

## Executive Summary & Division Matrix

To ensure an equal, technically sound, and impressive division of responsibilities for academic presentations, vivas, and technical project defense, this project is divided across **four specialized engineering roles**:

| Member | Engineering Role | Core Focus Area | Primary AWS Services | Key Codebase Files |
| :--- | :--- | :--- | :--- | :--- |
| **Member 1** | **Cloud Infrastructure & Security Lead** | Terraform IaC, Networking, Edge Delivery & OIDC | CloudFront, VPC, Subnets, ALB, IAM OIDC | `infra/terraform/network.tf`, `cloudfront.tf`, `iam.tf`, `main.tf`, `bootstrap-aws.sh` |
| **Member 2** | **Frontend Engineering & Streaming UX Lead** | Single-Page App, Direct S3 Upload & Player UI | S3 (Frontend Bucket & OAC), CloudFront Edge | `services/frontend/index.html`, `style.css`, `app.js`, `config.js`, `s3.tf` |
| **Member 3** | **Backend API & Database Architecture Lead** | FastAPI REST Server, DynamoDB & LocalStack | ECS Fargate (API), DynamoDB, ECR, S3 Presigning | `services/api/app/main.py`, `app/aws.py`, `dynamodb.tf`, `ecs.tf`, `docker-compose.yml` |
| **Member 4** | **Transcoding, Distributed Systems & CI/CD Lead** | FFmpeg Worker, SQS Queues, Auto Scaling & DevSecOps | SQS & DLQ, ECS Fargate Spot, Auto Scaling, CloudWatch | `services/worker/worker/main.py`, `transcoder.py`, `sqs.tf`, `autoscaling.tf`, `ci-deploy.yml` |

---

# 👤 MEMBER 1: Cloud Infrastructure, Networking & Security Lead

### 1. Responsibilities & Scope
Member 1 is responsible for the foundation of the entire system:
* Designing the cloud network topology (VPC, public subnets, internet routing, security groups).
* Authoring modular **Terraform Infrastructure as Code (IaC)** to provision all 64 AWS resources deterministically.
* Deploying **Amazon CloudFront** as a global CDN and edge router uniting frontend, backend, and media storage under a single domain.
* Enforcing **Zero-Trust Security & Identity Federation (OIDC)** to eliminate hardcoded AWS access keys.
* Writing one-click automation scripts for cloud provisioning (`bootstrap-aws.sh`) and cost teardown (`teardown-aws.sh`).

### 2. Owned File Structure
```
video-platform/infra/terraform/
├── main.tf                    # Provider configuration & S3 remote state locking
├── variables.tf               # Parameter definitions (region, repo, state bucket)
├── terraform.tfvars           # Concrete environment values (us-east-1)
├── outputs.tf                 # Exported endpoints (CloudFront URL, ALB DNS, Role ARN)
├── network.tf                 # VPC, 2 public subnets, Internet Gateway, Security Groups
├── cloudfront.tf              # Global CDN, Origin Access Control, multi-origin routing
└── iam.tf                     # Least-privilege ECS roles & GitHub Actions OIDC federation
video-platform/scripts/
├── bootstrap-aws.sh           # One-command full infrastructure & deploy automation
└── teardown-aws.sh            # Safe resource destruction script (reverts billing to $0.00)
```

### 3. AWS Services Used & Engineering Rationale
* **Amazon CloudFront:** Serves as the single public entrypoint (`d13nzb4lwb8eqj.cloudfront.net`). Eliminates Cross-Origin Resource Sharing (CORS) preflight penalties by hosting the frontend (`/*`), API (`/api/*`), and media (`/processed/*`) on the identical HTTPS origin.
* **Amazon VPC & Subnets:** Isolated virtual network (`10.0.0.0/16`) spanning Availability Zones `us-east-1a` and `us-east-1b`. Uses public subnets with Internet Gateway **without an expensive NAT Gateway**, saving ~$32/month.
* **Application Load Balancer (ALB):** Spreads dynamic API requests across healthy container tasks with health checks on `/health`.
* **AWS IAM & OIDC:** Implements GitHub Actions OpenID Connect federation. AWS mints temporary 15-minute STS credentials for GitHub workflows, meaning **zero permanent AWS access keys are stored in GitHub**.

### 4. Presentation Speaking Script (What to say)
> *"Hello everyone. I am the Cloud Infrastructure and Security Lead for StreamForge. My responsibility was creating the cloud backbone using Terraform Infrastructure as Code and securing our public perimeter.*
>
> *A major distributed systems problem in web platforms is Cross-Origin Resource Sharing (CORS) latency and mixed-content browser blocking. I solved this by deploying Amazon CloudFront as our unified edge entrypoint. Under one domain name, CloudFront routes API calls to our Load Balancer, video playback to S3, and static assets to our frontend bucket.*
>
> *From a networking perspective, I architected a multi-AZ VPC across us-east-1a and us-east-1b. To optimize operational cost, our containers run in public subnets protected by strict security groups, completely eliminating the need for a $32/month AWS NAT Gateway.*
>
> *Finally, regarding security, we store zero AWS access keys in GitHub. I configured AWS IAM OpenID Connect federation so GitHub Actions cryptographically assumes a role using temporary STS tokens."*

### 5. Live Demo Actions (What to show on screen)
1. Open the [AWS CloudFront Console](https://us-east-1.console.aws.amazon.com/cloudfront/v4/home): Show the 3 origins (Frontend S3, Processed S3, ALB) and the Behaviors routing table.
2. Open the [VPC Console](https://us-east-1.console.aws.amazon.com/vpc/home?region=us-east-1#vpcs:): Show `video-platform-vpc`, subnets in two AZs, and security groups.
3. Show `infra/terraform/network.tf` and `cloudfront.tf` in VS Code to explain the IaC definitions.

### 6. Expected Professor / Viva Questions & Model Answers
* **Q1: Why did you use CloudFront instead of letting users access the ALB or S3 directly?**  
  *Answer:* Directly exposing S3 websites lacks SSL and requires public buckets. Exposing the ALB directly creates CORS pre-flight latency between frontend and backend. CloudFront unifies both under one HTTPS origin, enables Origin Access Control (OAC) to keep S3 private, and caches media chunks at worldwide edge locations.
* **Q2: Why didn't you use a NAT Gateway in your VPC?**  
  *Answer:* An AWS NAT Gateway costs ~$32/month plus data processing fees. By placing our ECS Fargate tasks in public subnets with assigned public IPs, but locking down inbound access with strict security groups (allowing only ALB traffic to the API and zero inbound traffic to the worker), we achieve equivalent security for $0/month.

---

# 👤 MEMBER 2: Frontend Engineering & Streaming UX Lead

### 1. Responsibilities & Scope
Member 2 is responsible for everything the user touches and experiences:
* Developing the responsive Single-Page Application (SPA) using modern Vanilla HTML5, CSS3, and JavaScript.
* Creating the **Direct-to-S3 Upload Client** using browser `XMLHttpRequest` to stream video bytes straight to Amazon S3, bypassing web server memory entirely.
* Implementing the **HLS / Multi-Bitrate Video Player** with automatic and manual quality resolution switching (720p / 480p).
* Building real-time video state polling, upload progress bars, search filtering, and local client persistence (`localStorage`) for likes, views, and comments.
* Defining S3 frontend bucket policies and Origin Access Control (OAC).

### 2. Owned File Structure
```
video-platform/services/frontend/
├── index.html                 # Semantic HTML5 layout, video grid, upload modal & player
├── style.css                  # Dark-theme Vanilla CSS design system, glassmorphism & tokens
├── app.js                     # Upload handling, API polling, HLS playback & local storage
└── config.js                  # Dynamic API base URL injection (window.API_BASE_URL)
video-platform/infra/terraform/
└── s3.tf                      # Frontend S3 bucket definition & CloudFront OAC read policies
```

### 3. AWS Services Used & Engineering Rationale
* **Amazon S3 (Frontend Bucket):** Stores static web assets (`index.html`, `style.css`, `app.js`). Public access is completely blocked (`BlockPublicAcls = true`); files can only be accessed through CloudFront via Origin Access Control (OAC).
* **Amazon S3 Presigned Upload Integration:** Instead of uploading multi-gigabyte video files to our backend server, the browser uploads binary files directly to the S3 uploads bucket using temporary presigned URLs.
* **CloudFront Cache Invalidation:** Works with the CDN to ensure frontend updates are instantly visible globally upon deployment.

### 4. Presentation Speaking Script (What to say)
> *"Hello everyone. I am the Frontend Engineering and Streaming UX Lead. I built the client interface that our end-users interact with.*
>
> *In traditional video apps, users upload files to the web server, which crashes the server's memory under heavy traffic. In StreamForge, I implemented direct-to-S3 browser uploads. When a user selects a video, the browser asks the API for a presigned upload URL and streams the raw binary file directly into our S3 uploads bucket using an XMLHttpRequest progress listener.*
>
> *Our frontend is built entirely in Vanilla HTML, CSS, and modern JavaScript without framework bloat. It features a YouTube-inspired dark-mode aesthetic with custom glassmorphism. For video playback, I integrated multi-resolution switching, allowing users to toggle between 720p HD and 480p SD seamlessly.*
>
> *Our static assets are hosted in a secure S3 bucket that blocks all public access and serves files exclusively through CloudFront edge caches."*

### 5. Live Demo Actions (What to show on screen)
1. Open the live site: [https://d13nzb4lwb8eqj.cloudfront.net](https://d13nzb4lwb8eqj.cloudfront.net).
2. Click **"Upload Video"**, drag in an MP4 file, and point out the real-time progress bar.
3. Show how the video card appears with a `"Processing"` badge and automatically updates to `"Ready"` when polling detects completion.
4. Click the video card to open the player and toggle the **720p** and **480p** resolution pills.

### 6. Expected Professor / Viva Questions & Model Answers
* **Q1: What happens if a user uploads a 2 GB video? Does the web server run out of memory?**  
  *Answer:* No. The web server never touches the video file. The frontend requests an S3 presigned PUT URL (a tiny JSON payload). The browser then streams the 2 GB binary directly to Amazon S3 via HTTPS PUT, completely bypassing our API server memory and CPU.
* **Q2: Why did you use Vanilla JavaScript instead of React or Angular?**  
  *Answer:* Vanilla JavaScript produces zero build-step overhead, loads in milliseconds without multi-megabyte bundle downloads, and eliminates framework dependencies while demonstrating core DOM manipulation, asynchronous fetch APIs, and native event listeners.

---

# 👤 MEMBER 3: Backend API Architecture & Database Engineering Lead

### 1. Responsibilities & Scope
Member 3 is responsible for the API gateway and data persistence tier:
* Architecting the high-throughput **FastAPI REST API** with Pydantic request/response validation.
* Modeling the **Amazon DynamoDB NoSQL Database** using a single-table schema with atomic state transitions (`uploaded` ➔ `processing` ➔ `ready` ➔ `failed`).
* Writing cryptographic presigned S3 upload URL generation using the AWS Boto3 SDK.
* Containerizing the API microservice using multi-stage, non-root Docker builds.
* Designing the local development environment using **LocalStack** and **DynamoDB Local** for offline testing.

### 2. Owned File Structure
```
video-platform/services/api/
├── app/main.py                # FastAPI routes: /health, /videos, /videos/upload-url
├── app/aws.py                 # Boto3 client wrappers for DynamoDB & S3 presigned URLs
├── app/config.py              # Pydantic environment configuration (Twelve-Factor App)
├── app/models.py              # Pydantic data schemas (CreateVideoRequest, VideoItem)
├── Dockerfile                 # Multi-stage, non-root lightweight Python 3.11 container
├── tests/test_api.py          # Pytest automated API unit tests using Moto mocks
├── requirements.txt           # Production dependencies (fastapi, uvicorn, boto3)
└── ruff.toml                  # Linter and PEP-8 code standards configuration
video-platform/infra/terraform/
├── dynamodb.tf                # DynamoDB table schema, partition key & on-demand billing
└── ecs.tf                     # ECS Fargate task definition & ALB target group for API
video-platform/
├── docker-compose.yml         # LocalStack & DynamoDB Local container orchestration
└── scripts/init-localstack.sh # Mock AWS resources initialization script
```

### 3. AWS Services Used & Engineering Rationale
* **Amazon DynamoDB:** Stores video metadata in table `video-platform-videos` with `video_id` as the Partition Key. Configured with `PAY_PER_REQUEST` on-demand billing ($0.00 idle cost, single-digit millisecond latency).
* **Amazon ECS Fargate (API Service):** Runs the containerized FastAPI server serverlessly (0.25 vCPU, 512 MB memory) behind the Application Load Balancer.
* **Amazon ECR (API Repo):** Stores immutable API container images tagged with Git commit SHAs.
* **LocalStack:** Simulates S3, SQS, and DynamoDB locally on developers' laptops for free offline testing.

### 4. Presentation Speaking Script (What to say)
> *"Hello everyone. I am the Backend API and Database Architecture Lead. I designed the data layer and REST services that power StreamForge.*
>
> *I built our API microservice with Python FastAPI. FastAPI gives us native asynchronous request handling and automatic Pydantic data validation. The API exposes four primary endpoints: a health probe on /health for the load balancer, video listing on /videos, single video details, and presigned upload URL generation.*
>
> *For our database, we selected Amazon DynamoDB. Relational databases like RDS require dedicated running instances that cost money 24/7. DynamoDB runs in serverless pay-per-request mode, incurring zero cost when idle while providing sub-10ms read/write latency. Each video record tracks the complete lifecycle state: uploaded, processing, ready, or failed.*
>
> *To enable fast local development, I also created our docker-compose environment with LocalStack, allowing us to mock S3, SQS, and DynamoDB locally before deploying to AWS."*

### 5. Live Demo Actions (What to show on screen)
1. Open the [DynamoDB Console](https://us-east-1.console.aws.amazon.com/dynamodbv2/home?region=us-east-1#table?name=video-platform-videos): Click **"Explore table items"** and show existing video rows with `status`, `outputs`, and timestamps.
2. Open the [ECS Cluster Console](https://us-east-1.console.aws.amazon.com/ecs/v2/clusters/video-platform-cluster/services?region=us-east-1): Show `video-platform-api` running as a healthy Fargate service.
3. Show `services/api/app/main.py` in VS Code to explain the presigned URL generation.

### 6. Expected Professor / Viva Questions & Model Answers
* **Q1: Why did you choose DynamoDB over MongoDB or PostgreSQL?**  
  *Answer:* PostgreSQL requires provisioning EC2 instances or RDS clusters with continuous baseline costs ($15-$30/month) and connection pool management. DynamoDB is fully serverless, scales automatically, requires zero maintenance, charges only per read/write unit, and offers single-digit millisecond latency.
* **Q2: How does the API know if a video fails transcoding?**  
  *Answer:* The API doesn't do the transcoding; the background worker does. If FFmpeg fails, the worker updates the item's `status` attribute in DynamoDB to `"failed"` and logs the error message. The frontend polls `/api/videos` and displays an error state to the user.

---

# 👤 MEMBER 4: Transcoding, Distributed Systems & CI/CD Lead

### 1. Responsibilities & Scope
Member 4 is responsible for the background processing engine and automated release pipelines:
* Building the asynchronous **FFmpeg Transcoding Engine** producing 720p and 480p MP4 files with `+faststart` and JPEG thumbnails.
* Designing the **Event-Driven Decoupling Pipeline** using S3 Event Notifications and **Amazon SQS**.
* Implementing **Dead-Letter Queue (DLQ)** retry logic to isolate corrupted video files.
* Setting up **ECS Worker Auto-Scaling (0 to 3 tasks)** driven by CloudWatch queue depth alarms.
* Configuring **Fargate Spot** to achieve a ~70% compute cost reduction.
* Implementing the **GitHub Actions DevSecOps CI/CD Pipeline** with automated Trivy container vulnerability scanning, Ruff linting, Pytest, and automated rollbacks.

### 2. Owned File Structure
```
video-platform/services/worker/
├── worker/main.py             # SQS long-polling daemon & lifecycle status coordinator
├── worker/transcoder.py       # FFmpeg command builder: 720p, 480p, +faststart, thumbnail
├── worker/config.py           # Worker environment configuration settings
├── Dockerfile                 # Multi-stage Dockerfile bundling Python 3.11 & FFmpeg binary
├── tests/test_worker.py       # Pytest unit tests verifying SQS parsing & FFmpeg args
└── ruff.toml                  # Worker linting rules
.github/workflows/
├── ci-deploy.yml              # Main CI/CD pipeline: test, Trivy scan, build, deploy, smoke
├── infra.yml                  # Terraform validation & PR plan generation pipeline
└── rollback.yml               # Automated one-click ECS task definition rollback workflow
video-platform/infra/terraform/
├── sqs.tf                     # video-jobs queue, DLQ (maxReceiveCount=3) & S3 permissions
└── autoscaling.tf             # Step scaling policies (0 -> 3 workers) on SQS queue depth
```

### 3. AWS Services Used & Engineering Rationale
* **Amazon SQS & DLQ:** Decouples video ingestion from processing. Absorbs upload bursts without dropping jobs. Corrupted files that fail 3 times are quarantined in `video-jobs-dlq` for 14 days, preventing infinite crash loops.
* **Amazon ECS Fargate Spot:** Runs transcode workers on spare AWS compute capacity at a **~70% discount**.
* **AWS Application Auto Scaling:** Scales workers from **0 up to 3** based on SQS queue depth, and scales back down to 0 after 5 quiet minutes.
* **Amazon CloudWatch:** Collects container logs (`/ecs/video-platform-worker`) and triggers auto-scaling alarms (`queue-backlog` and `queue-empty`).

### 4. Presentation Speaking Script (What to say)
> *"Hello everyone. I am the Transcoding, Distributed Systems, and CI/CD Lead. I engineered the asynchronous processing pipeline and our automated deployment automation.*
>
> *Video encoding is heavily CPU-intensive. If encoding ran on our web server, one upload would freeze the website. I decoupled the architecture using Amazon SQS. When an upload finishes, S3 drops an event into our video-jobs queue. Our worker daemon uses SQS long-polling to pick up jobs asynchronously.*
>
> *The worker executes FFmpeg to generate two optimized resolutions: 720p HD and 480p SD, using -preset veryfast and CRF 28 for high visual fidelity at compact file sizes. We add the +faststart flag so videos begin streaming immediately before fully downloading. We also extract a JPEG thumbnail at the 1-second mark.*
>
> *To protect against corrupted files, I configured a Dead-Letter Queue with maxReceiveCount = 3. To minimize cost, workers run on Fargate Spot at a 70% discount and auto-scale down to zero when the queue is empty.*
>
> *Finally, our GitHub Actions CI/CD pipeline automatically lints, tests, and scans container images with Trivy for security vulnerabilities before deploying with zero downtime."*

### 5. Live Demo Actions (What to show on screen)
1. Open the [SQS Console](https://us-east-1.console.aws.amazon.com/sqs/v3/home?region=us-east-1#/queues): Show `video-jobs` and `video-jobs-dlq`.
2. Open the [CloudWatch Log Groups](https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups): Open `/ecs/video-platform-worker` to show live FFmpeg transcode logs.
3. Open GitHub Actions in the browser: Show [Run #40367242112](https://github.com/kartikadhonde/cc-proj/actions/runs/40367242112) with all green checkmarks (Trivy scan, ECS deploy, smoke test).

### 6. Expected Professor / Viva Questions & Model Answers
* **Q1: What happens if an uploaded video is corrupted and crashes FFmpeg?**  
  *Answer:* SQS message visibility timeout is 5 minutes. If FFmpeg crashes, the message is not deleted. After 5 minutes, SQS releases the message for retry. After 3 failed attempts (`maxReceiveCount = 3`), SQS automatically routes the poison pill to `video-jobs-dlq` (Dead-Letter Queue) and marks the video as failed in DynamoDB.
* **Q2: Why do workers scale to 0? How do they start back up?**  
  *Answer:* Transcoding is bursty. Leaving Fargate tasks running 24/7 wastes money. CloudWatch alarm `video-platform-queue-backlog` monitors `ApproximateNumberOfMessagesVisible`. When an upload occurs, the alarm fires within 1 minute, triggering Application Auto Scaling to launch 1 to 3 Fargate Spot worker tasks. When queues are empty for 5 minutes, tasks scale back to 0.

---

# 🎯 End-to-End Team Demo Playbook (Order of Presentation)

During your project presentation or lab evaluation, follow this sequential 5-minute team walkthrough:

```
[ Slide 1: Problem & Architecture ]  ──► All Team Members Introduce Themselves
       │
[ Step 1: Member 1 ] ──► Opens AWS CloudFront & VPC (Explains Edge routing & IaC)
       │
[ Step 2: Member 2 ] ──► Opens Live Web App (Uploads MP4, explains direct S3 upload & UX)
       │
[ Step 3: Member 3 ] ──► Opens DynamoDB Console (Shows item queued -> processing in real-time)
       │
[ Step 4: Member 4 ] ──► Opens CloudWatch Logs (Shows FFmpeg encoding & SQS queue consumption)
       │
[ Step 5: Member 2 ] ──► Returns to Web App (Plays the ready video, toggles 720p/480p)
       │
[ Step 6: Member 4 ] ──► Opens GitHub Actions (Shows automated DevSecOps CI/CD pipeline)
       │
[ Conclusion & Q&A ] ──► Team fields examiner questions using the model answers above!
```
