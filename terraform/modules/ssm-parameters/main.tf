resource "aws_ssm_parameter" "parameters" {
  for_each = var.parameters

  name  = "/${var.project_name}/${each.key}"
  type  = "String"
  value = each.value
}

resource "aws_ssm_parameter" "secrets" {
  for_each = var.secrets

  name  = "/${var.project_name}/${each.key}"
  type  = "SecureString"
  value = each.value
}
