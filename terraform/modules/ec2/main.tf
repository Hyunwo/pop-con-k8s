data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "T1 EC2 Security Group"
  vpc_id      = var.vpc_id


  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-sg"
  }
}

resource "aws_instance" "this" {
  ami = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  subnet_id = var.subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile = aws_iam_instance_profile.this.name
  associate_public_ip_address = true
  key_name = var.key_name

  user_data = <<-EOT
    #!/bin/bash
    dnf update -y

    # Docker 설치
    dnf install -y docker
    systemctl start docker
    systemctl enable docker

    # ec2-user docker 권한 추가
    usermod -aG docker ec2-user

    # Docker Compose v2
    mkdir -p /usr/libexec/docker/cli-plugins
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
      -o /usr/libexec/docker/cli-plugins/docker-compose
    chmod +x /usr/libexec/docker/cli-plugins/docker-compose
  EOT


  tags = {
    Name = var.name
  }
}
