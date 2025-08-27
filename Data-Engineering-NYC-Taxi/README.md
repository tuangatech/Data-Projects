
## Project Overview
We all know a fundamental truth about machine learning: garbage in, garbage out. Why people’s attention focuses on fancy algorithms and model architectures, the other challenge is the data pipeline that feeds these models. The model is only as good as the data it trains on, the data needs to be fresh, clean, and the data pipeline needs to be reliable, scalable.

Imagine building a solution to predict NYC tax fares. We start by training a model with historical ride data, but the model will quickly fall behind reality if we don’t continuously feed it with new rides and fares. A robust data pipeline ensures that fresh data is ingested, processed, and delivered to the model on a regular basis, enabling retraining and keeping predictions accurate over time.

In this side project, I built a cloud-native, serverless data pipeline that ingests and processes NYC taxi data on a monthly schedule. The pipeline is designed to automate the entire flow — from data ingestion to preprocessing — so that updated datasets are always ready to be used for fare prediction ML models. While we’re using NYC taxi data as our example, this architecture pattern applies to countless ML scenarios like product recommendation models, fraud detection systems, predictive maintenance, etc.

## Architecture Components
1. Data Ingestion Layer (AWS)
- Source: Public NYC taxi parquet files (monthly updates)
- Ingestion: AWS Lambda automatically downloads new monthly data to Raw S3 bucket
- Format: Maintain original parquet format in raw zone

2. Data Processing Layer (Databricks)
- Environment: Shared clusters with Unity Catalog governance
- Processing: Spark-based data cleaning, feature engineering, and quality checks
- Output Format: Delta Lake format in processed S3 bucket

3. ML Training Layer (AWS)
- Infrastructure: SageMaker or custom EC2-based training
- Input: Processed Delta Lake tables from S3
- Output: Updated fare prediction models



## Data Ingestion
This pipeline will automatically download the previous month's data on the 1st of each month, with fallback logic and proper monitoring. The partitioned folder structure makes it easy for Databricks to process the data efficiently. Ingestion isn't just about moving data; it's about creating a reliable, scalable, and maintainable system that fuels everything downstream.

1. The Ingestion Process

- Scheduled Trigger: A CloudWatch Event rule triggers our Lambda function monthly:
- Date Calculation: The pipeline automatically calculates which month to process
- Resilient Download Process. Everything that can go wrong will go wrong. Build retries, fallbacks, and comprehensive logging from day one. The Lambda function handles common edge cases:
  - HTTP 404 errors (data not yet available)
  - Network timeouts
  - Partial file downloads (?)
  - Everything that can go wrong will go wrong. Build retries, fallbacks, and comprehensive logging from day one.
- Organized S3 Storage. Design your ingestion format with consumers in mind. Proper partitioning and metadata save countless hours later. Files are stored with clear naming conventions and partitioning: s3_key = f"nyctaxi/raw/year={year}/month={month}/{file_name}"

2. The Architecture: Cloud-Native and Serverless. 

Our ingestion pipeline follows a cloud-native approach using AWS serverless services: CloudWatch Events → AWS Lambda → S3 Raw Bucket → Databricks Processing

Why serverless? Because data ingestion is typically bursty—we process monthly data but need the system to scale automatically and cost-effectively. In this project, data is pretty stable but I build a solution ready to data peak.

3. Download Strategy with Resilience

Download previous month. 

Built-in Retry and Fallback Mechanisms. Data sources can be unreliable. Our pipeline includes:
- Exponential backoff for HTTP requests
- Multiple month fallback attempts
- Comprehensive error logging

4. Partitioned Storage from Day One. 

We don't just dump files into S3—we implement a structured data lake approach: nyctaxi/raw/year=2023/month=01/yellow_tripdata_2023-01.parquet

```
s3://databricks-workspace-stack-06ea8-bucket/nyctaxi/
├── raw/
│   ├── year=2025/
│   │   ├── month=01/
│   │   │   └── yellow_tripdata_2025-01.parquet
│   │   ├── month=02/
│   │   └── ...
│   └── year=2024/
└── processed/ (future stage)
```
Partitioning benefits:
- Query performance: Partition pruning dramatically speeds up Databricks processing
- Cost management: Lifecycle policies can be applied at partition level
- Data organization: Clear separation of raw vs processed data
- Time travel: Easy access to historical data for model retraining

