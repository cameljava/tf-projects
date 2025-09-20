provider "aws" {
  region = "ap-southeast-2"
  default_tags {
    tags = {
      ManagedBy   = "Terraform"
      Environment = "dev"
      Owner       = "team-k"
    }
  }
}

# --------------------------
# VPC & Subnet
# --------------------------
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "main" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-southeast-2a"
}

# --------------------------
# Internet Gateway
# --------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "Main-IGW" }
}

# --------------------------
# Route Table
# --------------------------
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "Main-RouteTable" }
}

resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

# --------------------------
# Security Group (SSH)
# --------------------------
resource "aws_security_group" "app_sg" {
  name        = "eni-failover-sg"
  description = "Allow SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # restrict in production
  }
}

# --------------------------
# EC2 Instances
# --------------------------
resource "aws_instance" "primary" {
  ami                    = "ami-0059ed5a3aacdfe15"
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  key_name               = "k" # existing key

  tags = { Name = "Primary-EC2" }
}

resource "aws_instance" "standby" {
  ami                    = "ami-0059ed5a3aacdfe15"
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  key_name               = "k"

  tags = { Name = "Standby-EC2" }
}

# --------------------------
# Floating ENI
# --------------------------
resource "aws_network_interface" "failover_eni" {
  subnet_id       = aws_subnet.main.id
  private_ips     = ["10.0.1.100"]
  security_groups = [aws_security_group.app_sg.id]

  tags = { Name = "Failover-ENI" }
}

resource "aws_network_interface_attachment" "eni_primary" {
  instance_id          = aws_instance.primary.id
  network_interface_id = aws_network_interface.failover_eni.id
  device_index         = 1
}

# --------------------------
# Elastic IP
# --------------------------
resource "aws_eip" "failover_eip" {
  tags = { Name = "Failover-EIP" }
}

resource "aws_eip_association" "failover_eip_assoc" {
  allocation_id        = aws_eip.failover_eip.id
  network_interface_id = aws_network_interface.failover_eni.id
  private_ip_address   = "10.0.1.100"
}

# --------------------------
# IAM Role for Lambda
# --------------------------
resource "aws_iam_role" "lambda_role" {
  name = "eni-failover-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = { Service = "lambda.amazonaws.com" },
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "eni-failover-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:DescribeNetworkInterfaces",
          "ec2:DetachNetworkInterface",
          "ec2:AttachNetworkInterface",
          "ec2:DescribeInstances"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      }
    ]
  })
}

# --------------------------
# Lambda Function Validation
# --------------------------
resource "null_resource" "lambda_zip_validation" {
  provisioner "local-exec" {
    command = "if [ ! -f 'lambda_failover.zip' ]; then echo 'ERROR: lambda_failover.zip file not found. Please create the Lambda deployment package first.'; exit 1; fi"
  }
}

# --------------------------
# Lambda Function
# --------------------------
resource "aws_lambda_function" "eni_failover" {
  filename         = "lambda_failover.zip" # packaged Python function
  function_name    = "eni_failover"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = filebase64sha256("lambda_failover.zip")

  # Validation to ensure the zip file exists
  depends_on = [null_resource.lambda_zip_validation]

  environment {
    variables = {
      ENI_ID       = aws_network_interface.failover_eni.id
      PRIMARY_ID   = aws_instance.primary.id
      STANDBY_ID   = aws_instance.standby.id
      DEVICE_INDEX = "1"
    }
  }
}

# --------------------------
# SNS Topic
# --------------------------
resource "aws_sns_topic" "failover_topic" {
  name = "eni-failover-topic"
}

# Lambda subscription to SNS
resource "aws_sns_topic_subscription" "lambda_sub" {
  topic_arn = aws_sns_topic.failover_topic.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.eni_failover.arn
}

# Give SNS permission to invoke Lambda
resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.eni_failover.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.failover_topic.arn
}

