output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_arn" {
  value = aws_vpc.main.arn
}

output "primary_availability_zone" {
  value = var.primary_availability_zone
}

output "witness_availability_zone" {
  value = var.witness_availability_zone
}

output "primary_public_subnet_id" {
  value = aws_subnet.primary_public.id
}

output "witness_public_subnet_id" {
  value = aws_subnet.witness_public.id
}

output "primary_private_subnet_id" {
  value = aws_subnet.primary_private.id
}

output "witness_private_subnet_id" {
  value = aws_subnet.witness_private.id
}

output "eks_cluster_subnet_ids" {
  value = [aws_subnet.primary_private.id, aws_subnet.witness_private.id]
}

output "alb_public_subnet_ids" {
  value = [aws_subnet.primary_public.id, aws_subnet.witness_public.id]
}

output "nat_public_ip" {
  value = aws_eip.nat.public_ip
}
