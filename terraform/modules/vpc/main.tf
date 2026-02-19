locals {
  public_subnet_az_map  = zipmap(var.public_subnet_cidrs, var.azs)
  private_subnet_az_map = zipmap(var.private_subnet_cidrs, var.azs)
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnet_az_map

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.key
  availability_zone       = each.value
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name}-public-${each.value}"
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnet_az_map

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.key
  availability_zone = each.value

  tags = {
    Name = "${var.name}-private-${each.value}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
