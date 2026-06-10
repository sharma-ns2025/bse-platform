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
  
  user_data = <<-EOF
    #!/bin/bash
    # Update system
    sudo yum update -y

    # Install Java (required for Flyway)
    sudo yum install -y java-17-amazon-corretto

    # Download and install Flyway
    wget -qO- https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/10.0.0/flyway-commandline-10.0.0-linux-x64.tar.gz | tar xvz
    sudo mv flyway-*/ /opt/flyway
    sudo ln -s /opt/flyway/flyway /usr/local/bin/flyway

    # Create directory for migration scripts
    mkdir -p /opt/flyway/sql
  EOF
}

#########################################
# IAM Instance Profile for EC2
#########################################
resource "aws_iam_instance_profile" "bastion_profile" {
  name = "bastion-profile"
  role = aws_iam_role.bastion_ssm_role.name
}