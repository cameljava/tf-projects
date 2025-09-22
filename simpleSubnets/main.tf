terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# ---------- Variables ----------
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}

# ---------- Locals ----------
locals {
  common_tags = {
    ManagedBy   = "Terraform"
    Environment = var.environment
    Owner       = "team-k"
  }

  name_prefix = "${var.environment}-demo"
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

# ---------- Data Sources ----------
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------- VPC ----------
resource "aws_vpc" "demo_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${local.name_prefix}-vpc" }
}

# ---------- Internet Gateway ----------
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.demo_vpc.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

# ---------- Elastic IP for NAT ----------
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

# ---------- NAT Gateway ----------
resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_1.id
  tags          = { Name = "${local.name_prefix}-nat-gw" }
}

# ---------- Route Tables ----------
# Main route table (for public subnets)
resource "aws_route_table" "main_custom" {
  vpc_id = aws_vpc.demo_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "${local.name_prefix}-main-rt" }
}

# Add these missing associations:
resource "aws_route_table_association" "public_1_assoc" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.main_custom.id
}

resource "aws_route_table_association" "public_2_assoc" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.main_custom.id
}

# Private subnets route table (routes via NAT)
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.demo_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }

  tags = { Name = "${local.name_prefix}-private-rt" }
}

# ---------- Main route table association ----------
resource "aws_main_route_table_association" "main_assoc" {
  vpc_id         = aws_vpc.demo_vpc.id
  route_table_id = aws_route_table.main_custom.id
}

# ---------- Subnets ----------
# Public subnets
resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.demo_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name_prefix}-public-1" }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.demo_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name_prefix}-public-2" }
}

# Private subnets
resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.demo_vpc.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${local.name_prefix}-private-1" }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.demo_vpc.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
  tags              = { Name = "${local.name_prefix}-private-2" }
}

# ---------- Route table associations ----------
# Private subnets → private RT
resource "aws_route_table_association" "private_1_assoc" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_2_assoc" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private_rt.id
}

# ---------- Security Groups ----------
# Public SG: allow SSH & HTTP
resource "aws_security_group" "public_sg" {
  # Use name_prefix instead of a static name
  name_prefix = "public-sg-"
  description = "Allow SSH and HTTP"
  vpc_id      = aws_vpc.demo_vpc.id
  lifecycle {
    create_before_destroy = true
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Private SG: allow traffic from public subnet
resource "aws_security_group" "private_sg" {
  # Use name_prefix instead of a static name
  name_prefix = "private-sg-"
  description = "Private subnet with access from public subnet"
  vpc_id      = aws_vpc.demo_vpc.id

  lifecycle {
    create_before_destroy = true
  }

  # Allow SSH from public subnet
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24", "10.0.2.0/24"] # Public subnet CIDRs
  }

  # Allow HTTP from public subnet
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24", "10.0.2.0/24"] # Public subnet CIDRs
  }

  # Allow HTTPS from public subnet
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24", "10.0.2.0/24"] # Public subnet CIDRs
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- Network ACLs ----------
# Example: public subnet NACL
resource "aws_network_acl" "public_nacl" {
  vpc_id = aws_vpc.demo_vpc.id
  tags   = { Name = "public-nacl" }

  # Allow ephemeral ports (for return traffic)
  ingress {
    protocol   = "tcp"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Allow HTTP
  ingress {
    protocol   = "tcp"
    rule_no    = 200
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  # Allow HTTPS
  ingress {
    protocol   = "tcp"
    rule_no    = 300
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # Allow SSH
  ingress {
    protocol   = "tcp"
    rule_no    = 400
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 22
    to_port    = 22
  }

  # Allow all outbound traffic
  egress {
    protocol   = "-1"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
}

# Associate NACL with public subnets
resource "aws_network_acl_association" "public_1_nacl_assoc" {
  subnet_id      = aws_subnet.public_1.id
  network_acl_id = aws_network_acl.public_nacl.id
}

resource "aws_network_acl_association" "public_2_nacl_assoc" {
  subnet_id      = aws_subnet.public_2.id
  network_acl_id = aws_network_acl.public_nacl.id
}

# You only have public NACL - consider adding:
resource "aws_network_acl" "private_nacl" {
  vpc_id = aws_vpc.demo_vpc.id
  tags   = { Name = "private-nacl" }

  # Allow all traffic within VPC
  ingress {
    protocol   = "-1"
    rule_no    = 100
    action     = "allow"
    cidr_block = "10.0.0.0/16"
    from_port  = 0
    to_port    = 0
  }

  egress {
    protocol   = "-1"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
}

# Add these missing private subnet NACL associations:
resource "aws_network_acl_association" "private_1_nacl_assoc" {
  subnet_id      = aws_subnet.private_1.id
  network_acl_id = aws_network_acl.private_nacl.id
}

resource "aws_network_acl_association" "private_2_nacl_assoc" {
  subnet_id      = aws_subnet.private_2.id
  network_acl_id = aws_network_acl.private_nacl.id
}



# ---------- EC2 Instances ----------
# Public instance in public subnet
resource "aws_instance" "public_ec2" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.public_1.id
  vpc_security_group_ids      = [aws_security_group.public_sg.id]
  associate_public_ip_address = true
  key_name                    = "aws-test-keys"
  tags                        = { Name = "${local.name_prefix}-public-ec2" }
}

# Private instance in private subnet
resource "aws_instance" "private_ec2" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.private_1.id
  vpc_security_group_ids      = [aws_security_group.private_sg.id]
  associate_public_ip_address = false
  key_name                    = "aws-test-keys"
  tags                        = { Name = "${local.name_prefix}-private-ec2" }
}

# ---------- Outputs ----------
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.demo_vpc.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.demo_vpc.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = [aws_subnet.public_1.id, aws_subnet.public_2.id]
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = [aws_subnet.private_1.id, aws_subnet.private_2.id]
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.igw.id
}

output "nat_gateway_id" {
  description = "ID of the NAT Gateway"
  value       = aws_nat_gateway.nat_gw.id
}

output "public_instance_id" {
  description = "ID of the public EC2 instance"
  value       = aws_instance.public_ec2.id
}

output "private_instance_id" {
  description = "ID of the private EC2 instance"
  value       = aws_instance.private_ec2.id
}

output "public_instance_public_ip" {
  description = "Public IP of the public EC2 instance"
  value       = aws_instance.public_ec2.public_ip
}

output "public_security_group_id" {
  description = "ID of the public security group"
  value       = aws_security_group.public_sg.id
}

output "private_security_group_id" {
  description = "ID of the private security group"
  value       = aws_security_group.private_sg.id
}
