
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

<img width="765" height="485" alt="Image" src="https://miro.medium.com/v2/resize:fit:4800/format:webp/1*LS47r0E_KsyiueBCIiajRg.gif" />

