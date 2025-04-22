resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr #10.0.0.0/16
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_security_group" "allow_all" {
  name        = "allow_all"
  description = "Allow all inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_instance" "ec2" {
  count             = 2
  ami               = "ami-0e449927258d45bc4" # Use your region's Amazon Linux 2 AMI
  instance_type     = "t2.micro"
  subnet_id         = aws_subnet.public[count.index].id
  vpc_security_group_ids = [aws_security_group.allow_all.id]
  tags = {
    Name = "EC2-${count.index == 0 ? "Primary" : "Secondary"}"
  }
}
# RDS Instances (Multi-AZ)
resource "aws_db_instance" "rds" {
  count                    = 2
  identifier               = "mydb-${count.index == 0 ? "primary" : "secondary"}"
  allocated_storage        = 20
  engine                   = "mysql"
  engine_version           = "8.0"
  instance_class           = "db.t3.micro"
  username                 = "admin"
  password                 = "dbnewpassword"
  db_subnet_group_name     = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids   = [aws_security_group.allow_all.id]
  multi_az                 = true
  skip_final_snapshot      = true
}

resource "aws_db_subnet_group" "db_subnets" {
  name       = "db-subnet-group"
  subnet_ids = aws_subnet.public[*].id
}
# S3 Buckets (Primary and Secondary)
resource "aws_s3_bucket" "primary" {
  bucket = "my-primary-dr-project-123456"
  acl    = "private"
}

resource "aws_s3_bucket" "secondary" {
  bucket = "my-secondary-dr-project-123456"
  acl    = "private"
}

# S3 Cross Region Replication (CRR)
resource "aws_s3_bucket_replication_configuration" "replication" {
  bucket = aws_s3_bucket.primary.id

  role = aws_iam_role.s3_replication.arn

  rule {
    id     = "replication"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.secondary.arn
      storage_class = "STANDARD"
    }
  }
}

resource "aws_iam_role" "s3_replication" {
  name = "s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "s3.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "s3_replication_policy" {
  name = "s3-replication-policy"
  role = aws_iam_role.s3_replication.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Effect   = "Allow"
        Resource = [aws_s3_bucket.primary.arn]
      },
      {
        Action = [
          "s3:GetObjectVersion",
          "s3:GetObjectVersionAcl"
        ]
        Effect   = "Allow"
        Resource = ["${aws_s3_bucket.primary.arn}/*"]
      },
      {
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete"
        ]
        Effect   = "Allow"
        Resource = ["${aws_s3_bucket.secondary.arn}/*"]
      }
    ]
  })
}

# CloudWatch & CloudTrail
resource "aws_cloudwatch_log_group" "log_group" {
  name = "/aws/ha-architecture"
}

resource "aws_cloudtrail" "trail" {
  name                          = "ha-architecture-trail"
  s3_bucket_name                = aws_s3_bucket.primary.bucket
  include_global_service_events = true
  is_multi_region_trail         = true
}

# Route 53 Hosted Zone and Failover
resource "aws_route53_zone" "main" {
  name = "mydrproject.com"
}

resource "aws_route53_record" "failover" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "app.mydrproject.com"
  type    = "A"

  set_identifier = "primary"
  failover_routing_policy {
    type = "PRIMARY"
  }
  alias {
    name                   = aws_instance.ec2[0].public_dns
    zone_id                = aws_route53_zone.main.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "failover_secondary" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "app.mydrproject.com"
  type    = "A"

  set_identifier = "secondary"
  failover_routing_policy {
    type = "SECONDARY"
  }
  alias {
    name                   = aws_instance.ec2[1].public_dns
    zone_id                = aws_route53_zone.main.zone_id
    evaluate_target_health = true
  }
}



#Lambda, SNS for failover (simplified example)
resource "aws_sns_topic" "failover" {
  name = "failover-topic"
}

resource "aws_lambda_function" "failover" {
  filename         = "lambda_function_payload.zip"
  function_name    = "failoverLambda"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "nodejs14.x"
  #source_code_hash = filebase64sha256("lambda_function_payload.zip")
}

resource "aws_iam_role" "lambda_exec" {
  name = "lambda_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
