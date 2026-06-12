module "vpc" {
  source = "../../modules/vpc"
}

module "security_groups" {
  source = "../../modules/security-groups"

  vpc_id = module.vpc.vpc_id
}

module "vpc_endpoints" {
  source = "../../modules/vpc-endpoints"

  vpc_id = module.vpc.vpc_id
  subnet_ids = [
    module.vpc.private_subnet1_id,
    module.vpc.private_subnet2_id
  ]
  security_group_id = module.security_groups.bastion_sg_id

  private_route_table_ids = [
  module.vpc.private_route_table1_id,
  module.vpc.private_route_table2_id
]

  ecs_security_group_id = module.security_groups.ecs_sg_id
}

module "bastion" {
  source = "../../modules/bastion"

  subnet_id     = module.vpc.private_subnet1_id
  bastion_sg_id = module.security_groups.bastion_sg_id
}

module "rds" {
  source = "../../modules/rds-postgres"

  subnet_ids = [
    module.vpc.private_subnet1_id,
    module.vpc.private_subnet2_id
  ]

  postgres_sg_id = module.security_groups.postgres_sg_id
}

module "scheduler" {
  source = "../../modules/scheduler"

  db_identifier = module.rds.db_identifier
  db_arn        = module.rds.db_arn
  rds_db_name = module.rds.db_name
  instance_id  = module.bastion.instance_id
  instance_arn = module.bastion.instance_arn
}

moved {
  from = module.rds-postgres
  to   = module.rds
}

module "redis" {
  source = "../../modules/redis"

  subnet_ids         = [
    module.vpc.private_subnet1_id,
    module.vpc.private_subnet2_id
  ]

  security_group_ids = [module.security_groups.bastion_sg_id]
  availability_zone  = "eu-central-1a"  # region specified
}

module "app_secrets" {
  source = "../../modules/secrets-manager"

  secret_name   = "app-credentials"
  secret_values = {
    db_username = "postgres"
    db_password = "CHANGE_ME"   # Replace with real secret or managed dynamically
    redis_host = module.redis.redis_endpoint
    redis_port = tostring(module.redis.redis_port)
  }
}

module "ecs_cluster" {
  source = "../../modules/ecs-cluster"
  cluster_name = "dev-cluster"
}

module "alb" {
  source = "../../modules/alb"
  alb_name    = "dev-alb"
  target_port = 8080
  vpc_id      = module.vpc.vpc_id
  subnet_ids = [
    module.vpc.public_subnet1_id,
    module.vpc.public_subnet2_id
  ]
  security_group_id = module.security_groups.alb_sg_id
}

module "ecr_admin" {
  source    = "../../modules/ecr"
  repo_name = "admin-service"
}

module "ecr_auth" {
  source    = "../../modules/ecr"
  repo_name = "auth-service"
}

module "ecr_user" {
  source    = "../../modules/ecr"
  repo_name = "user-service"
}

module "ecr_wallet" {
  source    = "../../modules/ecr"
  repo_name = "wallet-service"
}

module "ecr_trading" {
  source    = "../../modules/ecr"
  repo_name = "trading-engine"
}

module "ecr_notification" {
  source    = "../../modules/ecr"
  repo_name = "notification-service"
}

# ECS Services with Auto Scaling
locals {
  ecs_services = [
    { name = "admin-service", cpu = 256, memory = 512, ecr_module = "ecr_admin" },
    { name = "auth-service", cpu = 256, memory = 512, ecr_module = "ecr_auth" },
    { name = "user-service", cpu = 256, memory = 512, ecr_module = "ecr_user" },
    { name = "wallet-service", cpu = 256, memory = 512, ecr_module = "ecr_wallet" },
    { name = "trading-engine", cpu = 256, memory = 512, ecr_module = "ecr_trading" },
    { name = "notification-service", cpu = 256, memory = 512, ecr_module = "ecr_notification" }
  ]
}

module "ecs_services" {
  source = "../../modules/ecs-service"

  for_each = {
    "admin-service"        = { cpu = 256, memory = 512 }
    "auth-service"         = { cpu = 256, memory = 512 }
    "user-service"         = { cpu = 256, memory = 512 }
    "wallet-service"       = { cpu = 256, memory = 512 }
    "trading-engine"       = { cpu = 256, memory = 512 }
    "notification-service" = { cpu = 256, memory = 512 }
  }

  service_name       = each.key
  cluster_id         = module.ecs_cluster.cluster_arn
  desired_count      = 1
  cpu                = each.value.cpu
  memory             = each.value.memory

  container_name     = each.key
  container_port     = 8080

  image = (
    each.key == "admin-service"        ? module.ecr_admin.repository_url :
    each.key == "auth-service"         ? module.ecr_auth.repository_url :
    each.key == "user-service"         ? module.ecr_user.repository_url :
    each.key == "wallet-service"       ? module.ecr_wallet.repository_url :
    each.key == "trading-engine"       ? module.ecr_trading.repository_url :
    module.ecr_notification.repository_url
  )

  task_family        = "${each.key}-task-family"
  execution_role_arn = module.ecs_cluster.execution_role_arn
  security_group_id  = module.security_groups.ecs_sg_id
  target_group_arn   = module.alb.target_group_arn
  subnet_ids         = [module.vpc.private_subnet1_id, module.vpc.private_subnet2_id]
  cluster_name       = module.ecs_cluster.cluster_name
}
