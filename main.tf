# -------------------------------------------------
# ECS Fargate + ECR Portfolio Deployment
# -------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Random suffix for unique names
resource "random_id" "suffix" {
  byte_length = 4
}

# Variables
locals {
  app_name = "portfolio-flask"
  container_port = 5000
  
  tags = {
    Project     = "Portfolio Flask App"
    Environment = "Production"
    ManagedBy   = "Terraform"
  }
}

# -------------------------------------------------
# ECR Repository (Container Registry)
# -------------------------------------------------

resource "aws_ecr_repository" "app" {
  name                 = "${local.app_name}-${random_id.suffix.hex}"
  image_tag_mutability = "MUTABLE"
  
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

# -------------------------------------------------
# VPC and Networking
# -------------------------------------------------

# Get default VPC
data "aws_vpc" "default" {
  default = true
}

# Get default subnets
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security Group for ALB
resource "aws_security_group" "alb" {
  name        = "${local.app_name}-alb-sg-${random_id.suffix.hex}"
  description = "Security group for ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.app_name}-alb-sg"
  })
}

# Security Group for ECS Tasks
resource "aws_security_group" "ecs_tasks" {
  name        = "${local.app_name}-ecs-tasks-sg-${random_id.suffix.hex}"
  description = "Security group for ECS tasks"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Allow traffic from ALB"
    from_port       = local.container_port
    to_port         = local.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.app_name}-ecs-tasks-sg"
  })
}

# -------------------------------------------------
# Application Load Balancer
# -------------------------------------------------

resource "aws_lb" "main" {
  name               = "${local.app_name}-alb-${random_id.suffix.hex}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids

  enable_deletion_protection = false

  tags = merge(local.tags, {
    Name = "${local.app_name}-alb"
  })
}

# Target Group
resource "aws_lb_target_group" "app" {
  name        = "${local.app_name}-tg-${random_id.suffix.hex}"
  port        = local.container_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
  }

  tags = merge(local.tags, {
    Name = "${local.app_name}-tg"
  })
}

# ALB Listener
resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = local.tags
}

# -------------------------------------------------
# IAM Roles
# -------------------------------------------------

# ECS Task Execution Role
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${local.app_name}-ecs-task-execution-${random_id.suffix.hex}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Task Role
resource "aws_iam_role" "ecs_task_role" {
  name = "${local.app_name}-ecs-task-${random_id.suffix.hex}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.tags
}

# -------------------------------------------------
# ECS Cluster
# -------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "${local.app_name}-cluster-${random_id.suffix.hex}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.app_name}-${random_id.suffix.hex}"
  retention_in_days = 7

  tags = local.tags
}

# ECS Task Definition
resource "aws_ecs_task_definition" "app" {
  family                   = "${local.app_name}-${random_id.suffix.hex}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"  # 0.25 vCPU
  memory                   = "512"  # 0.5 GB
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = local.app_name
      image     = "${aws_ecr_repository.app.repository_url}:latest"
      essential = true

      portMappings = [
        {
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "ENVIRONMENT"
          value = "AWS ECS Fargate"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${local.container_port}/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = local.tags
}

# ECS Service
resource "aws_ecs_service" "app" {
  name            = "${local.app_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.app_name
    container_port   = local.container_port
  }

  depends_on = [aws_lb_listener.app]

  tags = local.tags
}

# -------------------------------------------------
# Outputs
# -------------------------------------------------

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.app.repository_url
}

output "load_balancer_dns" {
  description = "Load Balancer DNS name (your app URL)"
  value       = "http://${aws_lb.main.dns_name}"
}

output "ecs_cluster_name" {
  description = "ECS Cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS Service name"
  value       = aws_ecs_service.app.name
}

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group"
  value       = aws_cloudwatch_log_group.app.name
}