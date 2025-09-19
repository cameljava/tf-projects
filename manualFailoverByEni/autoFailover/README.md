## automatic ENI failover

- VPC + Subnet + Security Group
- Primary and Standby EC2 instances
- Floating ENI with fixed private IP + Elastic IP
- CloudWatch alarm monitoring primary instance health
- SNS topic to trigger Lambda
- Lambda function to move ENI to standby
- IAM role and policy for Lambda