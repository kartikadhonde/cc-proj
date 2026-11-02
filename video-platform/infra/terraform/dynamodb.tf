# DynamoDB Table: stores video metadata (title, status, stream links, thumbnails, error traces)
resource "aws_dynamodb_table" "videos" {
  name         = "${local.name}-videos"
  billing_mode = "PAY_PER_REQUEST" # On-demand pricing: pay only when requests happen, zero idle cost
  hash_key     = "video_id"        # Unique UUID for each video

  attribute {
    name = "video_id"
    type = "S" # String UUID
  }
}
