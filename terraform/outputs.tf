output "health_url" {
  value = "${aws_apigatewayv2_api.health_check.api_endpoint}/health"
}

output "table_name" {
  value = aws_dynamodb_table.requests.name
}

output "lambda_name" {
  value = aws_lambda_function.health_check.function_name
}
