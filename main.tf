################################################################################
# Provider
################################################################################

provider "aws" {
  region = var.region
}


################################################################################
# VPC
################################################################################
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  cluster_name = "eks-karpenter-1"

  tags = {
    Example    = local.cluster_name
    GithubRepo = "terraform-aws-eks"
    GithubOrg  = "terraform-aws-modules"
  }
}


module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name = "karpenter-vpc-eks"

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
  # intra_subnets   = ["10.0.7.0/24", "10.0.8.0/24", "10.0.9.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  enable_dns_hostnames   = true
  enable_dns_support     = true
  one_nat_gateway_per_az = false

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  # private_subnet_tags = {
  #   "kubernetes.io/role/internal-elb" = 1
  #   # Tags subnets for Karpenter auto-discovery
  #   "karpenter.sh/discovery" = local.cluster_name
  # }
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.5"

  cluster_name    = local.cluster_name
  cluster_version = "1.30"

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  enable_irsa = true

  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  # control_plane_subnet_ids = module.vpc.intra_subnets


  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"

    tags = {
      "karpenter.sh/discovery" = local.cluster_name
    }
  }

  eks_managed_node_groups = {
    one = {
      name = "eks-managed-node"

      instance_types = ["t3.medium"]

      min_size     = 1
      max_size     = 10
      desired_size = 2

      # taints = {
      #   # This Taint aims to keep just EKS Addons and Karpenter running on this MNG
      #   # The pods that do not tolerate this taint should run on nodes created by Karpenter
      #   addons = {
      #     key    = "CriticalAddonsOnly"
      #     value  = "true"
      #     effect = "NO_SCHEDULE"
      #   }
      # }
    }

    two = {
      name = "node-group-2"

      instance_types = ["t3.medium"]
      capacity_type  = "SPOT"

      min_size     = 1
      max_size     = 2
      desired_size = 1
    }
  }

  # node_security_group_tags = {
  #   # NOTE - if creating multiple security groups with this module, only tag the
  #   # security group that Karpenter should utilize with the following tag
  #   # (i.e. - at most, only one security group should have this tag in your account)
  #   "karpenter.sh/discovery" = local.cluster_name
  # }
}

# https://aws.amazon.com/blogs/containers/amazon-ebs-csi-driver-is-now-generally-available-in-amazon-eks-add-ons/ 
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "5.39.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

################################################################################
# EKS Auto Mode Module
################################################################################

# https://marcincuber.medium.com/amazon-eks-auto-mode-with-terraform-8b15c2f1aa62
