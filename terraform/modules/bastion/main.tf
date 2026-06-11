#########################################
# IAM Role for Bastion SSM
#########################################
resource "aws_iam_role" "bastion_ssm_role" {
  name = "bastion-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm_attach" {
  role       = aws_iam_role.bastion_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

#########################################
# Bastion EC2 in private subnet
#########################################
resource "aws_instance" "bastion_ssm" {
  ami                    = "ami-0faab6bdbac9486fb"  # Amazon Linux 2023 eu-central-1
  instance_type          = "t3.nano"
  subnet_id              = var.subnet_id
  associate_public_ip_address = false

  iam_instance_profile = aws_iam_instance_profile.bastion_profile.name

  vpc_security_group_ids = [
    var.bastion_sg_id
  ]

  tags = {
    Name = "bastion-private-ssm"
  }
}

#########################################
# IAM Instance Profile for EC2
#########################################
resource "aws_iam_instance_profile" "bastion_profile" {
  name = "bastion-profile"
  role = aws_iam_role.bastion_ssm_role.name
}

#########################################
# For accessing secrets
#########################################
resource "aws_iam_role_policy" "secrets_access" {
  name = "bastion-secrets-access"
  role = aws_iam_role.bastion_ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        # For production, restrict this to your secret ARN
        Resource = "*"
      }
    ]
  })
}