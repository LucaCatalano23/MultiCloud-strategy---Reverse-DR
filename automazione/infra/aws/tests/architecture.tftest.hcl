mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-west-1a", "eu-west-1b"]
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }

  mock_resource "aws_eks_cluster" {
    defaults = {
      endpoint = "https://example.eks.amazonaws.com"
      version  = "1.32"
      identity = [{
        oidc = [{
          issuer = "https://oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE"
        }]
      }]
      vpc_config = [{
        cluster_security_group_id = "sg-0123456789abcdef0"
      }]
    }
  }
}

mock_provider "tls" {
  mock_data "tls_certificate" {
    defaults = {
      certificates = [{
        sha1_fingerprint = "0123456789abcdef0123456789abcdef01234567"
      }]
    }
  }
}

run "poc_keeps_compute_and_data_in_primary_az" {
  command = plan

  variables {
    availability_zones = ["eu-west-1a", "eu-west-1b"]
  }

  assert {
    condition     = module.eks.node_subnet_ids == [module.network.primary_private_subnet_id]
    error_message = "The managed node group must be pinned to the primary private subnet."
  }

  assert {
    condition     = module.database.availability_zone == "eu-west-1a"
    error_message = "RDS must remain in the primary availability zone."
  }

  assert {
    condition     = module.database.multi_az == false
    error_message = "The PoC database must be explicitly single-AZ."
  }

  assert {
    condition     = length(module.network.eks_cluster_subnet_ids) == 2
    error_message = "EKS still requires a minimal witness subnet in a second AZ."
  }

  assert {
    condition     = toset(keys(module.ecr.repository_urls)) == toset(["frontend", "bff", "ticket", "automation", "ticket-processor"])
    error_message = "The four deployable services and the ticket-processor function image each require an ECR repository."
  }
}

run "public_cluster_endpoint_rejects_world_open_cidr" {
  command = plan

  variables {
    availability_zones            = ["eu-west-1a", "eu-west-1b"]
    eks_endpoint_public_access    = true
    eks_public_access_cidrs       = ["0.0.0.0/0"]
  }

  expect_failures = [var.eks_public_access_cidrs]
}
