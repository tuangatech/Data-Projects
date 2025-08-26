import boto3
import requests
from datetime import datetime, timedelta
import time
import os
import logging

# Set up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    logger.info("=== NYC Taxi Data Ingestion Started ===")
    logger.info(f"Event: {event}")
    logger.info(f"Context: {context}")

    s3_client = boto3.client('s3')
    cloudwatch = boto3.client('cloudwatch')
    
    s3_bucket = os.getenv('S3_BUCKET') # Set in Lambda environment variables
    s3_prefix = os.getenv('S3_PREFIX') # Set in Lambda environment variables, e.g., "nyctaxi/raw/"

    logger.info(f"Configuration - S3 Bucket: {s3_bucket}, Prefix: {s3_prefix}")
    
    # Find the previous month
    now = datetime.now()
    target_date = now - timedelta(days=30)  # Previous month
    year = str(target_date.year)
    month = str(target_date.month).zfill(2)
    logger.info(f"Target month: {year}-{month}")

    try:
        # Check if already exists
        if file_exists_in_s3(s3_client, s3_bucket, s3_prefix, year, month):
            logger.warning(f"Data for {year}-{month} already exists in S3. Skipping download.")
            put_skipped_metric(cloudwatch, year, month) 
            return {
                'statusCode': 200,
                'body': f"Data already exists for {year}-{month}"
            }
        
        # Try to download
        if process_month(s3_client, cloudwatch, s3_bucket, s3_prefix, year, month):
            logger.info(f"Successfully processed {year}-{month}")
            put_success_metric(cloudwatch, year, month)
            return {
                'statusCode': 200,
                'body': f"Successfully processed {year}-{month}"
            }
        
    except Exception as e:
        logger.error(f"Unexpected error in Lambda handler: {str(e)}", exc_info=True)
        put_failure_metric(cloudwatch)
        return {
            'statusCode': 500,
            'body': f"Unexpected error: {str(e)}"
        }

def file_exists_in_s3(s3_client, bucket, prefix, year, month):
    """Check if file already exists in S3"""
    file_name = f"yellow_tripdata_{year}-{month}.parquet"
    s3_key = f"{prefix}year={year}/month={month}/{file_name}"
    
    try:
        s3_client.head_object(Bucket=bucket, Key=s3_key)
        print(f"File already exists: s3://{bucket}/{s3_key}")
        return True
    except s3_client.exceptions.ClientError as e:
        if e.response['Error']['Code'] == '404':
            return False
        else:
            # Other error (permissions, etc.)
            print(f"Error checking S3: {e}")
            return False

def process_month(s3_client, cloudwatch, bucket, prefix, year, month):
    """Process a specific month's data with performance metrics"""
    file_name = f"yellow_tripdata_{year}-{month}.parquet"
    url = f"https://d37ci6vzurychx.cloudfront.net/trip-data/{file_name}"
    s3_key = f"{prefix}year={year}/month={month}/{file_name}"
    
    start_time = time.time()
    download_success = False
    file_size_bytes = 0
    download_duration = 0
    
    try:
        logger.info(f"Attempting download: {url}")
        
        for attempt in range(3):  # Retry logic
            try:
                attempt_start = time.time()
                
                # Download with timeout
                response = requests.get(url, stream=True, timeout=30)
                response.raise_for_status()
                
                # Get file size from headers
                file_size_bytes = int(response.headers.get('content-length', 0))
                logger.info(f"File size: {file_size_bytes} bytes ({file_size_bytes/1024/1024:.2f} MB)")
                
                # Upload to S3 and measure duration
                upload_start = time.time()
                s3_client.upload_fileobj(
                    response.raw,
                    bucket,
                    s3_key
                )
                upload_duration = time.time() - upload_start
                
                # Calculate total download duration
                download_duration = time.time() - attempt_start
                download_success = True
                
                logger.info(f"Successfully uploaded to s3://{bucket}/{s3_key}")
                logger.info(f"Download & upload completed in {download_duration:.2f} seconds")
                logger.info(f"Upload only took {upload_duration:.2f} seconds")
                logger.info(f"Throughput: {file_size_bytes/download_duration/1024/1024:.2f} MB/s")
                
                # Send performance metrics to CloudWatch
                send_performance_metrics(
                    cloudwatch, 
                    year, 
                    month, 
                    download_duration, 
                    upload_duration,
                    file_size_bytes,
                    True  # success
                )
                
                return True
                
            except requests.exceptions.RequestException as e:
                attempt_duration = time.time() - attempt_start
                logger.warning(f"Attempt {attempt + 1} failed in {attempt_duration:.2f}s: {e}")
                
                # Log failed attempt metrics
                if attempt == 2:  # Last attempt
                    send_performance_metrics(cloudwatch, year, month, attempt_duration, 0, 0, False)  # failure                    
                    raise
                time.sleep(2 ** attempt)  # Exponential backoff
                
    except Exception as e:
        error_duration = time.time() - start_time
        logger.error(f"Failed {file_name} after {error_duration:.2f}s: {str(e)}")        
        # Log final failure metrics
        send_performance_metrics(cloudwatch, year, month, error_duration, 0, 0, False)  # failure        
        return False

