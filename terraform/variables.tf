variable "env" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "lambda_zip_path" {
  type = string
}

variable "api_rate_limit" {
  type = number
}

variable "api_burst_limit" {
  type = number
}