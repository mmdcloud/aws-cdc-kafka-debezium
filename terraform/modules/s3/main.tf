# S3 Bucket
resource "aws_s3_bucket" "bucket" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags = {
    Name = var.bucket_name
  }
}

# Creating object
resource "aws_s3_object" "object" {
  count  = length(var.objects)
  bucket = aws_s3_bucket.bucket.id
  source = var.objects[count.index].source
  key    = var.objects[count.index].key
}

# Bucket versioning configuration
resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.bucket.id
  versioning_configuration {
    status = var.versioning_enabled
  }
}

# Bucket cors configuration
resource "aws_s3_bucket_cors_configuration" "cors" {
  bucket = aws_s3_bucket.bucket.id
  dynamic "cors_rule" {
    for_each = var.cors
    content {
      allowed_headers = cors_rule.value["allowed_headers"]
      allowed_methods = cors_rule.value["allowed_methods"]
      allowed_origins = cors_rule.value["allowed_origins"]
      max_age_seconds = cors_rule.value["max_age_seconds"]
    }
  }  
}

# Bucket policy
resource "aws_s3_bucket_policy" "bucket_policy" {
  count  = var.bucket_policy != "" ? 1 : 0
  bucket = aws_s3_bucket.bucket.id
  policy = var.bucket_policy  
}

# Specifying bucket notification configuration
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.bucket.bucket
  dynamic "queue" {
    for_each = var.bucket_notification.queue
    content {
      queue_arn = queue.value["queue_arn"]
      events    = queue.value["events"]
    }
  }
  dynamic "lambda_function" {
    for_each = var.bucket_notification.lambda_function
    content {
      lambda_function_arn = lambda_function.value["lambda_function_arn"]
      events              = lambda_function.value["events"]
    }
  }  
}
