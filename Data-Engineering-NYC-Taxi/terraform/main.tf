terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"  # Change to your region
}

# Lambda function
resource "aws_lambda_function" "nyctaxi_ingestion" {
  function_name = "nyctaxi-data-ingestion"
  description   = "Downloads NYC taxi data monthly and saves to S3"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.10"
  timeout       = 900  # 15 minutes
  memory_size   = 512   # 512 MB

  filename         = data.archive_file.lambda_zip.output_path   # Path to the zipped code (below)
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      S3_BUCKET = "databricks-workspace-stack-06ea8-bucket"
      S3_PREFIX = "nyctaxi/raw/"
    }
  }

  tags = {
    Project     = "nyctaxi-ml-pipeline"
    Environment = "production"
  }
}

# IAM role for Lambda
resource "aws_iam_role" "lambda_exec" {
  name = "nyctaxi-ingestion-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Project = "nyctaxi-ml-pipeline"
  }
}

# IAM policy for Lambda
resource "aws_iam_role_policy" "lambda_s3_policy" {
  name = "nyctaxi-ingestion-s3-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::databricks-workspace-stack-06ea8-bucket",
          "arn:aws:s3:::databricks-workspace-stack-06ea8-bucket/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

# CloudWatch Event Rule
resource "aws_cloudwatch_event_rule" "monthly_trigger" {
  name                = "nyctaxi-monthly-ingestion"
  description         = "Triggers NYC taxi data ingestion on the 1st of each month"
  schedule_expression = "cron(0 8 5 * ? *)"  # "cron(0 8 1 * ? *)" = 8 AM on the 1st of every month, edit to test "rate(5 minutes)"

  tags = {
    Project = "nyctaxi-ml-pipeline"
  }
}


# CloudWatch Event Target
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.monthly_trigger.name
  target_id = "nyctaxi-lambda-target"
  arn       = aws_lambda_function.nyctaxi_ingestion.arn
}

# Lambda Permission for CloudWatch
resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.nyctaxi_ingestion.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.monthly_trigger.arn
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/${aws_lambda_function.nyctaxi_ingestion.function_name}"
  retention_in_days = 7  # Keep logs for 7 days

  tags = {
    Project = "nyctaxi-ml-pipeline"
  }
}

# CloudWatch Alarm for Lambda errors
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "nyctaxi-ingestion-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 86400  # 24 hours
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "This alarm triggers if Lambda function has errors"

  dimensions = {
    FunctionName = aws_lambda_function.nyctaxi_ingestion.function_name
  }

  alarm_actions = []  # Add SNS topic ARN for notifications

  tags = {
    Project = "nyctaxi-ml-pipeline"
  }
}

# Zip the lambda/ folder and create lambda_function.zip
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"       # Go up to root, then into lambda folder
  output_path = "${path.module}/../lambda_function.zip"
}

# Outputs
output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.nyctaxi_ingestion.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.nyctaxi_ingestion.arn
}

output "cloudwatch_rule_arn" {
  description = "ARN of the CloudWatch event rule"
  value       = aws_cloudwatch_event_rule.monthly_trigger.arn
}

output "iam_role_arn" {
  description = "ARN of the IAM role for Lambda"
  value       = aws_iam_role.lambda_exec.arn
}