def send_performance_metrics(cloudwatch, year, month, download_duration, upload_duration, file_size_bytes, success):
    """Send detailed performance metrics to CloudWatch"""
    try:
        metric_data = []
        
        # Download duration metric
        metric_data.append({
            'MetricName': 'DownloadDuration',
            'Dimensions': [
                {'Name': 'Year', 'Value': year},
                {'Name': 'Month', 'Value': month},
                {'Name': 'Status', 'Value': 'Success' if success else 'Failure'}
            ],
            'Value': download_duration,
            'Unit': 'Seconds'
        })
        
        # Upload duration metric (only for successful downloads)
        if success and upload_duration > 0:
            metric_data.append({
                'MetricName': 'UploadDuration',
                'Dimensions': [
                    {'Name': 'Year', 'Value': year},
                    {'Name': 'Month', 'Value': month}
                ],
                'Value': upload_duration,
                'Unit': 'Seconds'
            })
        
        # File size metric (only for successful downloads)
        if success and file_size_bytes > 0:
            metric_data.append({
                'MetricName': 'FileSize',
                'Dimensions': [
                    {'Name': 'Year', 'Value': year},
                    {'Name': 'Month', 'Value': month}
                ],
                'Value': file_size_bytes,
                'Unit': 'Bytes'
            })
            
            # Also log in MB for easier reading
            metric_data.append({
                'MetricName': 'FileSizeMB',
                'Dimensions': [
                    {'Name': 'Year', 'Value': year},
                    {'Name': 'Month', 'Value': month}
                ],
                'Value': file_size_bytes / (1024 * 1024),
                'Unit': 'Megabytes'
            })
        
        # Throughput metric (MB/s)
        if success and download_duration > 0 and file_size_bytes > 0:
            throughput = file_size_bytes / download_duration / (1024 * 1024)  # MB/s
            metric_data.append({
                'MetricName': 'DownloadThroughput',
                'Dimensions': [
                    {'Name': 'Year', 'Value': year},
                    {'Name': 'Month', 'Value': month}
                ],
                'Value': throughput,
                'Unit': 'Megabytes/Second'
            })
        
        # Send all metrics in one call (more efficient)
        if metric_data:
            cloudwatch.put_metric_data(
                Namespace='NYCTaxiDownload',
                MetricData=metric_data
            )
            logger.debug(f"Sent {len(metric_data)} performance metrics to CloudWatch")
            
    except Exception as e:
        logger.error(f"Failed to send performance metrics to CloudWatch: {e}")

def put_success_metric(cloudwatch, year, month):
    """Record overall job success"""
    try:
        cloudwatch.put_metric_data(
            Namespace='NYCTaxiDownload',
            MetricData=[{
                'MetricName': 'JobSuccess',
                'Dimensions': [
                    {'Name': 'Year', 'Value': year},
                    {'Name': 'Month', 'Value': month}
                ],
                'Value': 1.0,
                'Unit': 'Count'
            }]
        )
        logger.info(f"Recorded job success for {year}-{month}")
    except Exception as e:
        logger.error(f"Failed to record success metric: {e}")

def put_failure_metric(cloudwatch, year, month):
    """Record overall job failure"""
    try:
        cloudwatch.put_metric_data(
            Namespace='NYCTaxiDownload',
            MetricData=[{
                'MetricName': 'JobFailure', 
                'Dimensions': [
                    {'Name': 'Year', 'Value': year},
                    {'Name': 'Month', 'Value': month}
                ],
                'Value': 1.0,
                'Unit': 'Count'
            }]
        )
        logger.error(f"Recorded job failure for {year}-{month}")
    except Exception as e:
        logger.error(f"Failed to record failure metric: {e}")

def put_skipped_metric(cloudwatch, year, month):
    """Record skipped download (already exists)"""
    try:
        cloudwatch.put_metric_data(
            Namespace='NYCTaxiDownload',
            MetricData=[{
                'MetricName': 'JobSkipped',
                'Dimensions': [
                    {'Name': 'Year', 'Value': year},
                    {'Name': 'Month', 'Value': month}
                ],
                'Value': 1.0,
                'Unit': 'Count'
            }]
        )
        logger.info(f"Recorded job skipped for {year}-{month}")
    except Exception as e:
        logger.error(f"Failed to record skipped metric: {e}")
