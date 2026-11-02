# StreamForge: Complete AWS Cloud Architecture, Service Rationale, Interconnections & Live Console Demonstration Master Guide

**Project Name:** StreamForge — Cloud-Based Video Upload, Transcoding, and Streaming Platform  
**Target Audience:** All Team Members, Presenters, Evaluators & Examiners  
**Target Environment:** Amazon Web Services (AWS) | Primary Region: `us-east-1` (US East - N. Virginia)  
**AWS Account ID:** `242201307132`  
**Active Production CloudFront URL:** [https://d31pege4389vaq.cloudfront.net](https://d31pege4389vaq.cloudfront.net)  

---

## Table of Contents
1. [Executive Blueprint & System Overview](#1-executive-blueprint--system-overview)
2. [Deep Dive: The 11 AWS Services (What, Why & Trade-offs)](#2-deep-dive-the-11-aws-services-what-why--trade-offs)
   - [2.1 Amazon CloudFront (Global Edge CDN & Router)](#21-amazon-cloudfront-global-edge-cdn--router)
   - [2.2 Amazon S3 (Triple-Bucket Storage Strategy)](#22-amazon-s3-triple-bucket-storage-strategy)
   - [2.3 Amazon SQS & Dead-Letter Queue (Asynchronous Decoupling)](#23-amazon-sqs--dead-letter-queue-asynchronous-decoupling)
   - [2.4 Amazon ECS on AWS Fargate & Fargate Spot (Serverless Compute)](#24-amazon-ecs-on-aws-fargate--fargate-spot-serverless-compute)
   - [2.5 Amazon DynamoDB (Single-Digit Millisecond NoSQL Database)](#25-amazon-dynamodb-single-digit-millisecond-nosql-database)
   - [2.6 Application Load Balancer (ALB) & Target Groups](#26-application-load-balancer-alb--target-groups)
   - [2.7 Amazon Elastic Container Registry (ECR)](#27-amazon-elastic-container-registry-ecr)
   - [2.8 Amazon CloudWatch (Logs, Metrics & Alarms)](#28-amazon-cloudwatch-logs-metrics--alarms)
   - [2.9 AWS Application Auto Scaling (Queue-Driven 0 to 3 Scaling)](#29-aws-application-auto-scaling-queue-driven-0-to-3-scaling)
   - [2.10 AWS IAM & GitHub Actions OIDC (Zero-Key Security)](#210-aws-iam--github-actions-oidc-zero-key-security)
   - [2.11 Amazon VPC, Subnets & Security Groups (Isolated Networking)](#211-amazon-vpc-subnets--security-groups-isolated-networking)
3. [How Everything is Connected (The 8-Stage Lifecycle Journey)](#3-how-everything-is-connected-the-8-stage-lifecycle-journey)
4. [Step-by-Step AWS Management Console Live Demo Guide](#4-step-by-step-aws-management-console-live-demo-guide)
   - [Stop 1: CloudFront Distribution](#stop-1-cloudfront-distribution)
   - [Stop 2: S3 Triple-Bucket Storage](#stop-2-s3-triple-bucket-storage)
   - [Stop 3: SQS Queues & Dead-Letter Queue](#stop-3-sqs-queues--dead-letter-queue)
   - [Stop 4: ECS Fargate Services & Tasks](#stop-4-ecs-fargate-services--tasks)
   - [Stop 5: DynamoDB Table Items](#stop-5-dynamodb-table-items)
   - [Stop 6: Application Load Balancer & Health Checks](#stop-6-application-load-balancer--health-checks)
   - [Stop 7: CloudWatch Logs & Auto-Scaling Alarms](#stop-7-cloudwatch-logs--auto-scaling-alarms)
   - [Stop 8: VPC Networking & Security Groups](#stop-8-vpc-networking--security-groups)
5. [The "Showstopper" 3-Minute Live Action Walkthrough](#5-the-showstopper-3-minute-live-action-walkthrough)
6. [Top 12 AWS Defense & Viva Questions Answered](#6-top-12-aws-defense--viva-questions-answered)

---

## 1. Executive Blueprint & System Overview

StreamForge is an **event-driven, serverless video streaming platform** deployed on Amazon Web Services. It transforms raw video uploads into dual-rendition streaming media (`720p` HD and `480p` SD) with automatic thumbnail extraction and global Content Delivery Network (CDN) distribution.

### The Complete Connection Topology
```
[ User Web Browser ]
       │
       ▼ (1. Access Webpage: /*)
[ Amazon CloudFront CDN (Global Edge) ] ──(Origin: S3)──► [ S3: video-platform-frontend ]
       │
       ▼ (2. Request Presigned Upload URL: /api/videos)
[ Application Load Balancer (ALB) ]
       │
       ▼ (Forward /api/* to Port 8000)
[ Amazon ECS Fargate: video-platform-api ] ──(Write status: "uploaded")──► [ Amazon DynamoDB ]
       │
       ▼ (Returns S3 Presigned PUT URL valid for 15 min)
[ User Web Browser ]
       │
       ▼ (3. Direct Binary PUT Upload: raw/{video_id}.mp4)
[ S3: video-platform-uploads-242201307132 ]
       │
       ▼ (4. s3:ObjectCreated:* Event Notification)
[ Amazon SQS: video-jobs ] ◄── (Queue Depth Alarm: visible >= 1) ──► [ CloudWatch Metric Alarm ]
       │                                                                      │
       ▼ (5. SQS Long-Polling: WaitTimeSeconds = 20)                          ▼ (Step Scaling)
[ ECS Fargate Spot: video-platform-worker ] ◄──────────────────── [ AWS Application Auto Scaling ]
       │                                                                  (Scales 0 -> 1 -> 2 -> 3)
       ├──► 6. Downloads raw .mp4 to local scratch space
       ├──► 7. Executes FFmpeg (720p, 480p, +faststart, 640px JPEG thumbnail)
       ├──► 8. Uploads renditions ──► [ S3: video-platform-processed-242201307132 ]
       ├──► 9. Updates state: "ready" + playback URLs ──► [ Amazon DynamoDB ]
       └──► 10. Deletes SQS message
       │
[ User Web Browser ]
       │
       ▼ (11. Streams Video Playback: /processed/{id}/720p.mp4)
[ Amazon CloudFront CDN ] ──(Origin: S3 Processed via OAC)──► [ S3: video-platform-processed ]
```

---

## 2. Deep Dive: The 11 AWS Services (What, Why & Trade-offs)

Every single AWS service in this architecture was deliberately selected based on engineering trade-offs between **latency, fault isolation, operational complexity, and cloud cost**.

---

### 2.1 Amazon CloudFront (Global Edge CDN & Router)
* **What it is:** A global Content Delivery Network (CDN) with hundreds of edge Points of Presence (PoPs) worldwide that caches web content and media close to viewers.
* **Why we use it:**
  1. **Unified Hostname & Elimination of CORS:** CloudFront acts as the single public domain (`d31pege4389vaq.cloudfront.net`). It routes `/api/*` to the ALB, `/processed/*` to the media S3 bucket, and `/*` to the frontend S3 bucket. Because everything shares the identical origin, the web browser **never makes cross-origin requests**, eliminating slow CORS `OPTIONS` preflight checks.
  2. **Edge Media Caching:** Video files (`720p.mp4`, `480p.mp4`, `thumb.jpg`) are immutable. CloudFront caches them at edge locations, so viewers stream from local edge caches rather than hitting S3. This cuts playback latency by up to 80% and drastically lowers S3 egress bandwidth costs.
  3. **Origin Access Control (OAC):** Keeps our S3 buckets completely private. The public internet cannot access our S3 buckets directly; only authenticated CloudFront edge requests signed via AWS SigV4 are allowed.
* **Alternative considered:** Directly exposing the Application Load Balancer and S3 website hosting.
* **Why rejected:** Exposing S3 directly requires making buckets public (major security risk), lacks custom SSL, and forces the browser into cross-origin requests between the website and the API.

---

### 2.2 Amazon S3 (Triple-Bucket Storage Strategy)
* **What it is:** Scalable, highly durable (99.999999999% - 11 9's) object storage.
* **Why we use it:**
  We segregate storage into **three specialized buckets** to isolate access patterns and lifecycles:
  1. **Frontend Bucket (`video-platform-frontend-242201307132`):** Holds static web files (`index.html`, `style.css`, `app.js`, `config.js`). 100% private, accessible exclusively by CloudFront via OAC.
  2. **Uploads Ingestion Buffer (`video-platform-uploads-242201307132`):** Receives binary uploads directly from users via presigned URLs. Configured with:
     * **S3 Event Notification:** Automatically drops a message into SQS whenever a file is created under `raw/*`.
     * **7-Day Lifecycle Rule:** Automatically expires and purges raw video files after 7 days, eliminating redundant storage costs once videos are transcoded.
  3. **Processed Media Bucket (`video-platform-processed-242201307132`):** Stores transcoded `720p.mp4`, `480p.mp4`, and `thumb.jpg` files. Public access blocked; read access granted exclusively to CloudFront.
* **Alternative considered:** Storing video files on Elastic Block Store (EBS) or Elastic File System (EFS).
* **Why rejected:** EBS volumes are tied to a single instance and cannot scale dynamically across multiple worker containers. EFS is significantly more expensive per gigabyte than S3.

---

### 2.3 Amazon SQS & Dead-Letter Queue (Asynchronous Decoupling)
* **What it is:** Fully managed, distributed message queuing service.
* **Why we use it:**
  1. **Asynchronous Decoupling:** When a video upload finishes, S3 publishes an event to the `video-jobs` queue. The API responds to the user immediately (in ~50ms) without waiting for transcoding.
  2. **Traffic Burst Shock Absorber:** If 100 users upload files simultaneously, SQS absorbs the burst without dropping a single job, allowing workers to consume tasks steadily.
  3. **Dead-Letter Queue (`video-jobs-dlq`):** If an unparseable or corrupted video crashes the worker 3 times (`maxReceiveCount = 3`), SQS moves the message to the DLQ (14-day retention). This isolates "poison pills" and prevents infinite crash loops that waste CPU and run up AWS bills.
  4. **Long Polling (`WaitTimeSeconds = 20`):** Workers keep connections open for up to 20 seconds, eliminating empty receive calls and reducing AWS API request billing by >95%.
* **Alternative considered:** Calling the worker directly via HTTP REST or using Apache Kafka / RabbitMQ.
* **Why rejected:** Direct HTTP calls are tightly coupled; if the worker is busy or crashes, the upload fails. RabbitMQ and Kafka require managing dedicated broker clusters 24/7 with continuous hourly costs. SQS is 100% serverless, charges only per request, and costs $0.00 when idle.

---

### 2.4 Amazon ECS on AWS Fargate & Fargate Spot (Serverless Compute)
* **What it is:** Container orchestration engine running serverless compute (AWS Fargate).
* **Why we use it:**
  * We run Docker containers without provisioning, managing, or patching EC2 virtual machines.
  * **API Service (`video-platform-api`):** Runs FastAPI on standard Fargate (0.25 vCPU, 512 MB RAM) behind the ALB for predictable low-latency web serving.
  * **Worker Service (`video-platform-worker`):** Runs Python + FFmpeg on **Fargate Spot**, using spare AWS capacity at a **~70% discount**.
  * **Graceful Spot Interruption Handling:** Fargate Spot provides a 2-minute termination warning via `SIGTERM`. We configure `stopTimeout = 120` in ECS and catch `SIGTERM` in Python to complete the active transcode before exiting.
* **Alternative considered:** AWS Lambda.
* **Why rejected for Worker:** Video transcoding frequently requires more than 15 minutes of execution time and requires custom FFmpeg binaries and flexible scratch disk space. AWS Lambda has a strict 15-minute maximum execution timeout. ECS Fargate provides full Linux container flexibility without runtime timeouts.

---

### 2.5 Amazon DynamoDB (Single-Digit Millisecond NoSQL Database)
* **What it is:** Fully managed, serverless NoSQL key-value and document database.
* **Why we use it:**
  * Stores video metadata in the `video-platform-videos` table using `video_id` (String UUID) as Partition Key.
  * Tracks video lifecycle states: `uploaded` ➔ `processing` ➔ `ready` (or `failed`).
  * **`PAY_PER_REQUEST` On-Demand Billing:** Zero baseline costs. Incurs $0.00 when idle while scaling instantly to thousands of requests per second with single-digit millisecond response times.
* **Alternative considered:** Amazon RDS (PostgreSQL / MySQL) or MongoDB.
* **Why rejected:** RDS requires running database instances 24/7 ($15–$30/month minimum), VPC subnet groups, and connection pool management. DynamoDB is fully serverless and charges only for exact read/write operations performed.

---

### 2.6 Application Load Balancer (ALB) & Target Groups
* **What it is:** Layer 7 intelligent HTTP/HTTPS load balancer.
* **Why we use it:**
  * Distributes incoming dynamic API traffic (`/api/*`) across healthy ECS Fargate API container tasks.
  * Performs active health checks (`GET /health`) every 15 seconds. If a container task crashes or becomes unresponsive, the ALB instantly stops sending traffic to it and shifts requests to healthy tasks.
* **Alternative considered:** AWS API Gateway.
* **Why rejected:** API Gateway has a 29-second maximum execution timeout and adds additional pricing tiers. ALB provides seamless integration with ECS Fargate services and native path-based routing.

---

### 2.7 Amazon Elastic Container Registry (ECR)
* **What it is:** Fully managed, secure Docker container image registry.
* **Why we use it:**
  * Stores production Docker images for `video-platform-api` and `video-platform-worker`.
  * Every CI/CD deployment pushes images tagged with both the unique Git commit SHA (`${{ github.sha }}`) and `latest`, ensuring immutable traceability and enabling instant rollback to any prior release.
  * Features an automated lifecycle policy keeping the 10 most recent images to prevent storage sprawl.

---

### 2.8 Amazon CloudWatch (Logs, Metrics & Alarms)
* **What it is:** Centralized monitoring, logging, and alerting engine.
* **Why we use it:**
  * **Centralized Logging:** Aggregates stdout and stderr from all container tasks:
    * `/ecs/video-platform-api`: Captures FastAPI HTTP access logs, database queries, and presigned URL generation.
    * `/ecs/video-platform-worker`: Captures FFmpeg transcode progress, frame counts, bitrates, and SQS message receipts.
  * **Metric Alarms:**
    * `video-platform-queue-backlog`: Monitors SQS queue depth (`ApproximateNumberOfMessagesVisible >= 1`) to trigger worker scale-out.
    * `video-platform-queue-empty`: Monitors when visible == 0 and in-flight == 0 for 5 minutes to trigger worker scale-in.
    * `video-platform-api-5xx`: Alerts if API error rates spike.

---

### 2.9 AWS Application Auto Scaling (Queue-Driven 0 to 3 Scaling)
* **What it is:** Automatically adjusts ECS task capacity based on real-time demand.
* **Why we use it:**
  * Dynamically scales the `video-platform-worker` ECS service between **0 and 3 tasks**.
  * **Step Scaling:**
    * 1 to 4 waiting messages ➔ Launches 1 worker task.
    * 5 to 9 waiting messages ➔ Launches 2 worker tasks.
    * 10+ waiting messages ➔ Launches 3 worker tasks (capped at max 3).
  * **Scale to Zero:** When no jobs are waiting and no jobs are in progress for 5 minutes, workers scale down to **0**, reducing compute costs during idle periods to **$0.00**.

---

### 2.10 AWS IAM & GitHub Actions OIDC (Zero-Key Security)
* **What it is:** Identity and Access Management and OpenID Connect identity federation.
* **Why we use it:**
  * **Least-Privilege Roles:**
    * `api_task`: Allowed to write to DynamoDB and generate presigned PUT URLs for `raw/*`.
    * `worker_task`: Allowed to poll SQS, download `raw/*`, upload `processed/*`, and update DynamoDB.
    * `ecs_execution`: Allowed to pull images from ECR and write log streams to CloudWatch.
  * **Passwordless OIDC Federation:** GitHub Actions authenticates using short-lived cryptographic STS tokens (`sts:AssumeRoleWithWebIdentity`). **Zero permanent AWS access keys or passwords exist in GitHub Secrets**, eliminating credential leak risks.

---

### 2.11 Amazon VPC, Subnets & Security Groups (Isolated Networking)
* **What it is:** Isolated virtual cloud network.
* **Why we use it:**
  * Network CIDR: `10.0.0.0/16`.
  * **High Availability Subnets:** Two public subnets distributed across Availability Zones `us-east-1a` and `us-east-1b`.
  * **NAT Gateway Cost Elimination:** Containers run in public subnets with public IPs to reach AWS service endpoints, **saving ~$32/month by omitting a NAT Gateway**.
  * **Defense-in-Depth Security Groups:**
    * `alb`: Inbound HTTP port 80 from everywhere (`0.0.0.0/0`).
    * `api`: Inbound HTTP port 8000 **strictly from the ALB security group**. Direct internet access is completely blocked.
    * `worker`: Outbound-only traffic to AWS APIs (SQS, S3, DynamoDB). Zero inbound ports open.

---

## 3. How Everything is Connected (The 8-Stage Lifecycle Journey)

| Stage | Triggering Component | Receiving Component | Protocol / Mechanism | Data Exchanged |
| :--- | :--- | :--- | :--- | :--- |
| **1. UI Load** | User Browser | CloudFront ➔ S3 Frontend | HTTPS GET (`/*`) | Static `index.html`, `style.css`, `app.js` |
| **2. Upload Request** | User Browser | CloudFront ➔ ALB ➔ API | HTTPS POST (`/api/videos`) | `{ "title": "My Video" }` |
| **3. Presign & Register** | ECS API | DynamoDB & S3 SDK | Boto3 SDK (SigV4) | Initial record created (`uploaded`); returns Presigned PUT URL valid for 900s |
| **4. Direct Upload** | User Browser | S3 Uploads Bucket | HTTPS PUT (`raw/{video_id}.mp4`) | Raw video binary stream (bypasses API server entirely) |
| **5. Job Queuing** | S3 Uploads Bucket | SQS `video-jobs` Queue | `s3:ObjectCreated:*` Event | SQS Message containing S3 bucket and object key |
| **6. Auto-Scale & Pickup** | SQS ➔ CloudWatch | Application Auto Scaling ➔ ECS Worker | Long Polling (`WaitTime=20s`) | Worker scales 0 ➔ 1; consumes message receipt handle |
| **7. Transcode & Upload** | ECS Worker | S3 Processed & DynamoDB | Subprocess FFmpeg & Boto3 | Generates `720p.mp4`, `480p.mp4`, `thumb.jpg`; updates DynamoDB status to `ready` |
| **8. Playback Stream** | User Browser | CloudFront ➔ S3 Processed | HTTPS GET (`/processed/{id}/720p.mp4`) | Cached HLS / MP4 video stream delivered via CloudFront Edge |

---

## 4. Step-by-Step AWS Management Console Live Demo Guide

When presenting or demonstrating the live architecture to professors or examiners, follow this exact click-by-click navigation guide.

> **Crucial Rule:** In the top-right corner of the AWS Management Console navigation bar, ensure your region is set to:  
> 👉 **US East (N. Virginia) `us-east-1`**

---

### Stop 1: CloudFront Distribution
* **Navigation:** Search `CloudFront` in top search bar ➔ Click **CloudFront**.
* **What to click:** Click on Distribution ID: **`E2WQAP42PCO71D`**.
* **What to show on screen:**
  1. **General Tab:** Point out the **Distribution domain name**: `d31pege4389vaq.cloudfront.net`.
  2. **Origins Tab:** Point out the **3 distinct origins**:
     * `frontend-s3` (S3 frontend bucket)
     * `processed-s3` (S3 processed video bucket)
     * `api-alb` (Application Load Balancer)
  3. **Behaviors Tab:** Explain the path-based routing table:
     * `/api/*` ➔ ALB (caching disabled, handles dynamic REST traffic).
     * `/processed/*` and `/thumbnails/*` ➔ S3 Processed bucket (caching optimized).
     * Default `(*)` ➔ S3 Frontend bucket (serves static UI).

---

### Stop 2: S3 Triple-Bucket Storage
* **Navigation:** Search `S3` in top search bar ➔ Click **S3**.
* **What to show on screen:**
  1. **`video-platform-frontend-242201307132`:**
     * Open bucket ➔ Show `index.html`, `style.css`, `app.js`, `config.js`.
     * Click **Permissions tab** ➔ Point out **"Block all public access is ON"** and the bucket policy allowing reads *strictly* via CloudFront Origin Access Control (OAC).
  2. **`video-platform-uploads-242201307132`:**
     * Click **Properties tab** ➔ Scroll down to **Event notifications** ➔ Show `video-platform-uploads-to-sqs` sending `All object create events` on prefix `raw/` to SQS queue `video-jobs`.
     * Click **Management tab** ➔ Show the **Lifecycle Rule** that automatically deletes raw uploads after 7 days to eliminate unnecessary storage costs.
  3. **`video-platform-processed-242201307132`:**
     * Open bucket ➔ Show folders `processed/` (holding `720p.mp4`, `480p.mp4`) and `thumbnails/` (holding `thumb.jpg`).

---

### Stop 3: SQS Queues & Dead-Letter Queue
* **Navigation:** Search `SQS` in top search bar ➔ Click **Simple Queue Service**.
* **What to click:** Click on queue name: **`video-jobs`**.
* **What to show on screen:**
  1. **Details Box:** Show `Messages available` (queue depth) and `Messages in flight` (jobs currently being transcoded).
  2. **Configuration Box:** Point out **Receive message wait time = 20 seconds** (Long Polling) and **Visibility timeout = 300 seconds** (5 minutes).
  3. **Dead-Letter Queue Tab:** Show the redrive policy targeting **`video-jobs-dlq`** with **Maximum receives = 3**. Explain that corrupted video files are quarantined here after 3 failed attempts.

---

### Stop 4: ECS Fargate Services & Tasks
* **Navigation:** Search `ECS` in top search bar ➔ Click **Clusters** ➔ Click **`video-platform-cluster`**.
* **What to show on screen:**
  1. **Services Tab:** Show the two serverless microservices:
     * `video-platform-api` (Desired: 1, Running: 1, Launch Type: Fargate).
     * `video-platform-worker` (Desired: 0–1, Launch Type: Fargate Spot).
  2. **Tasks Tab:** Click into any running task to show its allocated hardware (0.25 vCPU, 512 MB memory), public IP, and network ENI.
  3. **Worker Service Auto-Scaling:** Click `video-platform-worker` ➔ Click **Configuration and tasks** tab ➔ Scroll down to **Auto scaling**. Show the scaling target (Min: 0, Max: 3) governed by Application Auto Scaling.

---

### Stop 5: DynamoDB Table Items
* **Navigation:** Search `DynamoDB` in top search bar ➔ Click **Tables** in left menu ➔ Click **`video-platform-videos`**.
* **What to click:** Click the orange **"Explore table items"** button in the top-right corner.
* **What to show on screen:**
  * Show the table schema:
    * `video_id`: String UUID (Partition Key).
    * `title`: Video title.
    * `status`: Video lifecycle state (`uploaded` ➔ `processing` ➔ `ready`).
    * `outputs`: Map containing `720p` and `480p` S3 keys.
    * `thumbnail_key`: S3 key to the JPEG thumbnail.
    * `created_at` / `updated_at`: ISO-8601 UTC timestamps.

---

### Stop 6: Application Load Balancer & Health Checks
* **Navigation:** Search `EC2` in top search bar ➔ Scroll down left sidebar to **Load Balancing** ➔ Click **Load Balancers**.
* **What to click:** Click on **`video-platform-alb`**.
* **What to show on screen:**
  1. **DNS Name:** The internal regional load balancer hostname.
  2. **Listeners and Rules Tab:** Show Port 80 HTTP forwarding to Target Group `video-platform-api`.
  3. **Target Groups:** In the left sidebar, click **Target Groups** ➔ Click **`video-platform-api`**:
     * Show **Health check path = `/health`**.
     * Show **Targets**: Confirm 1 registered ECS Fargate task reporting status **`Healthy`**.

---

### Stop 7: CloudWatch Logs & Auto-Scaling Alarms
* **Navigation:** Search `CloudWatch` in top search bar ➔ Click **Logs** ➔ **Log groups**.
* **What to show on screen:**
  1. **Log Group `/ecs/video-platform-api`:** Click latest stream to show incoming HTTP requests, `/api/videos` queries, and presigned upload URL minting.
  2. **Log Group `/ecs/video-platform-worker`:** Click latest stream to show SQS message receipt, FFmpeg progress (encoding 720p, 480p, thumbnail), and S3 upload confirmations.
  3. **Alarms:** In the left sidebar, click **Alarms** ➔ **All alarms**:
     * `video-platform-queue-backlog`: Fires when SQS visible messages >= 1 to scale up workers.
     * `video-platform-queue-empty`: Fires when visible == 0 and in-flight == 0 for 5 minutes to scale workers to 0.

---

### Stop 8: VPC Networking & Security Groups
* **Navigation:** Search `VPC` in top search bar ➔ Click **Your VPCs**.
* **What to show on screen:**
  1. Show `video-platform-vpc` (`10.0.0.0/16`).
  2. In left sidebar, click **Subnets**: Show the 2 public subnets in `us-east-1a` and `us-east-1b`.
  3. In left sidebar, click **Security Groups**:
     * `video-platform-alb-sg`: Allows inbound HTTP 80 from everywhere (`0.0.0.0/0`).
     * `video-platform-api-sg`: Inbound HTTP 8000 **strictly from `video-platform-alb-sg`**.
     * `video-platform-worker-sg`: Outbound-only traffic to AWS APIs. Zero inbound ports open.

---

## 5. The "Showstopper" 3-Minute Live Action Walkthrough

This live demonstration protocol consistently wows professors, interviewers, and examiners by showing **real-time event-driven cloud propagation across 3 browser tabs simultaneously**:

### Preparation: Open 3 Browser Tabs
* **Tab 1 (The Logs):** Open [CloudWatch Worker Log Group `/ecs/video-platform-worker`](https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group/$252Fecs$252Fvideo-platform-worker).
* **Tab 2 (The Database):** Open [DynamoDB Table Items](https://us-east-1.console.aws.amazon.com/dynamodbv2/home?region=us-east-1#table?name=video-platform-videos).
* **Tab 3 (The App):** Open the live production web app: **[https://d31pege4389vaq.cloudfront.net](https://d31pege4389vaq.cloudfront.net)**.

### Execution: The 6-Step Live Demo
1. In **Tab 3**, click **"Upload Video"**, enter title `"Live Cloud Demo"`, and select any small `.mp4` file.
2. Point out the real-time upload progress bar filling up as the browser streams bytes directly to S3 via presigned PUT.
3. Switch to **Tab 2 (DynamoDB)** and click **"Run query"**:
   * Show that a new item appeared with `status: "uploaded"`, transitioning immediately to `status: "processing"`.
4. Switch to **Tab 1 (CloudWatch Logs)** and open the newest log stream:
   * Show FFmpeg actively executing: downloading the raw MP4 from S3, running `-preset veryfast -crf 28` to create `720p.mp4` and `480p.mp4`, generating the JPEG thumbnail, and uploading results to S3.
5. Switch back to **Tab 2 (DynamoDB)** and refresh the query:
   * Show `status` has updated to `"ready"`, with the `outputs` map populated with `720p` and `480p` S3 keys.
6. Switch back to **Tab 3 (The App)**:
   * The video card badge turns green (`Ready`).
   * Click on the card: the watch player opens and begins streaming instantly (enabled by `+faststart`).
   * Click the **720p** and **480p** resolution pills to demonstrate seamless quality switching!

---

## 6. Top 12 AWS Defense & Viva Questions Answered

#### Q1: Why did you use CloudFront instead of exposing the ALB or S3 directly?
**Answer:** Exposing S3 directly requires making buckets public (a major security violation) and cannot terminate custom SSL. Exposing the ALB directly creates CORS pre-flight latency between frontend and backend. CloudFront unifies frontend, API, and media storage under one single HTTPS domain, eliminates CORS, enforces Origin Access Control (OAC) to keep S3 private, and caches video segments globally at edge locations.

#### Q2: Why didn't your VPC include an AWS NAT Gateway?
**Answer:** An AWS NAT Gateway costs ~$32/month plus data processing fees. By placing our ECS Fargate tasks in public subnets with public IPs, but locking down inbound traffic with strict security groups (allowing only ALB traffic to the API and zero inbound traffic to the worker), we achieve equivalent security for $0/month.

#### Q3: Why did you use Amazon SQS instead of calling the worker directly via HTTP?
**Answer:** HTTP calls are synchronous and tightly coupled. If 50 users upload at once, an HTTP web server runs out of connection sockets or times out. SQS acts as a buffer/shock absorber that absorbs upload spikes without dropping jobs, allowing workers to process tasks steadily at their own capacity.

#### Q4: Why did you choose ECS Fargate instead of AWS Lambda for transcoding?
**Answer:** AWS Lambda has a strict 15-minute maximum execution timeout and limited ephemeral disk space. High-definition or longer video transcoding frequently exceeds 15 minutes and requires custom FFmpeg binaries and flexible scratch disk allocations. Fargate provides full Linux container flexibility without runtime timeouts.

#### Q5: What is the purpose of SQS Long Polling (`WaitTimeSeconds = 20`)?
**Answer:** Standard (short) polling queries SQS and returns immediately even if empty, burning CPU and generating thousands of costly API requests. Long polling keeps the connection open for up to 20 seconds waiting for messages, reducing empty receives by >95% and lowering AWS billing.

#### Q6: How does the Dead-Letter Queue (DLQ) protect the system?
**Answer:** If an uploaded file is corrupted or malicious and crashes FFmpeg, it would retry endlessly. Our redrive policy sets `maxReceiveCount = 3`. After 3 failed attempts, SQS quarantines the message in `video-jobs-dlq` for 14 days, isolating the "poison pill" and keeping the main queue clean.

#### Q7: How does worker auto-scaling work? Why check both visible and in-flight messages?
**Answer:** CloudWatch monitors SQS queue depth. When uploads arrive, alarm `video-platform-queue-backlog` scales workers from 0 to 3. For scaling in, alarm `video-platform-queue-empty` checks that visible messages == 0 **AND** in-flight messages == 0 for 5 minutes. Checking in-flight messages ensures AWS never terminates a worker while it is actively transcoding a video.

#### Q8: What is Fargate Spot and how do you handle instance termination?
**Answer:** Fargate Spot uses spare AWS compute capacity sold at up to a 70% discount. When AWS needs the capacity back, it sends a `SIGTERM` warning 2 minutes prior to termination. Our worker registers a Python signal handler (`handle_sigterm`) and sets `stopTimeout = 120` in ECS. The worker finishes its active transcode, uploads results, and exits gracefully before the container is terminated.

#### Q9: What does `-movflags +faststart` do in FFmpeg?
**Answer:** Standard MP4 containers write the index header (`moov` atom) at the end of the file. Without `+faststart`, browsers cannot begin playing until 100% of the video is downloaded. `+faststart` moves the `moov` atom to the very front of the file, enabling instant web streaming as soon as the first few kilobytes arrive.

#### Q10: Why did you choose DynamoDB over MongoDB or PostgreSQL?
**Answer:** PostgreSQL requires provisioning EC2 instances or RDS clusters with continuous baseline costs ($15–$30/month) and connection pool management. DynamoDB is fully serverless with `PAY_PER_REQUEST` billing—it costs $0.00 when idle, scales automatically, requires zero maintenance, and offers single-digit millisecond latency.

#### Q11: What is S3 Origin Access Control (OAC)?
**Answer:** OAC is AWS's modern security standard that restricts S3 bucket access exclusively to CloudFront. CloudFront signs every request to S3 using AWS Signature Version 4 (SigV4). S3 verifies the signature and bucket policy, ensuring users cannot bypass CloudFront or access S3 directly.

#### Q12: How does GitHub Actions authenticate to AWS without static access keys?
**Answer:** Through OpenID Connect (OIDC) identity federation. When a GitHub Actions workflow runs, it requests an OIDC token from GitHub. The `aws-actions/configure-aws-credentials` action exchanges this token with AWS Security Token Service (STS) using `sts:AssumeRoleWithWebIdentity`. AWS validates the token against our IAM trust policy and mints temporary 15-minute credentials. No permanent AWS access keys are stored in GitHub.
