variable "project_name" {
  description = "SSM 파라미터 경로의 프로젝트명 (예: popcon → /popcon/KEY)"
  type        = string
}

variable "parameters" {
  description = "일반 파라미터 (평문 저장)"
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "민감 파라미터 (KMS 암호화 저장)"
  type        = map(string)
  default     = {}

  validation {
    condition = length(setintersection(
      toset(keys(var.secrets)),
      toset(keys(var.parameters))
    )) == 0
    error_message = "secrets와 parameters 키가 중복되면 안 됩니다."
  }
}
