provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Owner = "ktcloud_team1_260204"
      Env = "dev"
    }
  }
}