# --------------------------
# CloudWatch Alarm
# --------------------------
/*
resource "aws_cloudwatch_metric_alarm" "primary_health" {
  alarm_name          = "PrimaryEC2_Failure"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "StatusCheckFailed_Instance"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  alarm_actions       = [aws_sns_topic.failover_topic.arn]

  dimensions = {
    InstanceId = aws_instance.primary.id
  }
}
*/
resource "aws_cloudwatch_metric_alarm" "primary_health" {
  alarm_name          = "PrimaryEC2_Failure"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "InstanceFailure"
  namespace           = "Custom/Test"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  alarm_actions       = [aws_sns_topic.failover_topic.arn]

  dimensions = {
    InstanceId = aws_instance.primary.id
  }

  treat_missing_data = "notBreaching"
}
# --------------------------
# Outputs
# --------------------------

# VPC Outputs
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

# Subnet Outputs
output "subnet_id" {
  description = "ID of the subnet"
  value       = aws_subnet.main.id
}

output "subnet_cidr_block" {
  description = "CIDR block of the subnet"
  value       = aws_subnet.main.cidr_block
}

output "subnet_availability_zone" {
  description = "Availability zone of the subnet"
  value       = aws_subnet.main.availability_zone
}

# Internet Gateway Outputs
output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}

# Route Table Outputs
output "route_table_id" {
  description = "ID of the main route table"
  value       = aws_route_table.main.id
}

# EC2 Instance Outputs
output "primary_instance_id" {
  description = "ID of the primary EC2 instance"
  value       = aws_instance.primary.id
}

output "primary_instance_private_ip" {
  description = "Private IP address of the primary EC2 instance"
  value       = aws_instance.primary.private_ip
}

output "primary_instance_public_ip" {
  description = "Public IP address of the primary EC2 instance"
  value       = aws_instance.primary.public_ip
}

output "standby_instance_id" {
  description = "ID of the standby EC2 instance"
  value       = aws_instance.standby.id
}

output "standby_instance_private_ip" {
  description = "Private IP address of the standby EC2 instance"
  value       = aws_instance.standby.private_ip
}

output "standby_instance_public_ip" {
  description = "Public IP address of the standby EC2 instance"
  value       = aws_instance.standby.public_ip
}

# ENI Outputs
output "failover_eni_id" {
  description = "ID of the failover ENI"
  value       = aws_network_interface.failover_eni.id
}

output "failover_eni_private_ip" {
  description = "Private IP address of the failover ENI"
  value       = aws_network_interface.failover_eni.private_ip
}

output "failover_eni_attachment_id" {
  description = "ID of the ENI attachment to primary instance"
  value       = aws_network_interface_attachment.eni_primary.id
}

# Elastic IP Outputs
output "failover_eip_id" {
  description = "ID of the failover Elastic IP"
  value       = aws_eip.failover_eip.id
}

output "failover_eip_public_ip" {
  description = "Public IP address of the failover Elastic IP"
  value       = aws_eip.failover_eip.public_ip
}

output "failover_eip_association_id" {
  description = "ID of the EIP association"
  value       = aws_eip_association.failover_eip_assoc.id
}

# Security Group Outputs
output "security_group_id" {
  description = "ID of the application security group"
  value       = aws_security_group.app_sg.id
}

# Lambda Function Outputs
output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.eni_failover.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.eni_failover.arn
}

output "lambda_zip_validation_status" {
  description = "Status of Lambda zip file validation"
  value       = "Lambda zip file validation completed successfully"
  depends_on  = [null_resource.lambda_zip_validation]
}

# SNS Topic Outputs
output "sns_topic_arn" {
  description = "ARN of the SNS topic for failover notifications"
  value       = aws_sns_topic.failover_topic.arn
}

# CloudWatch Alarm Outputs
output "cloudwatch_alarm_name" {
  description = "Name of the CloudWatch alarm for primary instance health"
  value       = aws_cloudwatch_metric_alarm.primary_health.alarm_name
}

output "cloudwatch_alarm_arn" {
  description = "ARN of the CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.primary_health.arn
}

# Application Access Information
output "application_access_info" {
  description = "Information for accessing the application"
  value = {
    primary_instance_ssh = "ssh -i k.pem ec2-user@${aws_instance.primary.public_ip}"
    standby_instance_ssh = "ssh -i k.pem ec2-user@${aws_instance.standby.public_ip}"
    failover_eip_ssh     = "ssh -i k.pem ec2-user@${aws_eip.failover_eip.public_ip}"
    failover_eip_http    = "http://${aws_eip.failover_eip.public_ip}"
    failover_eip_https   = "https://${aws_eip.failover_eip.public_ip}"
  }
}