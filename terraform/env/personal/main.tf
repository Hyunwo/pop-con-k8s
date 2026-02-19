module "vpc" {
    source = "../../modules/vpc"
    name = var.vpc_name
    cidr = var.vpc_cidr
    public_subnet_cidrs = var.public_subnet_cidrs
    private_subnet_cidrs = var.private_subnet_cidrs
    azs = var.azs

}

module "ecr" {
    source = "../../modules/ecr"
    name = var.ecr_name
}
  
module "ec2" {
    source = "../../modules/ec2"
    name = "t1-dev-ec2"
    instance_type = var.instance_type
    subnet_id     = module.vpc.public_subnet_ids[0]
    vpc_id        = module.vpc.vpc_id
    key_name      = var.key_name

}

module "scheduler" {
  source      = "../../modules/scheduler-lambda"
  name        = "t1-dev-scheduler"
  instance_id = module.ec2.instance_id
  env = "dev"
}

# ECR 레지스트리 주소 추출 (123456789.dkr.ecr.ap-northeast-2.amazonaws.com)
locals {
    ecr_registry = split("/", module.ecr.repository_url)[0]
}

module "ssm_parameters" {
    source       = "../../modules/ssm-parameters"
    project_name = "popcon"

    # 일반 파라미터 (평문)
    parameters = {
        "ECR_REGISTRY"           = local.ecr_registry
        "SPRING_PROFILES_ACTIVE" = "prod"           # Spring 프로필 (prod=MySQL, default=H2)
        "DB_HOST"                = "popcon-mysql"
        "DB_PORT"                = "3306"
        "DB_NAME"                = "popcon"
        "JAVA_OPTS"              = "-Xms512m -Xmx512m"
        "REDIS_HOST"             = "popcon-redis"
        "REDIS_PORT"             = "6379"
    }

    # 민감 파라미터 (KMS 암호화)
    secrets = {
        "DB_USERNAME"      = var.db_username
        "DB_PASSWORD"      = var.db_password
        "DB_ROOT_PASSWORD" = var.db_root_password
    }
}