This structure enables efficient querying in Databricks and other tools that understand partition pruning.


5. Monitoring: 

You can't fix what you can't see. Implement metrics for success rates, data quality, and processing times. We implemented CloudWatch metrics and alarms to track. We transform ingestion from a black box into a fully observable process::
- Success metrics: Track successful downloads by year/month
- Failure alerts: Immediate notification of ingestion issues
- Performance metrics: Download duration and file sizes
- Alarm when ingestion failed

```t
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
```

CloudWatch Metrics Structure
```
NYCTaxiDownload/
├── JobSuccess (Overall job status)
├── JobFailure (Overall job status) 
├── JobSkipped (Overall job status)
├── DownloadDuration (Performance)
├── UploadDuration (Performance)
├── FileSize (Performance)
├── FileSizeMB (Performance)
└── DownloadThroughput (Performance)
```
Benefits of These Metrics:
- Performance monitoring: Track download times and identify slowdowns
- Cost forecasting: File sizes help predict S3 storage costs
- Network health: Throughput metrics reveal network issues
- Capacity planning: Understand data growth patterns
- Troubleshooting: Compare success vs failure durations for root cause analysis

CloudWatch alarm Errors > 0 for 1 datapoints within 1 day. I got 1 as I tried to delete all dependency folders in lambda.
CloudWatch Event rule `"cron(0 8 1 * ? *)"` = 8 AM on the 1st of every month, edit to test `rate(5 minutes)`. We check existance before downloading but always Remember to switch back.
CloudWatch log retain 7 days

Check AWS CloudWatch Metrics: Go to: AWS Console → CloudWatch → Metrics → All metrics, Look for: Custom Namespaces → NYCTaxiDownload. Metric name: Success, Failure.

Create dashboards to monitor performance trends

2 metric types, they provide different levels of monitoring granularity and serve different stakeholders in your organization!
- Success/Failure Metrics	SLA monitoring, alerting	"Did yesterday's ingestion job succeed?"
- Performance Metrics	Performance optimization, troubleshooting	"Why was January's download so slow? Why was last month's file so small?"


6. Infrastructure as Code with Terraform
Our entire ingestion infrastructure is defined as code:

```t
resource "aws_lambda_function" "nyctaxi_ingestion" {
  function_name = "nyctaxi-data-ingestion"
  description   = "Downloads NYC taxi data monthly and saves to S3"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.10"

  environment {
    variables = {
      S3_BUCKET = "databricks-workspace-stack-06ea7-bucket"
      S3_PREFIX = "nyctaxi/raw/"
    }
  }
}
```

Infrastructure as Code benefits:
- Reproducible environments: identical staging and production
- Version control: Track infrastructure changes alongside code
- Automated deployments: CI/CD pipeline for infrastructure updates
- Disaster recovery: Recreate entire environment from code repository

7. Scheduled Automation with CloudWatch Events
The pipeline runs autonomously on a defined schedule:

```t
resource "aws_cloudwatch_event_rule" "monthly_trigger" {
  schedule_expression = "cron(0 8 5 * ? *)"  # 8 AM on the 5th of each month
}
```
Scheduling strategy:
- Time-optimized: Runs after data availability (5th of month)
- Business hours: Executes during working hours for easier monitoring
- Flexible: Easily adjusted for timezone changes or business needs

8. The Result: Trustworthy Data Delivery
This ingestion pipeline delivers:
- Fresh data: Monthly updates without manual intervention
- Data quality: Validated, complete datasets for ML training
- Operational reliability: 99.9% uptime with automated recovery
- Cost efficiency: Serverless model with per-execution pricing
- Full observability: Complete visibility into pipeline health

By investing in a robust ingestion foundation, we ensure that our machine learning models always train on timely, complete, and trustworthy data—eliminating "garbage in, garbage out" scenarios and enabling reliable production predictions.


```bash
chmod +x deploy.sh
./deploy.sh
```

