output "parameter_arns" {
  description = "생성된 일반 파라미터 ARN 목록"
  value       = { for k, v in aws_ssm_parameter.parameters : k => v.arn }
}

output "secret_arns" {
  description = "생성된 민감 파라미터 ARN 목록"
  value       = { for k, v in aws_ssm_parameter.secrets : k => v.arn }
}
