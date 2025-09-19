provider "aws" {
  region = "ap-southeast-2" # adjust for your region
  default_tags {
    tags = {
      ManagedBy   = "Terraform"
      Environment = "dev"
      Owner       = "team-k"
    }
  }
}

# --- VPC ---
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}
resource "aws_subnet" "main" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-southeast-2a"
}

# --- Security Group (allow SSH) ---
resource "aws_security_group" "app_sg" {
  name        = "eni-failover-sg"
  description = "Allow SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 🔴 For production, restrict to your IP
  }

}

# --- Primary EC2 ---
resource "aws_instance" "primary" {
  ami                    = "ami-0059ed5a3aacdfe15"
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  # I have already had a key pair in AWS, use it here for quick test.
  key_name = "k"

  tags = {
    Name = "Primary-EC2"
  }
}

# --- Standby EC2 ---
resource "aws_instance" "standby" {
  ami                    = "ami-0059ed5a3aacdfe15"
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  key_name               = "k"

  tags = {
    Name = "Standby-EC2"
  }
}

# --- Secondary ENI (floating IP identity) ---
resource "aws_network_interface" "failover_eni" {
  subnet_id       = aws_subnet.main.id
  private_ips     = ["10.0.1.100"] # fixed IP inside subnet
  security_groups = [aws_security_group.app_sg.id]

  tags = {
    Name = "Failover-ENI"
  }
}

# --- Attach ENI to Primary EC2 initially ---
resource "aws_network_interface_attachment" "eni_primary" {
  instance_id          = aws_instance.primary.id
  network_interface_id = aws_network_interface.failover_eni.id
  device_index         = 1

  depends_on = [
    aws_instance.primary,
    aws_network_interface.failover_eni
  ]
}

# --- Elastic IP ---
resource "aws_eip" "failover_eip" {
  tags = {
    Name = "Failover-EIP"
  }
}

# --- Associate Elastic IP with ENI ---
resource "aws_eip_association" "failover_eip_assoc" {
  allocation_id        = aws_eip.failover_eip.id
  network_interface_id = aws_network_interface.failover_eni.id
  private_ip_address   = "10.0.1.100"

  depends_on = [
    aws_eip.failover_eip,
    aws_network_interface.failover_eni,
    aws_network_interface_attachment.eni_primary
  ]
}