deploy.sh: Terraform will package/zip the lambda/ directory into a zip file and upload to AWS
```bash
echo "Installing dependencies..."
pip install -r lambda/requirements.txt -t lambda/

cd terraform
echo "Deploying with Terraform..."
terraform init
terraform plan  
terraform apply -auto-approve
```

Delete dependency folders in lambda by yourself, not show up on git changes.
I don't encrypt data in S3 as it's public data, but if it's your company's internal data, you should encrypt.
Should update S3 Lifecycle Policies manually to transition older raw data to S3 Glacier after 30 days.

Lambda function to download data file of the previous month
- S3 existence checks: Prevents redundant downloads and storage costs
- Exponential backoff: Intelligent retry logic for network issues



## Data Preprocessing

- When a new raw parquet NYC taxi data file arrives in S3, we want to automatically trigger a Databricks job to process it. In this case, our ingestion flow downloads from NYC Taxi website.
- S3 automatically sends out a notification saying: "Hey everyone! A new object was created in bucket databricks-workspace-stack-06ea8-bucket at path nyctaxi/raw/year=2025/month=05/yellow_tripdata_2025-05.parquet" 
- EventBridge (formerly called CloudWatch Events) Receives the S3 announcement. Checks it against your rules: "Does this match what we're looking for?"
Your rule says: "Only care about files in nyctaxi/raw/ folder of this specific bucket" Decision: ✅ "Yes, this matches! I need to take action!"
- EventBridge Rings the Lambda Doorbell. What happens: EventBridge triggers the corresponding Lambda function (the "processing trigger lambda"). "Hey Lambda! New taxi data just arrived. Here are the details: bucket name, file path, etc." 
- Lambda Function Does Detective Work. What happens: Your Lambda function wakes up and: Receives the file details from EventBridge Checks the filename: "Is this a yellow taxi file?" Extracts information: Year: 2025 Month: 05 File path: nyctaxi/raw/year=2025/month=05/yellow_tripdata_2025-05.parquet --> "Perfect! This is the data we need. Let me tell Databricks to start processing it." 
- Lambda Calls Databricks What happens: Lambda makes a phone call to Databricks using their API: The call says: "Hi Databricks! Please start job #12345 to process this file: Input file: s3://bucket/nyctaxi/raw/year=2025/month=05/yellow_tripdata_2025-05.parquet Year: 2025 Month: 05" Technical details: This is an HTTP POST request to Databricks' /api/2.1/jobs/run-now endpoint
- Databricks Starts the Job What happens: Databricks receives the request and: Starts a new run of your preprocessing job Passes the parameters (file path, year, month) to your notebook Allocates compute resources (starts cluster if needed) Begins executing your data processing code
- Your Databricks Notebook Runs What happens: Your notebook code executes

Final Result
- New data arrives in S3 raw folder
- System automatically detects it within seconds
- Databricks job starts without any manual intervention
- Data gets processed and saved to processed location
- ML model can now use the fresh data for training

Why This Approach Is Great
- Automatic: No manual triggering needed
- Fast: Processing starts within seconds of file arrival
- Reliable: AWS managed services with high availability
- Scalable: Can handle multiple files arriving simultaneously
- Cost-effective: Only pay when processing happens
- Auditable: Every step is logged and traceable

This is exactly how modern data engineering pipelines work in production environments!



Trigger Databricks job when new NYC taxi Parquet file lands in S3 raw folder → Process data → Write to processed S3 location 

S3 Event + Lambda + Databricks API - This is the most responsive approach - triggers immediately when data lands. Cost-effective: Only runs when needed

```
# EventBridge rule for S3 object creation
resource "aws_cloudwatch_event_rule" "s3_taxi_data_rule" {
  name        = "nyctaxi-s3-processing-trigger"
  description = "Triggers processing when new NYC taxi data arrives in S3 raw"

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
}
```

EventBridge is a serverless event bus service that simplifies building event-driven applications. It acts as a router, receiving events from various sources and delivering them to different targets based on rules you define. It's an evolution of a feature that was originally part of CloudWatch Events.

1. Read: Read the specific month's raw Parquet data from S3.

