# AWS Cloud Video Platform: Complete Architecture, Service Rationale & Console Navigation Guide

**Document Version:** 1.0  
**Target Environment:** Amazon Web Services (AWS)  
**Primary Region:** `us-east-1` (US East - N. Virginia)  
**AWS Account ID:** `242201307132`  
**Live Production URL:** [https://d13nzb4lwb8eqj.cloudfront.net](https://d13nzb4lwb8eqj.cloudfront.net)  

---

## Executive Summary

This document provides an exhaustive, engineering-grade explanation of the cloud architecture, services, design decisions, and AWS Management Console navigation for the **Cloud-Based Video Upload, Transcoding, and Streaming Platform**.

Modern video distribution requires solving four fundamental distributed systems challenges:
1. **Compute Bottlenecks:** Video encoding using FFmpeg is CPU- and memory-intensive; performing transcoding on an interactive web server starves API responses and causes cascading system failures.
2. **Network Ingestion Latency:** Direct file uploads through application web servers consume socket connections and bandwidth, creating single points of failure.
3. **Adaptive Bitrate Streaming (ABR):** Clients stream videos across fluctuating network conditions (mobile 4G, broadband, slow WiFi) and require multi-resolution HLS (HTTP Live Streaming) manifests (`1080p`, `720p`, `360p`) segmented into short transport stream chunks (`.ts`).
4. **Edge Delivery Performance:** Serving multi-megabyte video segments from a centralized server across the globe incurs buffering and latency; segments must be cached at global edge points-of-presence (PoPs).

To address these challenges, this platform implements a **serverless, event-driven, decoupled cloud architecture** on Amazon Web Services (AWS), orchestrated using Terraform Infrastructure-as-Code (IaC) and automated via GitHub Actions CI/CD with passwordless OpenID Connect (OIDC) authentication.

---

## 1. End-to-End Architectural Lifecycle

When an end user interacts with the platform, the request propagates across multiple AWS subsystems:

```
[ User Browser ]
       │
       ▼ (1. Access Webpage)
[ Amazon CloudFront CDN (Global Edge) ] ──(Origin S3)──► [ S3: video-platform-frontend ]
       │
       ▼ (2. Request Presigned Upload URL)
[ Application Load Balancer (ALB) ]
       │
       ▼ (Forward /api/*)
[ Amazon ECS Fargate: video-platform-api ] ──(Write metadata: "queued")──► [ Amazon DynamoDB ]
       │
       ▼ (Returns S3 Presigned PUT URL)
[ User Browser ]
       │
       ▼ (3. Direct Binary Upload via PUT)
[ S3: video-platform-uploads-242201307132 ]
       │
       ▼ (4. ObjectCreated Event Notification)
[ Amazon SQS: video-jobs ] ◄── (Auto Scaling Alarm on Backlog) ──► [ Application Auto Scaling ]
       │
       ▼ (5. Long-Polls SQS Queue)
[ Amazon ECS Fargate: video-platform-worker ]
       │
       ├──► (Downloads raw .mp4)
       ├──► (Executes FFmpeg Transcoding: 1080p, 720p, 360p HLS)
       ├──► (Uploads master.m3u8, variant playlists, and .ts segments)
       │    └──► [ S3: video-platform-processed-242201307132 ]
       │
       └──► (Updates video state to "ready" + qualities list)
            └──► [ Amazon DynamoDB: video-platform-videos ]
       │
[ User Browser ]
       │
       ▼ (6. Stream Adaptive Bitrate Video)
[ Amazon CloudFront CDN ] ──(Origin S3)──► [ S3: video-platform-processed-242201307132 ]
```

---

## 2. AWS Services Inventory: What We Use, Why, and Design Decisions

Every AWS service in this project was selected based on specific architectural trade-offs between performance, scalability, security, operational overhead, and cost.

---

### Service 1: Amazon CloudFront (Global Content Delivery Network & Edge Router)

* **What it is:** A globally distributed CDN with hundreds of edge locations worldwide that caches content closer to end users.
* **Role in our project:**
  * **Unified Domain Entrypoint:** CloudFront serves as the single public entrypoint (`d13nzb4lwb8eqj.cloudfront.net`) for all three layers of the application:
    1. `/api/*` requests route dynamically to the Application Load Balancer.
    2. `/hls/*` requests route to the processed video S3 bucket.
    3. Default `*` requests route to the static frontend S3 bucket.
  * **HLS Segment Caching:** Video chunks (`.ts` files) are immutable; CloudFront caches them at edge locations so subsequent viewers download chunks from local edge caches rather than hitting S3.
  * **Elimination of Cross-Origin Resource Sharing (CORS):** Because the web UI and the API share the identical CloudFront hostname, browser requests to `/api/videos` are same-origin, eliminating complex CORS pre-flight bottlenecks.
* **Why this service specifically?**
  * *Alternative considered:* Direct Application Load Balancer or direct S3 Website Hosting.
  * *Why rejected:* S3 website endpoints do not support private Origin Access Control (OAC), cannot terminate custom SSL securely without CloudFront, and lack worldwide caching, resulting in higher latency and higher egress costs.

---

### Service 2: Amazon Simple Storage Service (S3) (Triple-Bucket Architecture)

* **What it is:** Highly durable (99.999999999% - 11 9's), highly available object storage.
* **Role in our project:** We utilize a segmented **Triple-Bucket Architecture**:
  1. **`video-platform-frontend-242201307132` (Static Web Hosting):**
     * Contains `index.html`, `style.css`, `app.js`, and `config.js`.
     * Completely blocks all public access. Only CloudFront can read files via AWS Origin Access Control (OAC).
  2. **`video-platform-uploads-242201307132` (Raw Ingestion Buffer):**
     * Receives direct multipart/binary `.mp4` uploads from users via S3 presigned URLs.
     * Features an automated **S3 Event Notification** that dispatches messages to SQS whenever a new video is placed in `raw/*`.
     * Configured with a **Lifecycle Rule**: Raw source files are automatically expired and purged after 7 days, eliminating redundant storage costs once videos are transcoded.
  3. **`video-platform-processed-242201307132` (HLS Video Streaming Storage):**
     * Stores transcoded multi-bitrate HLS streams (`master.m3u8`, `1080p.m3u8`, `720p.m3u8`, `360p.m3u8`, and `.ts` chunk files).
     * Protected by Origin Access Control (OAC) so users can only stream video through CloudFront CDN.
* **Why this service specifically?**
  * *Alternative considered:* Storing files on Elastic Block Store (EBS) or Elastic File System (EFS).
  * *Why rejected:* EBS volumes cannot be shared across multiple stateless workers dynamically, and EFS is significantly more expensive per gigabyte than S3 for video storage.

---

### Service 3: Amazon Simple Queue Service (SQS) & Dead Letter Queue (DLQ)

* **What it is:** Fully managed, highly reliable distributed message queuing service.
* **Role in our project:**
  * **Asynchronous Decoupling:** When a video upload finishes, S3 publishes a notification directly to the `video-jobs` queue. The API server does not wait for transcoding; it immediately returns an HTTP 200 response to the user.
  * **Traffic Shock Absorption:** If 100 users upload videos simultaneously, SQS absorbs the burst without dropping a single job, allowing workers to process tasks steadily without overwhelming system memory.
  * **Dead Letter Queue (`video-jobs-dlq`):** If an invalid or corrupted video causes the worker process to crash 3 times (`maxReceiveCount = 3`), SQS automatically moves the message to the DLQ, isolating the "poison pill" and preventing infinite retry loops.
* **Why this service specifically?**
  * *Alternative considered:* Apache Kafka or RabbitMQ.
  * *Why rejected:* Kafka and RabbitMQ require dedicated broker instances, active cluster maintenance, and continuous hourly costs even when traffic is zero. SQS is 100% serverless, charges only per API request, and scales to millions of messages automatically.

---

### Service 4: Amazon Elastic Container Service (ECS) on AWS Fargate

* **What it is:** Fully managed container orchestration engine running serverless compute (Fargate).
* **Role in our project:**
  * **Serverless Execution:** We run Docker containers without provisioning, patching, or managing EC2 virtual machines. We specify CPU and memory (`0.25 vCPU`, `512 MB`), and AWS manages the underlying hardware.
  * **Two Dedicated Services:**
    1. **`video-platform-api`:** Runs the Python FastAPI web server. Stateless, scalable, registered with the Application Load Balancer target group.
    2. **`video-platform-worker`:** Runs the Python consumer with an embedded FFmpeg binary. It uses SQS long-polling (`WaitTimeSeconds = 20`) to minimize CPU usage while waiting for jobs.
* **Why this service specifically?**
  * *Alternative considered:* AWS Lambda.
  * *Why rejected for Worker:* Video transcoding of 1080p high-definition media frequently requires more than 15 minutes of execution time and requires custom FFmpeg binaries and local scratch disk space. AWS Lambda has a strict 15-minute maximum execution timeout and memory caps. ECS Fargate provides full Linux container flexibility without runtime timeouts.

---

### Service 5: Amazon Elastic Container Registry (ECR)

* **What it is:** Secure, private Docker container registry integrated with AWS IAM.
* **Role in our project:**
  * Stores production Docker images for `video-platform-api` and `video-platform-worker`.
  * Every GitHub Actions deployment tags the image with both `latest` and the unique Git commit SHA (`${{ github.sha }}`), enabling immutable traceability and instant rollback to any prior release.

---

### Service 6: Application Load Balancer (ALB)

* **What it is:** Layer 7 intelligent load balancer capable of routing HTTP/HTTPS traffic based on path rules and host headers.
* **Role in our project:**
  * Directs incoming API requests (`/api/*`) across healthy ECS Fargate API container tasks.
  * Conducts continuous health checks (`GET /health`) every 15 seconds. If a container task fails health checks, the ALB immediately stops routing traffic to it and alerts ECS to launch a replacement container.

---

### Service 7: Amazon DynamoDB (NoSQL Video Metadata Database)

* **What it is:** Fully managed, serverless NoSQL database offering single-digit millisecond latency at any scale.
* **Role in our project:**
  * Stores video records in the `video-platform-videos` table using `id` (String UUID) as the Partition Key.
  * Manages the lifecycle state machine:
    * `queued` ➔ Initial state recorded when upload presigned URL is generated.
    * `processing` ➔ Worker acknowledges SQS message and begins FFmpeg pass.
    * `ready` ➔ Transcode complete, master playlist verified, resolutions list populated (`["360p", "720p", "1080p"]`).
    * `failed` ➔ Recorded if FFmpeg encounters corrupted streams or unreadable containers.
* **Why this service specifically?**
  * *Alternative considered:* Amazon RDS PostgreSQL or MySQL.
  * *Why rejected:* Relational databases require provisioning instances, managing connections, VPC subnet groups, and ongoing monthly database instance costs. DynamoDB runs in serverless pay-per-request mode, incurring $0.00 cost when idle.

---

### Service 8: Amazon CloudWatch (Logs, Metrics & Alarms)

* **What it is:** AWS observability, centralized logging, and alerting engine.
* **Role in our project:**
  * **Centralized Log Groups:**
    * `/ecs/video-platform-api`: Aggregates web server access logs, upload URL generation, and error traces.
    * `/ecs/video-platform-worker`: Aggregates FFmpeg transcode progress, frame counts, bitrates, and SQS receipts.
  * **Production Alarms:**
    * `video-platform-api-5xx`: Fires if server errors exceed thresholds.
    * `video-platform-queue-backlog`: Triggers worker auto-scaling when SQS messages build up.
    * `video-platform-queue-empty`: Triggers scale-in when transcoding queues are clear.

---

### Service 9: AWS Application Auto Scaling

* **What it is:** Dynamic resource scaler that adjusts ECS task capacity based on CloudWatch metrics.
* **Role in our project:**
  * Scales the `video-platform-worker` ECS service dynamically between `0` (or `1`) and `3` tasks.
  * When users upload multiple videos, the SQS queue depth triggers `video-platform-queue-backlog`, launching additional Fargate workers to process jobs in parallel. When queues empty, it scales tasks back down to conserve costs.

---

### Service 10: AWS Identity and Access Management (IAM) & GitHub Actions OIDC

* **What it is:** Authentication and fine-grained authorization infrastructure.
* **Role in our project:**
  * Implements **Least-Privilege Role Separation**:
    * `video-platform-api-task`: Permitted only to write to DynamoDB and generate presigned PUT URLs for `raw/*`.
    * `video-platform-worker-task`: Permitted only to poll `video-jobs` SQS queue, read `raw/*`, write to `processed/*`, and update DynamoDB.
    * `video-platform-ecs-execution`: Permitted only to pull images from ECR and write log streams to CloudWatch.
  * **OpenID Connect (OIDC) Authentication:**
    * Eliminates static AWS Access Keys in GitHub. GitHub Actions uses cryptographic token exchanges with AWS STS (`sts:AssumeRoleWithWebIdentity`), obtaining temporary 15-minute credentials for automated deployments.

---

### Service 11: Amazon Virtual Private Cloud (VPC) & Networking

* **What it is:** Logically isolated virtual network.
* **Role in our project:**
  * Network CIDR: `10.0.0.0/16`.
  * Configured with **two public subnets** spanning Availability Zones `us-east-1a` and `us-east-1b` for high availability.
  * Attached to an Internet Gateway (`video-platform-igw`) for outbound internet connectivity.
  * **Security Groups:**
    * `video-platform-alb-sg`: Permits inbound HTTP 80 from the internet.
    * `video-platform-api-sg`: Permits inbound traffic *exclusively* from the ALB security group.
    * `video-platform-worker-sg`: Outbound-only traffic to AWS APIs (S3, SQS, DynamoDB).

---

## 3. Step-by-Step AWS Management Console Navigation Guide

Follow this guide to inspect each component directly inside your AWS account.

### Step 0: Ensure Correct Region
In the top-right corner of the AWS Management Console navigation bar, verify the region is set to:  
👉 **US East (N. Virginia) `us-east-1`**

---

### Step 1: Inspecting the Edge CDN (CloudFront)
1. In the top global search bar, type `CloudFront` and press **Enter**.
2. Click on Distribution ID: **`E12B1QG780JDSL`**.
3. **What to inspect:**
   * **General Tab:** Confirm the **Domain name** is `d13nzb4lwb8eqj.cloudfront.net`.
   * **Origins Tab:** Notice the three distinct origins:
     * `video-platform-frontend-242201307132.s3...`
     * `video-platform-processed-242201307132.s3...`
     * `video-platform-alb-878346630...`
   * **Behaviors Tab:** See how path patterns route requests:
     * `/api/*` routes to the Application Load Balancer.
     * `/hls/*` routes to the processed video S3 bucket.
     * Default `(*)` routes to the static frontend.

---

### Step 2: Inspecting S3 Buckets & Event Triggers
1. In the top search bar, type `S3` and click **S3**.
2. **Bucket 1: `video-platform-frontend-242201307132`**
   * Click the bucket name.
   * View the deployed assets: `index.html`, `style.css`, `app.js`, `config.js`.
   * Click the **Permissions** tab: Confirm **Block Public Access** is `On` (access is restricted to CloudFront Origin Access Control).
3. **Bucket 2: `video-platform-uploads-242201307132`**
   * Click the **Properties** tab and scroll to **Event notifications**.
   * Notice event `video-platform-uploads-to-sqs`: Every upload to `raw/*` automatically notifies SQS queue `video-jobs`.
   * Click the **Management** tab: Notice the **Lifecycle Rule** that automatically purges raw files after 7 days.
4. **Bucket 3: `video-platform-processed-242201307132`**
   * After transcoding, you will see a `hls/` directory here containing `master.m3u8` and `.ts` video chunks.

---

### Step 3: Inspecting the Message Queue & Dead-Letter Queue (SQS)
1. In the top search bar, type `SQS` and click **Simple Queue Service**.
2. Click on queue name: **`video-jobs`**.
3. **What to inspect:**
   * **Details card:**
     * **Messages available:** Jobs waiting to be picked up.
     * **Messages in flight:** Jobs currently being transcoded by workers.
   * **Dead-letter queue tab:**
     * Notice the link to **`video-jobs-dlq`**.
     * Redrive policy: Maximum receives = `3`. If a video crashes the worker 3 times, it is safely quarantined here.

---

### Step 4: Inspecting Serverless Containers (Amazon ECS)
1. In the top search bar, type `ECS` and click **Elastic Container Service**.
2. Click on cluster name: **`video-platform-cluster`**.
3. **What to inspect:**
   * **Services tab:**
     * `video-platform-api`: Desired count `1`, Running count `1`.
     * `video-platform-worker`: Desired count `1`, Running count `1`.
   * **Tasks tab:**
     * Shows the live container tasks.
     * Click any Task ID to inspect task definition revision, CPU/Memory metrics, and private IP.
   * **Auto Scaling:**
     * Click `video-platform-worker` ➔ click **Configuration and tasks** tab ➔ scroll down to **Auto scaling**.
     * View the scaling policy that scales workers between 0 and 3 based on SQS queue backlog.

---

### Step 5: Inspecting Docker Images (Amazon ECR)
1. In the top search bar, type `ECR` and click **Elastic Container Registry**.
2. Click into either `video-platform-api` or `video-platform-worker`.
3. **What to inspect:**
   * View the container images pushed by GitHub Actions.
   * Note the image tags matching the Git commit SHA.
   * View the image vulnerability scan status.

---

### Step 6: Inspecting the NoSQL Video Database (DynamoDB)
1. In the top search bar, type `DynamoDB` and click **DynamoDB**.
2. In the left navigation menu, click **Tables** ➔ select **`video-platform-videos`**.
3. Click the orange **Explore table items** button (top right).
4. **What to inspect:**
   * View video records:
     * `id`: Unique video UUID.
     * `title`: Video title.
     * `status`: `queued` ➔ `processing` ➔ `ready`.
     * `qualities`: `["360p", "720p", "1080p"]`.
     * `hlsPath`: Path to the HLS master playlist.
     * `createdAt` and `updatedAt` timestamps.

---

### Step 7: Inspecting Load Balancer Health (EC2 / ALB)
1. In the top search bar, type `EC2` and click **EC2**.
2. In the left sidebar, scroll down to **Load Balancing** and click **Load Balancers**.
3. Click on **`video-platform-alb`**:
   * View the **DNS Name** (`video-platform-alb-878346630...`).
   * In the **Listeners and rules** tab, view the rule forwarding port 80 to target group `video-platform-api`.
4. In the left sidebar, click **Target Groups** ➔ click **`video-platform-api`**:
   * Inspect **Health check settings** (`/health`).
   * Inspect **Targets**: Verify 1 registered ECS Fargate task is reporting `Healthy`.

---

### Step 8: Inspecting Live System Logs (Amazon CloudWatch)
1. In the top search bar, type `CloudWatch` and click **CloudWatch**.
2. In the left sidebar, click **Logs** ➔ **Log groups**.
3. **Log Group 1: `/ecs/video-platform-api`**
   * Click the latest log stream to see FastAPI HTTP requests, `/api/videos` queries, and presigned upload URL requests.
4. **Log Group 2: `/ecs/video-platform-worker`**
   * Click the latest log stream to see the worker polling SQS, downloading raw video from S3, running FFmpeg transcoding, and writing HLS chunks to S3.
5. In the left sidebar, click **Alarms** ➔ **All alarms**:
   * Review `video-platform-api-5xx`, `video-platform-queue-backlog`, and `video-platform-queue-empty`.

---

## 4. Live Multi-Screen Demonstration Walkthrough

To experience the entire AWS event-driven pipeline in real time:

1. **Screen 1 (CloudWatch Worker Logs):**  
   Open [CloudWatch Log Group `/ecs/video-platform-worker`](https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group/$252Fecs$252Fvideo-platform-worker).
2. **Screen 2 (DynamoDB Table Items):**  
   Open [DynamoDB Table Items](https://us-east-1.console.aws.amazon.com/dynamodbv2/home?region=us-east-1#table?name=video-platform-videos).
3. **Screen 3 (Live Streaming Application):**  
   Open [https://d13nzb4lwb8eqj.cloudfront.net](https://d13nzb4lwb8eqj.cloudfront.net).
4. **Execute Action:**  
   In Screen 3, click **Upload Video**, name it `"Live Cloud Demo"`, and select any small `.mp4` file.
5. **Observe the Event Propagation:**
   * In Screen 2 (DynamoDB), click **Run query** ➔ a new item appears with status `queued`, transitioning to `processing`.
   * In Screen 1 (CloudWatch), open the newest log stream ➔ watch FFmpeg actively log frame rates, bitrates, and HLS segment creation.
   * In Screen 2, refresh the query ➔ status updates to `ready`, with `qualities: ["360p", "720p", "1080p"]`.
   * In Screen 3, the card badge turns green (`Ready`). Click on the card to watch smooth, multi-bitrate HLS streaming delivered via CloudFront edge locations!

---

## 5. Cost Protection & Teardown Protocol

When not actively demonstrating the project, all 64 AWS resources can be cleanly decommissioned to ensure **active hourly billing returns to $0.00**:

```powershell
& "C:\Program Files\Git\bin\bash.exe" -c "cd /d/MyProjects/cc-proj/video-platform && ./scripts/teardown-aws.sh"
```

To bring everything back online at any time with one command:
```powershell
& "C:\Program Files\Git\bin\bash.exe" -c "cd /d/MyProjects/cc-proj/video-platform && ./scripts/bootstrap-aws.sh"
```
