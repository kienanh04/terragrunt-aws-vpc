provider "aws" {
  region  = "${var.aws_region}"
  profile = "${var.aws_profile}"
}

terraform {
  backend "s3" {}
}

data "aws_availability_zones" "available" {}

resource "null_resource" "public_subnets" {
  count    = "${length(var.public_subnets) == "0" ? var.num_of_public_subnets : 0}"
  triggers = {
    subnet = "${cidrsubnet("${var.vpc_cidr}", var.newbits , count.index + var.first_netnum )}"
  }
}

resource "null_resource" "private_subnets" {
  count    = "${length(var.private_subnets) == "0" ? var.num_of_private_subnets : 0}"
  triggers = {
    subnet = "${cidrsubnet("${var.vpc_cidr}", var.newbits , count.index + var.num_of_public_subnets + var.first_netnum )}"
  }
}

resource "null_resource" "database_subnets" {
  count    = "${length(var.database_subnets) == "0" ? var.num_of_database_subnets : 0}"
  triggers = {
    subnet = "${cidrsubnet("${var.vpc_cidr}", var.newbits , count.index + var.num_of_public_subnets + var.num_of_private_subnets + var.first_netnum )}"
  }
}

resource "null_resource" "azs" {
  count    = "${length(var.azs) == "0" ? local.max_subnet_length : 0}"
  triggers = {
    az = "${element(data.aws_availability_zones.available.names,count.index)}"
  }
}

locals {
  common_tags = {
    Env = "${var.project_env}"
  }

  vpc_name          = "${var.vpc_name == "" ? "${var.project_env}-${var.project_name}" : "${var.vpc_name}" }"
  public_subnets    = "${compact(split(",", (length(var.public_subnets) == "0" ? join(",", null_resource.public_subnets.*.triggers.subnet) : join(",", var.public_subnets))))}"
  private_subnets   = "${compact(split(",", (length(var.private_subnets) == "0" ? join(",", null_resource.private_subnets.*.triggers.subnet) : join(",", var.private_subnets))))}"
  database_subnets  = "${compact(split(",", (length(var.database_subnets) == "0" ? join(",", null_resource.database_subnets.*.triggers.subnet) : join(",", var.database_subnets))))}"
  max_subnet_length = "${max(length(local.public_subnets),length(local.private_subnets),length(local.database_subnets))}"
  azs               = "${compact(split(",", (length(var.azs) == "0" ? join(",", null_resource.azs.*.triggers.az) : join(",", var.azs))))}"
  key_name          = "${var.customized_key_name == "" ? "${var.project_name}-${var.project_env}" : var.customized_key_name}"
  dhcp_options_domain_name = "${var.dns_private ? var.domain_locals[0] : ""}"
}

///////////////////////
//        vpc        //
///////////////////////

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "1.72.0"

  name = "${local.vpc_name}"
  cidr = "${var.vpc_cidr}"
  tags = "${merge(local.common_tags, var.tags)}"

  enable_dns_hostnames    = "${var.enable_dns_hostnames}"
  enable_dns_support      = "${var.enable_dns_support}"
  map_public_ip_on_launch = "${var.map_public_ip_on_launch}"

  enable_nat_gateway      = "${var.enable_nat_gateway}"
  single_nat_gateway      = "${var.single_nat_gateway}"

  azs                     = ["${local.azs}"]
  public_subnets          = ["${local.public_subnets}"]
  private_subnets         = ["${local.private_subnets}"]
  database_subnets        = ["${local.database_subnets}"]

  enable_dhcp_options          = true
  dhcp_options_domain_name     = "${local.dhcp_options_domain_name}"

  create_database_subnet_group = "${var.create_database_subnet_group}"

  # Endpoints:
  enable_s3_endpoint       = "${var.enable_s3_endpoint}"
  enable_dynamodb_endpoint = "${var.enable_dynamodb_endpoint}"
  
}

///////////////////////////////////
//            Route53            //
///////////////////////////////////
resource "aws_route53_zone" "private" {
  count   = "${var.dns_private ? length(var.domain_locals) : 0}"
  name    = "${element(var.domain_locals,count.index)}"
  comment = "${var.project_name} Private Zone"

  vpc {
    vpc_id  = "${module.vpc.vpc_id}"
  }

  tags = "${merge(local.common_tags, var.tags)}"
}

resource "aws_route53_zone" "public" {
  count   = "${var.dns_public ? length(var.domain_names) : 0}"
  name    = "${element(var.domain_names,count.index)}"
  comment = "${var.project_name} Public Zone"

  tags = "${merge(local.common_tags, var.tags)}"
}

locals {
  public_name_servers = "${concat(aws_route53_zone.public.*.name_servers,list(list("")))}"
}

///////////////////////
//       Keys        //
///////////////////////
resource "aws_key_pair" "key_ssh" {
  count      = "${var.add_key_pair ? 1 : 0}"
  key_name   = "${local.key_name}"
  public_key = "${file("${var.ssh_public_key}")}"
}