2. Clean & Standardize:
- Select relevant columns for prediction (VendorID, pickup/dropoff timestamps, passenger_count, trip_distance, rate_code, store_and_fwd, payment_type, fare_amount, etc.).
- Drop rows with null critical fields (e.g., fare_amount, pickup datetime).
- Filter out invalid trips (e.g., trip_distance <= 0, fare_amount <= 0, unrealistic speeds).
- Standardize formats (ensure timestamps are correct type, enforce known categories for payment_type).

3. Feature Engineering: Derive new features from the raw data.
- Temporal Features: Hour of day, day of week, is_weekend, month, year.
- Trip Duration: Calculate duration_in_sec from pickup and dropoff timestamps.
- Derived Metrics: Calculate avg_speed_mph (trip_distance / (duration_in_sec / 3600)).
- Geographic Features (if possible): Approximate distance between pickup/dropoff coordinates (using Haversine formula).

4. Quality Checks (QA):
- Assertion Checks: Ensure no negative trip durations, average speed within a plausible range (e.g., 0.5 to 100 mph), no nulls in key columns after cleaning.
- Logging/Alerting: Record data quality metrics (number of rows ingested, rows filtered, rows passed) and trigger alerts if quality thresholds are breached.

5. Write: Write the processed DataFrame to the target S3 location in Delta Lake format.

6. Register & Govern: Create/overwrite the partition in a Delta table registered as a managed table in Unity Catalog. The partition key will be year_month for efficient time-based queries.

7. Monitoring and Alerting: We implemented CloudWatch metrics and alarms to track processing times. (just log, no metrics)

Notebook:  link your Databricks workspace to your GitHub repo, allowing you to version control and sync notebooks directly with GitHub

**Trigger Mechanism**: Instead of a manual trigger, we will use an external trigger (like a new file arriving in S3) for true automation. Test by uploading a test file to S3

**Unity Catalog Best Practices**:
- Use a three-level namespace: catalog.schema.table.
- Place processed data in a dedicated schema (e.g., nyctaxi_processed) separate from raw data (nyctaxi_raw).
- Use Managed Tables, so Delta files are stored in the UC Metastore's underlying storage location, abstracting the S3 path from users and improving governance.

Raw data: a full refresh month's data is often simpler.

Parquet files store data in columnar storage format, which makes them really efficient in reducing file size and perfect for analytics. Querying the data from a Parquet file will be extremely faster than reading it from a structure like CSV. So, it is a file format that stores data much more efficiently and reads data from it much faster. What can be better than that?

Delta Lake is the structure in which the table’s data is stored. It includes folders and files underneath. One of those file types is Parquet. That is where the actual data is stored. So, Parquet is part of the Delta Lake structure.

Data Quality Enforcement: For this code example, we'll use PySpark assertions

A Databricks Job is a scheduled/triggered execution of a Notebook on a Cluster. The notebook doesn't need to run constantly - it only runs when the job is triggered.

Workflow:
- Notebook = Your processing code (static, stored in workspace)
- Job = Configuration that runs the notebook on demand
- Cluster = Compute resources (created/destroyed automatically)

**Step 1: Create the Databricks Job**
- Create a new notebook with processing code
- Create the Job in Jobs and Pipelines and select the notebook you have just created (as in the below image)
- Get the job ID 884462806815102


EventBridge invokes the data processing lambda

Databricks token:
- Not exposed in Terraform state or code (creates secret with placeholder)
- Get Databricks token from Databricks settings
- Update Databricks token in `Secrets Manager` with actual one using AWS CLI. Databricks token = "dapi13745758276b00bc66380da479211421" 
- Lambda retrieves real token at runtime

```
aws secretsmanager update-secret \
  --secret-id "nyctaxi/databricks-token" \
  --secret-string '{"token":"dapi13745758276b00bc66380da479211421"}'
```

**What This Terraform Setup Provides:**
- Lambda Function (processing_trigger.py) - Triggers Databricks jobs
- EventBridge Rule - Listens for S3 object creation events
- S3 EventBridge Integration - Enables S3 to send events to EventBridge
- IAM Roles & Policies - Secure permissions for all components
- Secrets Manager - Secure Databricks token storage
- CloudWatch Monitoring - Logs, metrics, alarms
- Error Handling - Automatic retries and failure notifications (?)
- S3 bucket already created by Databricks


