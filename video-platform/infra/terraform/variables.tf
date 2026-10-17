variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Prefix for every resource name. CI workflows assume the default."
  type        = string
  default     = "video-platform"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the deploy role, as \"owner/repo\"."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like \"owner/repo\"."
  }
}

variable "tf_state_bucket" {
  description = "Terraform state bucket name. Lets the GitHub role run `terraform plan` in infra.yml."
  type        = string
  default     = ""
}

variable "use_learner_lab" {
  description = "AWS Academy Learner Lab: reuse the pre-created LabRole instead of creating IAM roles and the GitHub OIDC provider."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Optional email subscribed to the CloudWatch alarm SNS topic (confirm the email AWS sends)."
  type        = string
  default     = ""
}

variable "api_cpu" {
  description = "API task CPU units (256 = 0.25 vCPU)."
  type        = number
  default     = 256
}

variable "api_memory" {
  description = "API task memory in MiB."
  type        = number
  default     = 512
}

variable "api_desired_count" {
  description = "Number of API tasks. Set to 2 for a high-availability demo."
  type        = number
  default     = 1
}

variable "worker_cpu" {
  description = "Worker task CPU units (1024 = 1 vCPU)."
  type        = number
  default     = 1024
}

variable "worker_memory" {
  description = "Worker task memory in MiB."
  type        = number
  default     = 2048
}

variable "worker_max_count" {
  description = "Maximum number of worker tasks the autoscaler may run."
  type        = number
  default     = 3
}

variable "raw_upload_expiry_days" {
  description = "Days after which raw uploads are deleted from the uploads bucket."
  type        = number
  default     = 3
}
