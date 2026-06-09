#########################################
# Security Group for VPC Endpoints
#########################################
resource "aws_security_group" "vpc_endpoints_sg" {
  name   = "ssm-vpc-endpoints-sg"
  vpc_id = aws_vpc.main.id

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
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private1.id, aws_subnet.private2.id]
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private1.id, aws_subnet.private2.id]
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private1.id, aws_subnet.private2.id]
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  private_dns_enabled = true
}