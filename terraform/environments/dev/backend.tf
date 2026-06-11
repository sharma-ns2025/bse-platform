terraform {
  backend "s3" {
    bucket = "bse-data-bucket"
    key    = "bse-platform/dev/terraform.tfstate"
    region = "eu-central-1"
    encrypt = true
  }
}