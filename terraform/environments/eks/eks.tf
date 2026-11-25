#trivy:ignore:AWS-0040 lab 工作機在 VPC 外（無 VPN / bastion），需 public endpoint 才能 kubectl；叢集用完即 destroy；prod 改 private endpoint
#trivy:ignore:AWS-0041 工作機出口 IP 不固定且 repo 為 public，不寫入 IP；prod 限定公司出口 CIDR
#trivy:ignore:AWS-0104 node 需經 NAT 拉 image（ECR / Docker Hub）及呼叫 AWS API，為 EKS module 預設 egress 規則
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
