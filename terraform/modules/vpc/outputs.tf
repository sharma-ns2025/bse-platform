output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet1_id" {
  value = aws_subnet.private1.id
}

output "private_subnet2_id" {
  value = aws_subnet.private2.id
}

output "private_route_table1_id" {
  value = aws_route_table.private1.id
}

output "private_route_table2_id" {
  value = aws_route_table.private2.id
}