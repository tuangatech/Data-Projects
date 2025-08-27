import json
import boto3
import os
import re
import logging
import requests
from datetime import datetime

# Setup logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    """
    Lambda function triggered by S3 events via EventBridge
    Triggers Databricks job for NYC taxi data processing
    """
    
    logger.info(f"Received event: {json.dumps(event, default=str)}")
    
    try:
        # Initialize AWS clients
        cloudwatch = boto3.client('cloudwatch')
        
        # Extract S3 details from EventBridge event
        detail = event.get('detail', {})
        bucket = detail.get('bucket', {}).get('name')
        key = detail.get('object', {}).get('key')
        
        if not bucket or not key:
            logger.error("Missing bucket or key in event")
            return {
                'statusCode': 400,
                'body': json.dumps('Invalid event structure')
            }
        
        logger.info(f"Processing S3 event: s3://{bucket}/{key}")
        
        # Validate it's a yellow taxi file
        if 'yellow_tripdata' not in key or not key.endswith('.parquet'):
            logger.info(f"Skipping non-yellow-taxi file: {key}")
            return {
                'statusCode': 200,
                'body': json.dumps('Not a yellow taxi parquet file - skipping')
            }
        
        # Extract year/month from S3 key pattern: nyctaxi/raw/year=2024/month=01/yellow_tripdata_2024-01.parquet
        year_match = re.search(r'year=(\d{4})', key)
        month_match = re.search(r'month=(\d{2})', key)
        
        if not year_match or not month_match:
            logger.error(f"Could not extract year/month from key: {key}")
            return {
                'statusCode': 400, 
                'body': json.dumps('Could not extract year/month from S3 key')
            }
        
        year = year_match.group(1)
        month = month_match.group(1)
        
        logger.info(f"Extracted date: Year={year}, Month={month}")
        
        # Trigger Databricks job
        job_run_id = trigger_databricks_job(bucket, key, year, month)
        
        # Send success metric to CloudWatch
        send_cloudwatch_metric(
            cloudwatch,
            'JobTriggered',
            1,
            [
                {'Name': 'Year', 'Value': year},
                {'Name': 'Month', 'Value': month},
                {'Name': 'Status', 'Value': 'Success'}
            ]
        )
        
        logger.info(f"Successfully triggered Databricks job. Run ID: {job_run_id}")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Job triggered successfully',
                'run_id': job_run_id,
                'year': year,
                'month': month,
                's3_file': f's3://{bucket}/{key}'
            })
        }
        
    except Exception as e:
        logger.error(f"Error processing event: {str(e)}")
        
        # Send failure metric
        try:
            cloudwatch = boto3.client('cloudwatch')
            send_cloudwatch_metric(
                cloudwatch,
                'JobTriggerFailed',
                1,
                [{'Name': 'Error', 'Value': str(e)[:50]}]  # CloudWatch dimension value max 255 chars
            )
        except:
            pass  # Don't fail on metric sending failure
        
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e),
                'message': 'Failed to trigger processing job'
            })
        }

def trigger_databricks_job(bucket, key, year, month):
    """
    Trigger Databricks job using REST API with requests library
    """
    
    # Get configuration from environment variables
    databricks_host = os.environ['DATABRICKS_HOST']
    databricks_job_id = os.environ['DATABRICKS_JOB_ID']
    secret_arn = os.environ['DATABRICKS_SECRET_ARN']
    
    # Get Databricks token from Secrets Manager
    databricks_token = get_databricks_token(secret_arn)

    logger.debug(f"Using Databricks host: {databricks_host}, Job ID: {databricks_job_id}, Secret ARN: {secret_arn}")
    
    # Databricks API endpoint
    api_url = f"{databricks_host}/api/2.1/jobs/run-now"
    
    # Headers
    headers = {
        'Authorization': f'Bearer {databricks_token}',
        'Content-Type': 'application/json'
    }
    
    # Job parameters
    payload = {
        'job_id': int(databricks_job_id),
        'notebook_params': {
            'source_year': year,
            'source_month': month,
            'source_bucket': bucket,
            'source_key': key
        }
    }
    
    logger.info(f"Triggering Databricks job {databricks_job_id} with params: {payload['notebook_params']}")
    
    # Make API call
    response = requests.post(api_url, headers=headers, json=payload, timeout=30)
    
    if response.status_code == 200:
        result = response.json()
        run_id = result.get('run_id')
        logger.info(f"Databricks job triggered successfully. Run ID: {run_id}")
        return run_id
    else:
        error_msg = f"Databricks API error: {response.status_code} - {response.text}"
        logger.error(error_msg)
        raise Exception(error_msg)

def get_databricks_token(secret_arn):
    """
    Retrieve Databricks token from AWS Secrets Manager
    """
    try:
        secrets_client = boto3.client('secretsmanager')
        response = secrets_client.get_secret_value(SecretId=secret_arn)
        secret = json.loads(response['SecretString'])
        return secret['token']
    except Exception as e:
        logger.error(f"Failed to retrieve Databricks token: {e}")
        raise Exception(f"Failed to retrieve Databricks token: {e}")

def send_cloudwatch_metric(cloudwatch_client, metric_name, value, dimensions=None):
    """Send custom metrics to CloudWatch"""
    try:
        metric_data = {
            'MetricName': metric_name,
            'Value': value,
            'Unit': 'Count',
            'Timestamp': datetime.utcnow()
        }
        
        if dimensions:
            metric_data['Dimensions'] = dimensions
        
        cloudwatch_client.put_metric_data(
            Namespace='NYCTaxiProcessing',
            MetricData=[metric_data]
        )
        
        logger.info(f"CloudWatch metric sent: {metric_name} = {value}")
    except Exception as e:
        logger.error(f"Failed to send CloudWatch metric: {e}")
        # Don't raise exception for metric failures