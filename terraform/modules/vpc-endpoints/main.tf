#########################################
# Security Group for VPC Endpoints
#########################################
resource "aws_security_group" "vpc_endpoints_sg" {
  name   = "ssm-vpc-endpoints-sg"
  vpc_id = var.vpc_id

  # Prevents dependency deadlocks by removing rules before deletion
  revoke_rules_on_delete = true

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    # Allow HTTPS traffic from anywhere within the VPC
    cidr_blocks = ["10.0.0.0/16"] 
  }
}

data "aws_region" "current" {}

#########################################
# VPC Endpoints for Systems Manager (SSM)
#########################################
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids = var.subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids = var.subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids = var.subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = var.private_route_table_ids
  
  lifecycle {
    ignore_changes = [route_table_ids]
  }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"

  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]

  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ecr.api"
  vpc_endpoint_type   = "Interface"

  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]

  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"

  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]

  private_dns_enabled = true
}
