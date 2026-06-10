#########################################
# IAM Role for EventBridge Scheduler
#########################################
resource "aws_iam_role" "scheduler_role" {
  name = "auto-stop-scheduler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_policy" {
  name = "auto-stop-policy"
  role = aws_iam_role.scheduler_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["rds:StopDBInstance", "rds:StartDBInstance"]
        Resource = [var.db_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:StopInstances", "ec2:StartInstances"]
        Resource = [var.instance_arn]
      }
    ]
  })
}

#########################################
# Schedules to Stop Resources Daily
#########################################
resource "aws_scheduler_schedule" "stop_rds" {
  name       = "stop-bse-rds-nightly"
  group_name = "default"
  flexible_time_window { mode = "OFF" }
  schedule_expression = "cron(0 22 * * ? *)" # Runs at 10:00 PM IST daily
  schedule_expression_timezone = "Asia/Kolkata"
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance"
    role_arn = aws_iam_role.scheduler_role.arn
    input    = jsonencode({ DbInstanceIdentifier = var.rds_db_name })
  }
}

resource "aws_scheduler_schedule" "stop_ec2" {
  name       = "stop-bse-bastion-nightly"
  group_name = "default"
  flexible_time_window { mode = "OFF" }
  schedule_expression = "cron(0 22 * * ? *)" # Runs at 10:00 PM IST daily
  schedule_expression_timezone = "Asia/Kolkata"
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler_role.arn
    input    = jsonencode({ InstanceIds = [var.instance_id] })
  }
}

#########################################
# Schedules to Start Resources Daily
#########################################
resource "aws_scheduler_schedule" "start_rds" {
  name       = "start-bse-rds-morning"
  group_name = "default"
  flexible_time_window { mode = "OFF" }
  schedule_expression = "cron(0 10 * * ? *)" # Runs at 10:00 AM IST daily
  schedule_expression_timezone = "Asia/Kolkata"
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:rds:startDBInstance"
    role_arn = aws_iam_role.scheduler_role.arn
    input    = jsonencode({ DbInstanceIdentifier = var.rds_db_name })
  }
}

resource "aws_scheduler_schedule" "start_ec2" {
  name       = "start-bse-bastion-morning"
  group_name = "default"
  flexible_time_window { mode = "OFF" }
  schedule_expression = "cron(0 10 * * ? *)" # Runs at 10:00 AM IST daily
  schedule_expression_timezone = "Asia/Kolkata"
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler_role.arn
    input    = jsonencode({ InstanceIds = [var.instance_id] })
  }
}