#########################################
# Security Group for Aurora DB
#########################################
resource "aws_security_group" "aurora" {
  name   = "postgres-sg"
  vpc_id = aws_vpc.main.id

  # Prevents dependency deadlocks by removing rules before deletion
  revoke_rules_on_delete = true
}

# Allow access to PostgreSQL from within the VPC (for future backend APIs)
resource "aws_security_group_rule" "postgres_from_vpc" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"

  cidr_blocks = [
    "10.0.0.0/16"
  ]

  security_group_id = aws_security_group.aurora.id
}

# Allow access to PostgreSQL specifically from the Bastion host
resource "aws_security_group_rule" "postgres_from_bastion" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion_sg.id
  security_group_id        = aws_security_group.aurora.id
}

# Allow all outbound traffic from Aurora
resource "aws_security_group_rule" "egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"

  cidr_blocks = [
    "0.0.0.0/0"
  ]

  security_group_id = aws_security_group.aurora.id
}

#########################################
# Security Group for Bastion Host
#########################################
resource "aws_security_group" "bastion_sg" {
  name   = "bastion-sg"
  vpc_id = aws_vpc.main.id

  # Prevents dependency deadlocks by removing rules before deletion
  revoke_rules_on_delete = true
}

# SSH from specific whitelisted IPs
resource "aws_security_group_rule" "ssh_in" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  # The /16 subnet mask acts as a wildcard, allowing any IP starting with 223.190.x.x
  cidr_blocks       = ["223.190.0.0/16"]
  security_group_id = aws_security_group.bastion_sg.id
}

# Allow Bastion to connect everywhere (to reach SSM, internet, and the DB)
resource "aws_security_group_rule" "bastion_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.bastion_sg.id
}