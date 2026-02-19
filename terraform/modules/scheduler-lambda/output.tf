output "lambda_start_name" {
  value = aws_lambda_function.start.function_name
}

output "lambda_stop_name" {
  value = aws_lambda_function.stop.function_name
}

output "lambda_role_arn" {
  value = aws_iam_role.lambda_role.arn
}

output "start_rule_name" {
  value = aws_cloudwatch_event_rule.start_rule.name
}

output "stop_rule_name" {
  value = aws_cloudwatch_event_rule.stop_rule.name
}
