# Include your security group module (ensure it outputs SG IDs)
module "security_groups" {
  source = "./security-groups"
}

# Build N instance configs from num_instances
locals {
  instances = [
    for i in range(var.num_instances) : {
      name            = format("dev-%02d", i + 1)
      key_name        = var.key_name_default
      security_groups = [module.security_groups.dev_sg_security_group_id]
    }
  ]
}

resource "aws_instance" "ec2_instances" {
  count = length(local.instances)

  ami               = var.ami_id
  instance_type     = var.instance_type
  availability_zone = var.availability_zone
  subnet_id         = var.subnet_id

  key_name = coalesce(lookup(local.instances[count.index], "key_name", null), var.key_name_default)

  # Use SG **IDs** (recommended in VPCs)
  vpc_security_group_ids = local.instances[count.index].security_groups

  # Make the root volume 50 GB
  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    delete_on_termination = true
  }

  # Cloud-init user data: set hostname, then run your script content
  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    # Set hostname from Terraform
    hostnamectl set-hostname ${local.instances[count.index].name}
  EOT

  tags = {
    Name = local.instances[count.index].name
  }
}

output "ec2_public_ips" {
  description = "Public IPs of the EC2 instances"
  value       = aws_instance.ec2_instances[*].public_ip
}