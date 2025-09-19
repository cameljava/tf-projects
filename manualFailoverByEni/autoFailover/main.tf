provider "aws" {
  region = "ap-southeast-2"
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
# Security Group (SSH)
# --------------------------
resource "aws_security_group" "app_sg" {
  name        = "eni-failover-sg"
  description = "Allow SSH and HTTP"
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
  ami             = "ami-0059ed5a3aacdfe15"
  instance_type   = "t2.micro"
  subnet_id       = aws_subnet.main.id
  security_groups = [aws_security_group.app_sg.id]
  key_name        = "k" # existing key

  tags = { Name = "Primary-EC2" }
}

resource "aws_instance" "standby" {
  ami             = "ami-0059ed5a3aacdfe15"
  instance_type   = "t2.micro"
  subnet_id       = aws_subnet.main.id
  security_groups = [aws_security_group.app_sg.id]
  key_name        = "k"

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
        Principal = { Service = "lambda.amazonaws.com" }
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
# Lambda Function
# --------------------------
resource "aws_lambda_function" "eni_failover" {
  filename         = "lambda_failover.zip" # packaged Python function
  function_name    = "eni_failover"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = filebase64sha256("lambda_failover.zip")

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