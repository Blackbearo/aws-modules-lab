module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "lab-eks"
  kubernetes_version = "1.37" # standard support 內最新版；舊版進 extended support 每小時 US$0.60

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = ["c7i-flex.large"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }
  }
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
