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