terraform {
  # 개인 실습용: 로컬에 state 저장 (팀 S3 사용 안 함)
  # 팀 계정 전환 시 아래 s3 backend로 교체
  # backend "s3" {
  #   bucket = "my-terraform-state"
  #   key    = "env/personal/terraform.tfstate"
  #   region = "ap-northeast-2"
  # }
}