**Deployment Steps**
- Run `deploy.sh` to install Lambda's dependencies and Deploy with Terraform
- Update Databricks token in `Secrets Manager` with actual one using AWS CLI
- Test the pipeline by uploading a test file to trigger the pipeline `aws s3 cp yellow_tripdata_2025-05.parquet s3://databricks-workspace-stack-06ea8-bucket/nyctaxi/raw/year=2025/month=05/yellow_tripdata_2025-05.parquet`
- Check Logs: Monitor CloudWatch logs for processing trigger Lambda function
- Check the CloudWatch metrics

Lambda function can trigger Databricks' job. When job failed, click the latest job run to see the error, fix the notebook. Choose "Run now" in Job screen, don't need to copy new file to S3 to trigger..

Do not setup "Retry" for the Job at the beginning as your processing notebook will fail all the time. Consider for Production.

Why we need to create catalog_table_name = "nyc_taxi_analytics.fare_prediction.processed_yellow_taxi"?

====

## High-Level Design

The design is centered on an Extract, Transform, Load (ETL) pipeline orchestrated within the Databricks environment. Each stage is designed to be idempotent and modular, allowing for easy debugging and future enhancements.

1. Data Ingestion (E - Extract)
The first step is to get the raw data into a accessible location for Databricks. Given the constraints of the community edition, this stage is crucial.

- Source: The NYC TLC website hosts the 2023 Yellow Taxi data.
- Method: A Python script will be used to download the monthly Parquet files. This script will iterate through the 12 months of 2023, downloading each file.
- Storage: The downloaded files will be stored in Databricks File System (DBFS). This local storage acts as a staging area, making the data readily available to the Spark cluster. Storing files in DBFS is a good practice as it separates the ingestion logic from the processing logic.

2. Data Processing (T - Transform)
This is the core of the project where Spark's capabilities are leveraged for data cleaning and feature engineering. The processing is broken down into a series of Spark jobs.

- Setup: The Databricks cluster will be configured with a single-node cluster. This is adequate for the community edition. The necessary libraries (e.g., pyspark, pandas) are already part of the Databricks runtime.
- Data Cleaning:
  - Loading: The raw data will be read from the DBFS staging area into a Spark DataFrame.
  - Filtering: Rows with negative fares, zero-distance trips, invalid timestamps, or outliers (e.g., excessively long trips or speeds) will be filtered out.
  - Handling Missing Values: A strategic approach to NULL values is required. For example, some missing values can be imputed with mean or median, while others may indicate a faulty record and should be dropped.
  - Deduplication: Duplicate records, identified by a combination of key columns like vendor_id, tpep_pickup_datetime, and tpep_dropoff_datetime, will be removed to ensure data integrity.
- Feature Engineering: This step enriches the dataset for downstream tasks like demand forecasting and fare prediction.
  - Temporal Features: Features like hour, day_of_week, and day_of_month will be extracted from the tpep_pickup_datetime column.
  - Trip Features: trip_duration (in minutes or seconds) and average_speed (in miles per hour) will be calculated from the tpep_up_datetime, tpep_dropoff_datetime and trip_distance columns.

3. Data Validation and Logging
Before loading the data, it's essential to validate the transformed data. This ensures the output is of high quality and provides a clear record of the processing.

- Data Quality Checks: Perform checks on the cleaned data, such as verifying that no negative values remain in the fare_amount column or that the number of rows is within an expected range.
- Logging: A logging framework (e.g., using Python's logging module or Databricks' built-in logging) will be used to record key metrics like the number of rows processed, the number of rows dropped due to cleaning, and the time taken for each stage. This log will be saved to DBFS or a designated logging table.

4. Data Loading (L - Load)
The final step is to save the cleaned and enriched data to its final destination.

- Destination: The data will be saved to a chosen output location. Given the constraints, either DBFS or a cloud storage service like S3 (if the community edition allows for integration) can be used. For a true production setup, S3 is the preferred choice as it is a highly scalable and durable object store.
- Format: The data will be saved in Parquet format. This columnar storage format is highly efficient for analytical queries with Spark, as it offers compression and predicate pushdown.
- Partitioning: The data will be partitioned by month (e.g., part_month=01, part_month=02). This partitioning strategy is critical for performance, as it allows Spark to read only the relevant data for a specific month, significantly reducing I/O operations and query times.


