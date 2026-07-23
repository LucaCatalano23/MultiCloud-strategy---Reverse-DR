output "event_bus_name" {
  value = aws_cloudwatch_event_bus.application.name
}

output "event_bus_arn" {
  value = aws_cloudwatch_event_bus.application.arn
}

output "queue_url" {
  value = aws_sqs_queue.automation.id
}

output "queue_arn" {
  value = aws_sqs_queue.automation.arn
}

output "dead_letter_queue_arn" {
  value = aws_sqs_queue.dead_letter.arn
}

output "lambda_function_arn" {
  value = try(aws_lambda_function.automation[0].arn, null)
}

output "lambda_function_name" {
  value = try(aws_lambda_function.automation[0].function_name, null)
}
