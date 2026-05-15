terraform {
  required_version = ">= 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_dynamodb_table" "requests" {
  name         = "${var.env}-requests-db"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.env}-health-check-lambda"
  retention_in_days = 14
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole"
    ]
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${var.env}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    effect = "Allow"

    actions = [
      "dynamodb:PutItem"
    ]

    resources = [
      aws_dynamodb_table.requests.arn
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "${aws_cloudwatch_log_group.lambda.arn}:*"
    ]
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  name   = "${var.env}-lambda-policy"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_policy.json
}

resource "aws_lambda_function" "health_check" {
  function_name    = "${var.env}-health-check-lambda"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)
  timeout          = 5
  memory_size      = 128

  environment {
    variables = {
      requests_table = aws_dynamodb_table.requests.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda
  ]
}

resource "aws_apigatewayv2_api" "health_check" {
  name          = "${var.env}-health-check-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.health_check.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.health_check.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_health" {
  api_id    = aws_apigatewayv2_api.health_check.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "post_health" {
  api_id    = aws_apigatewayv2_api.health_check.id
  route_key = "POST /health"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.health_check.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.api_rate_limit
    throttling_burst_limit = var.api_burst_limit
  }
}

resource "aws_lambda_permission" "allow_api_gateway" {
  statement_id  = "${var.env}-allow-api-gateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.health_check.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.health_check.execution_arn}/*/*"
}