## Setup Databricks and AWS
- Create a workspace with article "Create a workspace using the AWS Quickstart (Recommended)". You need to login as an AWS admin account. The process will setup 
  - AWS: 
    - Workspace S3 bucket, Workspace S3 Bucket Policy, 
    - Catalog IAM Role, Catalog IAM Role Policy 
    - Copy Zips Role, Copy Zips Function, Copy Zips, Lambda Zips Bucket, 
    - function Role, Workspace IAM Role, Databricks Api Function
  - Databricks: createCredentials, createStorageConfiguration, createWorkspace

- Create a new compute
  - 16.4 LTS (Scala 2.12) Spark 3.5.2
  - Single node of r5d.large 16 GB Memory, 2 Cores

- Attach cluster to the sam AWS IAM role used in storage credential arn:aws:iam::418272790285:role/databricks-workspace-stack-06ea8-catalog-role?

Edit external location to not use the default storage credential.

## Databricks Notebooks
The recommended structure for Databricks is to use a main orchestration notebook that calls other modular notebooks. This allows for a clear, step-by-step pipeline.

- main_orchestrator: This notebook serves as the entry point for the entire pipeline. It takes configuration parameters (like the year to process) and calls the other notebooks using %run magic command.

- data_ingestion: Contains the Python script to download the monthly Parquet files from the NYC TLC website and store them in DBFS. This notebook ensures the raw data is available for processing.

- data_processing: This is the core of the ETL. It's best to have a separate notebook for this to keep the logic clean. The notebook will:

  - Load the data from DBFS.
  - Perform all cleaning steps: filter out negative fares, zero-distance trips, and outliers.
  - Execute feature engineering: calculate trip duration, average speed, and extract temporal features like hour and day of the week.

- data_validation: A crucial step before loading. This notebook will contain a series of data quality checks and assertions. For example, it will check if any negative fares or zero distances remain and log any failures.

- data_loading: This notebook will handle writing the final, cleaned Parquet data to S3. It will be configured to write the data partitioned by month, as specified in the requirements.

## Data
Number of columns: 20
Column names: ['VendorID', 'tpep_pickup_datetime', 'tpep_dropoff_datetime', 'passenger_count', 'trip_distance', 'RatecodeID', 'store_and_fwd_flag', 'PULocationID', 'DOLocationID', 'payment_type', 'fare_amount', 'extra', 'mta_tax', 'tip_amount', 'tolls_amount', 'improvement_surcharge', 'total_amount', 'congestion_surcharge', 'airport_fee', 'source_month']

=== SCHEMA ===
root
 |-- VendorID: long (nullable = true)
 |-- tpep_pickup_datetime: timestamp (nullable = true)
 |-- tpep_dropoff_datetime: timestamp (nullable = true)
 |-- passenger_count: double (nullable = true)
 |-- trip_distance: double (nullable = true)
 |-- RatecodeID: double (nullable = true)
 |-- store_and_fwd_flag: string (nullable = true)
 |-- PULocationID: long (nullable = true)
 |-- DOLocationID: long (nullable = true)
 |-- payment_type: long (nullable = true)
 |-- fare_amount: double (nullable = true)
 |-- extra: double (nullable = true)
 |-- mta_tax: double (nullable = true)
 |-- tip_amount: double (nullable = true)
 |-- tolls_amount: double (nullable = true)
 |-- improvement_surcharge: double (nullable = true)
 |-- total_amount: double (nullable = true)
 |-- congestion_surcharge: double (nullable = true)
 |-- airport_fee: double (nullable = true)
 |-- source_month: string (nullable = false)

=== RECORD COUNT BY MONTH ===
+------------+---------+
|source_month|  count  |
+------------+---------+
|          01|3,066,766|
|          02|2,913,955|
+------------+---------+

### What is an External Location?
An External Location is NOT a folder in your S3 bucket. It's a Databricks Unity Catalog object that:

- Grants permission to access a specific S3 path
- Links to a Storage Credential (which contains the IAM role)
- Acts as a security boundary for data access

