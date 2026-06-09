#########################################
# Standard RDS PostgreSQL (Low Cost)
#########################################
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group"
  # Requires at least two private subnets in different AZs
  subnet_ids = [aws_subnet.private1.id, aws_subnet.private2.id]
}

resource "aws_db_instance" "postgres" {
  identifier             = "bse-postgres"
  engine                 = "postgres"
  # engine_version         = "15.4"
  
  # Lowest cost instance type (~$12-14/month)
  instance_class         = "db.t4g.micro" 
  allocated_storage      = 20
  max_allocated_storage  = 100 # Enables auto-scaling for storage space if needed

  db_name                = "postgres"
  username               = "postgres"  
  # password                = "B5e_2026$d8"
  manage_master_user_password = true # Auto-generates and secures password via Secrets Manager

  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  publicly_accessible    = false
  skip_final_snapshot    = true  # Note: Change to false when going to real production
  multi_az               = false # Keeps costs down
}