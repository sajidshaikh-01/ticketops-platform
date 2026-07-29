resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-${var.environment}"
  role_arn = var.eks_cluster_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(var.public_subnet_ids, var.private_subnet_ids)
    endpoint_public_access   = true
    endpoint_private_access  = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-eks"
    Environment = var.environment
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-${var.environment}-nodes"
  node_role_arn   = var.eks_node_role_arn
  subnet_ids      = var.private_subnet_ids

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  instance_types = [var.instance_type]
  capacity_type  = "ON_DEMAND"

  tags = {
    Name        = "${var.project_name}-${var.environment}-eks-nodes"
    Environment = var.environment
  }
}

# OIDC provider — required foundation for IRSA (IAM Roles for Service Accounts).
# We create it now; actual IRSA roles (e.g. for AWS Load Balancer Controller) get attached in Phase 6.
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name        = "${var.project_name}-${var.environment}-eks-oidc"
    Environment = var.environment
  }
}

data "aws_iam_policy_document" "alb_controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.project_name}-${var.environment}-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume_role.json
}

resource "aws_iam_policy" "alb_controller" {
  name   = "${var.project_name}-${var.environment}-alb-controller-policy"
  policy = file("${path.module}/alb_controller_policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# --- Loki IRSA ---
# Lets Loki pods (monitoring:loki service account) write chunks/index directly
# to S3 without static AWS credentials, following the same OIDC trust pattern
# as the ALB controller above.
data "aws_iam_policy_document" "loki_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:monitoring:loki"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "loki" {
  name               = "${var.project_name}-${var.environment}-loki-role"
  assume_role_policy = data.aws_iam_policy_document.loki_assume_role.json
}

# Scoped to exactly one bucket, ListBucket at bucket level + object actions
# at object level — least privilege, no wildcard resource.
data "aws_iam_policy_document" "loki_s3_access" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.loki_logs_bucket_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.loki_logs_bucket_arn}/*"]
  }
}

resource "aws_iam_policy" "loki" {
  name   = "${var.project_name}-${var.environment}-loki-policy"
  policy = data.aws_iam_policy_document.loki_s3_access.json
}

resource "aws_iam_role_policy_attachment" "loki" {
  role       = aws_iam_role.loki.name
  policy_arn = aws_iam_policy.loki.arn
}

# --- Dedicated monitoring/logging node group ---
# Simpler alternative to the prefix-delegation/nodeadm approach: a plain
# managed node group with a bigger instance type gets a much higher default
# pod ceiling with zero custom launch template or nodeadm config, per AWS's
# own eni-max-pods.txt table (t3.medium=17, t3.large=35 — confirmed against
# https://github.com/awslabs/amazon-eks-ami/blob/main/nodeadm/internal/kubelet/eni-max-pods.txt).
# Hosts monitoring/logging workloads (Fluent Bit, Loki, Prometheus, Grafana)
# so the main app node group doesn't need to grow just to fit observability.
resource "aws_eks_node_group" "monitoring" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-${var.environment}-monitoring-nodes"
  node_role_arn   = var.eks_node_role_arn
  subnet_ids      = var.private_subnet_ids

  instance_types = ["t3.large"]
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    workload = "monitoring"
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-monitoring-nodes"
    Environment = var.environment
    Purpose     = "monitoring-logging-workloads"
  }
}

# --- EBS CSI Driver IRSA ---
# NOTE: role name is hardcoded to match what eksctl already created on the live cluster
# (installed manually on 2026-07-11 to fix PVC provisioning). Imported into Terraform
# rather than replaced, to avoid an unnecessary IAM role swap on a working cluster.
data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "eksctl-ticketops-dev-addon-aws-ebs-csi-driver-Role1-DQYfpaMZ6OqN"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  tags = {
    Name        = "${var.project_name}-${var.environment}-ebs-csi-addon"
    Environment = var.environment
  }
}