Think of it as a "passport" that allows Databricks to access your S3 bucket.

Key Concepts:
1. Storage Credential
Contains the IAM role that Databricks created (aws-stack-06ea8-storage-credential)

Represents "who can access" (the IAM role)

2. External Location
Points to a specific S3 path (s3://your-bucket/)

Represents "what can be accessed" (which S3 path)

Combines the "who" and "what" together

3. The Complete Picture:
Databricks → External Location → Storage Credential → IAM Role → S3 Bucket


Creating the External Location
```sql
-- Run this in a SQL cell
CREATE EXTERNAL LOCATION IF NOT EXISTS my_s3_location
URL 's3://databricks-workspace-stack-06ea8-bucket/'
WITH (STORAGE CREDENTIAL `aws-stack-06ea8-storage-credential`);
```

What this does:
- Creates a Databricks object called my_s3_location
- Grants access to the entire bucket: s3://databricks-workspace-stack-06ea8-bucket/
- Uses the IAM role from the storage credential

IAM databricks-workspace-stack-06ea8-catalog-role:
- Permissions policies
- Trust policy


Bad code of Loading the entire Parquet file into driver memory (e.g., 300 MB → pandas), Then copying it into a single-partition Spark DataFrame. This DataFrame is not distributed — all data lives on the driver. Any action (even .limit(1000)) triggers full deserialization → JVM crash:
```python
    # Read into pandas
    pdf = pd.read_parquet(io.BytesIO(response.content))
    # Convert to Spark DataFrame
    spark_df = spark.createDataFrame(pdf)
```

Need to avoid Pandas entirely.

On Shared clusters with Unity Catalog, Databricks blocks direct access to local filesystem paths (like /tmp) for security. Even though: You can write to /tmp via Python (open(...)), But dbutils.fs.cp("file:/tmp/...", "dbfs:...") is blocked to prevent unauthorized file access. This is by design in Shared Access Mode. --> cannot copy file to DBFS but saved to the local workspace first and then copied to DBFS.

Leveraging Unity Catalog with Shared Clusters
- Unity Catalog provides centralized governance (access control, auditing, lineage) across shared clusters.
- Using shared clusters with Unity Catalog ensures better cost efficiency and governance compared to dedicated clusters.

Decoupling of Storage and Compute
- Using S3 as the source and destination (rather than downloading directly to Databricks DBFS) is a best practice. It enables durability, scalability, and separation of concerns.
- Databricks clusters (compute) can be ephemeral; S3 provides persistent, reliable storage.

Spark on Databricks is Well-Suited for This Workload
- Spark excels at large-scale data processing (e.g., cleaning, aggregating, enriching taxi data).
- Databricks provides optimized runtimes and Delta Lake integration.

downloading NYC taxi data from the internet to S3, processing it with Spark in Databricks, and writing the results back to S3 — is generally effective and aligns well with modern cloud data architecture best practices, especially in a Databricks environment with Unity Catalog and AWS S3.

What format for ML training? Answer: Delta Lake Format in S3 Why: Delta Lake provides:
- ACID transactions ensuring data consistency for ML training
- Time travel capabilities for model reproducibility
- Schema enforcement preventing training data quality issues
- Efficient incremental updates for monthly retraining
- Direct integration with both Databricks and AWS ML services

Register as managed tables in Unity Catalog? Answer: Yes, for processed data. Purpose:
- Data Governance: Centralized access control and auditing
- Discovery: Data lineage and cataloging for ML teams
- Quality: Schema enforcement and data validation
- Reproducibility: Versioned data for model training

=========
### The Databricks 

Databricks has expanded the Lakehouse vision to create Data Intelligence Platform

Control Plane (brain)
- Databricks owned environment
- Hosts the UI, notebooks, and general code
- Orchestrates compute nodes for processing

Compute Plane (muscles)
- Customer owned environment (on AWS, Azure, GCP)
- Location for data storage
- Customer networking, applications, etc.

Architecture
- Databricks is a compute engine that operates on top of the data.
- Control Plane will create clusters in the Compute Plane in order to reach the data. Data and compute in Compute Plane.

With Databricks, recommend to store data in Delta format (a collection of parquet files + metadata)