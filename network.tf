data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(
    { Name = local.resource_prefix },
    local.tags
  )
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(
    {
      Name = "${local.resource_prefix}-public"
      Tier = "public"
    },
    local.tags
  )
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(
    {
      Name = "${local.resource_prefix}-private"
      Tier = "private"
    },
    local.tags
  )
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(
    { Name = "${local.resource_prefix}-igw" },
    local.tags
  )
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(
    { Name = "${local.resource_prefix}-nat-eip" },
    local.tags
  )
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  depends_on = [aws_internet_gateway.main]

  tags = merge(
    { Name = "${local.resource_prefix}-nat" },
    local.tags
  )
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(
    { Name = "${local.resource_prefix}-public-rt" },
    local.tags
  )
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(
    { Name = "${local.resource_prefix}-private-rt" },
    local.tags
  )
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "nlb" {
  name        = "${local.resource_prefix}-nlb-sg"
  description = "Public HTTP/HTTPS entry to the load balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from the internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from the internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.resource_prefix}-nlb-sg"
  }
}

resource "aws_security_group" "ec2_app" {
  name        = "${local.resource_prefix}-ec2-sg"
  description = "Private EC2 instance. Public SSH is disabled; SSM is used instead."
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from the NLB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.nlb.id]
  }

  ingress {
    description     = "HTTPS from the NLB"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.nlb.id]
  }

  egress {
    description = "Allow outbound traffic for package updates and AWS API access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.resource_prefix}-ec2-sg"
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.resource_prefix}-vpc-endpoints-sg"
  description = "Allow private EC2 to reach the Session Manager endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTPS from the EC2 app"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_app.id]
  }

  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.resource_prefix}-vpc-endpoints-sg"
  }
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${local.resource_prefix}-ssm-endpoint"
  }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${local.resource_prefix}-ec2messages-endpoint"
  }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${local.resource_prefix}-ssmmessages-endpoint"
  }
}

resource "aws_eip" "nlb" {
  domain = "vpc"

  tags = {
    Name = "${local.resource_prefix}-nlb-eip"
  }
}

resource "aws_lb" "app" {
  name               = substr("${local.resource_prefix}-nlb", 0, 32)
  internal           = false
  load_balancer_type = "network"
  security_groups    = [aws_security_group.nlb.id]

  enable_cross_zone_load_balancing = true

  subnet_mapping {
    subnet_id     = aws_subnet.public.id
    allocation_id = aws_eip.nlb.id
  }

  tags = {
    Name = "${local.resource_prefix}-nlb"
  }
}

resource "aws_lb_target_group" "app_https" {
  name        = substr("${local.resource_prefix}-tg-https", 0, 32)
  port        = 443
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    port                = "traffic-port"
    protocol            = "TCP"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${local.resource_prefix}-tg-https"
  }
}

resource "aws_lb_target_group" "app_http" {
  name        = substr("${local.resource_prefix}-tg-http", 0, 32)
  port        = 80
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    port                = "traffic-port"
    protocol            = "TCP"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${local.resource_prefix}-tg-http"
  }
}

resource "aws_lb_target_group_attachment" "app_https" {
  target_group_arn = aws_lb_target_group.app_https.arn
  target_id        = aws_instance.app.id
  port             = 443
}

resource "aws_lb_target_group_attachment" "app_http" {
  target_group_arn = aws_lb_target_group.app_http.arn
  target_id        = aws_instance.app.id
  port             = 80
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_https.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_http.arn
  }
}

resource "aws_route53_record" "app" {
  count   = var.domain_name == null || var.route53_zone_id == null ? 0 : 1
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

