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

# ===== DATA INGESTION RESOURCES =====

# Lambda function for data ingestion
resource "aws_lambda_function" "nyctaxi_ingestion" {
  function_name = "nyctaxi-data-ingestion"
  description   = "Downloads NYC taxi data monthly and saves to S3"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.10"
  timeout       = 900  # 15 minutes
  memory_size   = 512   # 512 MB

  filename         = data.archive_file.ingestion_lambda_zip.output_path   # Path to the zipped code (below)
  source_code_hash = data.archive_file.ingestion_lambda_zip.output_base64sha256

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
# event target is the lambda function, event rule is the schedule
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.monthly_trigger.name
  target_id = "nyctaxi-lambda-target"
  arn       = aws_lambda_function.nyctaxi_ingestion.arn     # refer to the lambda function created above "aws_lambda_function"
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
# Alarm if Errors > 0 for 1 datapoints within 1 day
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
data "archive_file" "ingestion_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"       # Go up to root, then into lambda folder
  output_path = "${path.module}/../ingestion_lambda_function.zip"
  excludes    = ["processing_trigger.py"]  # Exclude data processing function
}


# ===== DATA PROCESSING RESOURCES =====

# Secrets Manager for Databricks token
resource "aws_secretsmanager_secret" "databricks_token" {
  name                    = "nyctaxi/databricks-token"
  description             = "Databricks personal access token for NYC taxi processing"
  recovery_window_in_days = 7

  tags = {
    Project = "nyctaxi-ml-pipeline"
  }
}

# Store the Databricks token (you'll need to set this manually after creation)
resource "aws_secretsmanager_secret_version" "databricks_token" {
  secret_id = aws_secretsmanager_secret.databricks_token.id
  secret_string = jsonencode({
    token = "PLACEHOLDER_TOKEN"  # Replace with actual token using AWS CLI
  })

  lifecycle {
    ignore_changes = [secret_string]    # Prevent Terraform from overwriting the actual secret in Secrets Manager
  }
}

# Lambda function for data processing trigger
resource "aws_lambda_function" "nyctaxi_processing_trigger" {
  function_name = "nyctaxi-processing-trigger"
  description   = "Triggers Databricks processing when new taxi data arrives"
  role          = aws_iam_role.processing_lambda_exec.arn
  handler       = "processing_trigger.lambda_handler"
  runtime       = "python3.10"
  timeout       = 60   # 1 minute
  memory_size   = 256  # 256 MB

  filename         = data.archive_file.processing_lambda_zip.output_path    # Path to the zipped code (below)
  source_code_hash = data.archive_file.processing_lambda_zip.output_base64sha256

  environment {
    variables = {
      DATABRICKS_HOST        = var.databricks_host
      DATABRICKS_JOB_ID      = var.databricks_job_id
      DATABRICKS_SECRET_ARN  = aws_secretsmanager_secret.databricks_token.arn
    }
  }

  tags = {
    Project     = "nyctaxi-ml-pipeline"
    Environment = "production"
  }
}

# IAM role for processing Lambda
resource "aws_iam_role" "processing_lambda_exec" {
  name = "nyctaxi-processing-lambda-role"

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

# IAM policy for processing Lambda: create logs, put metrics, s3 read, secretsmanager read
resource "aws_iam_role_policy" "processing_lambda_policy" {
  name = "nyctaxi-processing-lambda-policy"
  role = aws_iam_role.processing_lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = [
          "arn:aws:s3:::databricks-workspace-stack-06ea8-bucket/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.databricks_token.arn
      }
    ]
  })
}

# Enable S3 EventBridge notifications
resource "aws_s3_bucket_notification" "taxi_data_notification" {
  bucket      = "databricks-workspace-stack-06ea8-bucket"
  eventbridge = true
}

# EventBridge rule for S3 object creation
resource "aws_cloudwatch_event_rule" "s3_taxi_data_rule" {
  name        = "nyctaxi-s3-processing-trigger"
  description = "Triggers processing when new NYC taxi data arrives in S3"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = ["databricks-workspace-stack-06ea8-bucket"]
      }
      object = {
        key = [
          {
            prefix = "nyctaxi/raw/"
          }
        ]
      }
    }
  })

  tags = {
    Project = "nyctaxi-ml-pipeline"
  }
}

# EventBridge target for processing Lambda
# target is the lambda function, rule is the event pattern above "Object Created" in an S3 bucket
resource "aws_cloudwatch_event_target" "processing_lambda_target" {
  rule      = aws_cloudwatch_event_rule.s3_taxi_data_rule.name
  target_id = "nyctaxi-processing-target"
  arn       = aws_lambda_function.nyctaxi_processing_trigger.arn
}

# Lambda Permission for EventBridge
# Allow EventBridge to invoke the processing lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.nyctaxi_processing_trigger.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_taxi_data_rule.arn
}

# CloudWatch Log Group for processing Lambda
resource "aws_cloudwatch_log_group" "processing_lambda_log_group" {
  name              = "/aws/lambda/${aws_lambda_function.nyctaxi_processing_trigger.function_name}"
  retention_in_days = 14

  tags = {
    Project = "nyctaxi-ml-pipeline"
  }
}

# CloudWatch Alarms for processing pipeline
# Alarm if Errors > 0 for 1 datapoints within 5 minutes
resource "aws_cloudwatch_metric_alarm" "processing_lambda_errors" {
  alarm_name          = "nyctaxi-processing-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300  # 5 minutes
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "This alarm triggers if processing Lambda function has errors"

  dimensions = {
    FunctionName = aws_lambda_function.nyctaxi_processing_trigger.function_name
  }

  alarm_actions = []

  tags = {
    Project = "nyctaxi-ml-pipeline"
  }
}

# Zip the lambda/ folder for processing trigger (separate zip file)
data "archive_file" "processing_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/../processing_lambda_function.zip"
  excludes    = ["ingestion.py"]  # Exclude ingestion function
}

# ===== VARIABLES =====

variable "databricks_host" {
  description = "Databricks workspace host URL"
  type        = string
  default     = "https://id.cloud.databricks.com/"  # Actual job ID in terraform.tfvars
}

variable "databricks_job_id" {
  description = "Databricks job ID for processing"
  type        = string
  default     = "123456789"  # Actual job ID in terraform.tfvars
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

output "processing_lambda_function_name" {
  description = "Name of the processing trigger Lambda function"
  value       = aws_lambda_function.nyctaxi_processing_trigger.function_name
}

output "processing_lambda_function_arn" {
  description = "ARN of the processing trigger Lambda function"
  value       = aws_lambda_function.nyctaxi_processing_trigger.arn
}

output "databricks_secret_arn" {
  description = "ARN of the Databricks token secret"
  value       = aws_secretsmanager_secret.databricks_token.arn
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge rule for S3 events"
  value       = aws_cloudwatch_event_rule.s3_taxi_data_rule.arn
}