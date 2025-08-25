#!/bin/bash
echo "Installing dependencies..."
pip install -r lambda/requirements.txt -t lambda/  # Once-off, do not need to run again

# Terraform will package/zip the lambda/ directory into a zip file

cd terraform
echo "Deploying with Terraform..."
terraform init
terraform plan
terraform apply -auto-approve