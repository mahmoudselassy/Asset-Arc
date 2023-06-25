provider "aws" {
  access_key = "AKIAW7RN25ENVZHM4Y3A"
  secret_key = "ajjsV9dgaj9uByRXW3ER7MkFprsDOQxNwD7xeM3N"
  region     = "us-east-1"  # Update with your desired region
}

resource "aws_s3_bucket" "assets_bucket" {
  bucket = "assets-csv-bucket"
}

resource "aws_sqs_queue" "assets_queue" {
  name = "assets-queue"
  visibility_timeout_seconds = 43200
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq_assets_queue.arn
    maxReceiveCount     = 5  # Maximum number of times a message can be received before being sent to the DLQ
  })
}

resource "aws_iam_role" "root_role" {
  name = "root-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "root_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  role       = aws_iam_role.root_role.name
}

resource "aws_iam_role_policy_attachment" "root_role_logs_policy_attachment" {
  role       = aws_iam_role.root_role.name
  policy_arn = aws_iam_policy.root_role_logs_policy.arn
}

resource "aws_iam_policy" "root_role_logs_policy" {
  name        = "root-role-logs-policy"
  description = "Policy for log-related actions"
  policy      = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "logs:CreateLogGroup",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    },
    {
      "Effect": "Allow",
      "Action": "sqs:SendMessage",
      "Resource": "${aws_sqs_queue.assets_queue.arn}"
    },
    {
      "Effect": "Allow",
      "Action": "sqs:GetQueueUrl",
      "Resource": "${aws_sqs_queue.assets_queue.arn}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage"
      ],
      "Resource": "${aws_sqs_queue.dlq_assets_queue.arn}"
    },
    {
      "Effect": "Allow",
      "Action": "sqs:GetQueueAttributes",
      "Resource": "${aws_sqs_queue.dlq_assets_queue.arn}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem"
      ],
      "Resource": "${aws_dynamodb_table.assets_table.arn}"
    }
  ]
}
EOF
}

resource "aws_lambda_function" "file_changes_lambda" {
  function_name    = "file-changes-lambda"
  runtime          = "python3.9"
  handler          = "index.handler"
  role             = aws_iam_role.root_role.arn
  filename         = "File Change Handler.zip"
  source_code_hash = filebase64sha256("File Change Handler.zip")
  timeout          = 900
}

resource "aws_lambda_permission" "s3_lambda_permission" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.file_changes_lambda.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.assets_bucket.arn
}

resource "aws_s3_bucket_notification" "file_changes_lambda_trigger" {
  bucket = aws_s3_bucket.assets_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.file_changes_lambda.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.s3_lambda_permission]
}

resource "aws_sqs_queue_policy" "assets_queue_policy" {
  queue_url = aws_sqs_queue.assets_queue.id
  policy    = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "lambda.amazonaws.com"
        },
        "Action": "sqs:SendMessage",
        "Resource": aws_sqs_queue.assets_queue.arn,
        "Condition": {
          "ArnEquals": {
            "aws:SourceArn": aws_lambda_function.file_changes_lambda.arn
          }
        }
      }
    ]
  })
}


resource "aws_lambda_permission" "sqs_lambda_permission" {
  statement_id  = "AllowSQSSendMessage"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.file_changes_lambda.arn
  principal     = "sqs.amazonaws.com"
  source_arn    = aws_sqs_queue.assets_queue.arn
}

resource "aws_lambda_function_event_invoke_config" "file_changes_lambda_destination" {
  function_name = aws_lambda_function.file_changes_lambda.function_name
  destination_config {
    on_success {
      destination = aws_sqs_queue.assets_queue.arn
    }
    on_failure {
      destination = aws_sqs_queue.dlq_assets_queue.arn
    }
  }
}

resource "aws_sqs_queue" "dlq_assets_queue" {
  name = "dlq-assets-queue"
  visibility_timeout_seconds = 43200
}

resource "aws_lambda_function" "assets_consumer_lambda" {
  function_name    = "assets-consumer-lambda"
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  role             = aws_iam_role.root_role.arn
  filename         = "Assets Consumer Handler.zip"
  source_code_hash = filebase64sha256("Assets Consumer Handler.zip")
  timeout          = 900

  # Add any other required configuration for your Lambda function

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.assets_queue.url
      EVAL_FUNCTION = aws_lambda_function.asset_evaluation_lambda.function_name
      ASSETS_TABLE = aws_dynamodb_table.assets_table.name
    }
  }


  # Add any other required configuration for your Lambda function
}


resource "aws_iam_role_policy_attachment" "consumer_sqs_policy" {
  role       = aws_iam_role.root_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
}

# Configure the SQS queue trigger for the Lambda function
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn  = aws_sqs_queue.assets_queue.arn
  function_name     = aws_lambda_function.assets_consumer_lambda.function_name
  batch_size = 1
}

resource "aws_lambda_function" "asset_evaluation_lambda" {
  function_name    = "asset-evaluation-lambda"
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  role             = aws_iam_role.root_role.arn
  filename         = "Asset Evaluation Handler.zip"
  source_code_hash = filebase64sha256("Asset Evaluation Handler.zip")
  timeout          = 900

   environment {
    variables = {
      CHATGPT_URL= "https://api.openai.com/v1/chat/completions"
      CHATGPT_API_KEY = "API_KEY"
    }
  }
}

resource "aws_lambda_permission" "asset_evaluation_lambda_permission" {
  statement_id  = "AllowExecutionFromConsumer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.asset_evaluation_lambda.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_lambda_function.assets_consumer_lambda.arn
}


resource "aws_iam_policy" "lambda_invoke_policy" {
  name        = "lambda-invoke-policy"
  description = "Policy for invoking Lambda functions"

  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "lambda:InvokeFunction",
        "Resource": aws_lambda_function.asset_evaluation_lambda.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "consumer_lambda_invoke_policy_attachment" {
  role       = aws_iam_role.root_role.name
  policy_arn = aws_iam_policy.lambda_invoke_policy.arn
}

resource "aws_dynamodb_table" "assets_table" {
  name         = "assets-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

}
resource "aws_lambda_permission" "asset_consumer_lambda_dynamodb_permission" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.assets_consumer_lambda.function_name
  principal     = "dynamodb.amazonaws.com"
  source_arn    = aws_dynamodb_table.assets_table.arn
}
