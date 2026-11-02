# Zero-NAT Network Architecture:
# Containers run in public subnets with public IPs to communicate with AWS APIs (ECR, S3, SQS, DynamoDB).
# This completely eliminates the need for an expensive NAT Gateway (~$32.40/month baseline cost).
# Ingress security is strictly locked down using security groups.

# Virtual Private Cloud (VPC): private cloud network for our application
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

# Internet Gateway: allows VPC resources to reach the internet
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

# Public Subnets: 2 subnets across 2 Availability Zones (ap-south-1a and ap-south-1b) for high availability
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-public-${local.azs[count.index]}" }
}

# Route table: sends all outbound traffic (0.0.0.0/0) to the Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public" }
}

# Associate both subnets with the public route table
resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Security Groups (Firewalls) ---

# ALB Security Group: allows public HTTP traffic on port 80 from anywhere
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public HTTP to the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# API Security Group: allows incoming traffic on port 8000 ONLY from the ALB (no direct public access)
resource "aws_security_group" "api" {
  name        = "${local.name}-api"
  description = "API tasks: inbound 8000 from the ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "API port from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Worker Security Group: ZERO inbound rules (blocks all incoming internet traffic)
resource "aws_security_group" "worker" {
  name        = "${local.name}-worker"
  description = "Worker tasks: no inbound, outbound to AWS APIs"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
