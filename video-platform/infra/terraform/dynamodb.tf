resource "aws_dynamodb_table" "videos" {
  name         = "${local.name}-videos"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "video_id"

  attribute {
    name = "video_id"
    type = "S"
  }
}
