resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "private1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "eu-central-1a"
}

resource "aws_subnet" "private2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-central-1b"
}

resource "aws_route_table" "private1" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "private2" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table_association" "private1" {
  subnet_id      = aws_subnet.private1.id
  route_table_id = aws_route_table.private1.id
}

resource "aws_route_table_association" "private2" {
  subnet_id      = aws_subnet.private2.id
  route_table_id = aws_route_table.private2.id
}

#########################################
# INTERNET GATEWAY (REQUIRED FOR ALB)
#########################################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

#########################################
# PUBLIC SUBNETS (NEW - REQUIRED FOR ALB)
#########################################
resource "aws_subnet" "public1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.101.0/24"
  availability_zone       = "eu-central-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.102.0/24"
  availability_zone       = "eu-central-1b"
  map_public_ip_on_launch = true
}

#########################################
# PUBLIC ROUTE TABLE
#########################################
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public1" {
  subnet_id      = aws_subnet.public1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public2" {
  subnet_id      = aws_subnet.public2.id
  route_table_id = aws_route_table.public.id
}