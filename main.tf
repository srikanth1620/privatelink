# Variables 
variable "vpc_cidr" {
  description = "The CIDR block for the VPC"
  default     = "10.70.0.0/16"
}

variable "private_subnets" {
  type        = "list"
  description = "Subnets available"
  default = ["10.70.1.0/24","10.70.2.0/24"]
}

variable "ami" {
  description = "ami used to create private instances"
  default     = "ami-b70554c8"
}

variable "instance_type" {
  description = "instance type used to create private instances"
  default     = "t2.micro"
}

variable "privateCIDRblock" {
  description = "private CIDR block"
  default     = "10.52.2.0/24"
}

variable "public_subnet" {
  description = "public subnet available"
  default = "10.70.3.0/24"
}

variable "consumer_vpcid" {
  description = "Consumer VPC"
  default = "vpc-68937XXX"
}



# create VPC

resource "aws_vpc" "PLinkvpc" {
  cidr_block           = "${var.vpc_cidr}"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags {
    Name = "PLinkVPC"
    label = "blog"
  }
}


resource "aws_subnet" "PLink-privatesubnet" {
  count = "${length(var.private_subnets)}"
  vpc_id                  = "${aws_vpc.PLinkvpc.id}"
  cidr_block              = "${element(var.private_subnets, count.index)}"
  availability_zone       = "us-east-1a"
  tags {
    Name = "PLink-privatesubnet-${count.index+1}"
  }
}


# create subnets

resource "aws_subnet" "PLink-publicsubnet" {
  vpc_id                  = "${aws_vpc.PLinkvpc.id}"
  cidr_block              = "${var.public_subnet}"
  availability_zone       = "us-east-1a"

  tags {
    Name = "PLink-public"
  }
}

# Create internet gateway and attach it with VPC


resource "aws_internet_gateway" "PLink_internet_gateway" {
  vpc_id = "${aws_vpc.PLinkvpc.id}"

  tags {
    Name = "PLinkIGW"
  }
}


# Create route table and include internet gateway as route

resource "aws_route_table" "PLink_public_routetable" {
  vpc_id = "${aws_vpc.PLinkvpc.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.PLink_internet_gateway.id}"
  }

  tags {
    label = "PLink_public_routetable"
  }
}

# Associate route table with public subnet

resource "aws_route_table_association" "public_subnet" {
  subnet_id      = "${aws_subnet.PLink-publicsubnet.id}"
  route_table_id = "${aws_route_table.PLink_public_routetable.id}"
}

# create network load balancer

resource "aws_lb" "PLink_nlb" {
  #count = "$length(var.private_subnets)"
  name = "PLinkLB"
  load_balancer_type = "network"
  internal        = true
  subnets         = ["${aws_subnet.PLink-publicsubnet.id}"]
  #subnets         = "${element(aws_subnet.PLink-privatesubnet.*.id,0)}"
  enable_deletion_protection = false
}


# create target group

resource "aws_lb_target_group" "PLink_tg" {
  name = "PLinktg"
  port = 80
  protocol = "TCP"
  vpc_id = "${aws_vpc.PLinkvpc.id}"
  target_type = "instance"
}


# create listener

resource "aws_lb_listener" "PLink_listener" {
  load_balancer_arn = "${aws_lb.PLink_nlb.arn}"
  port = 80
  protocol = "TCP"
  "default_action" {
    target_group_arn = "${aws_lb_target_group.PLink_tg.arn}"
    type = "forward"
  }
}

# create private instances

resource "aws_instance" "PLink_private" {
  count = "${length(var.private_subnets)}"
  subnet_id = "${element(aws_subnet.PLink-privatesubnet.*.id, count.index)}"
  key_name = "snskey"
  ami = "${var.ami}"
  instance_type = "${var.instance_type}"
  tags {
    Name = "PLink_privateinstance-${count.index+1}"
  }
}

# create public instance

resource "aws_instance" "PLink_public" {
  subnet_id  = "${aws_subnet.PLink-publicsubnet.id}"
  associate_public_ip_address = true
  key_name = "snskey"
  ami = "${var.ami}"
  instance_type = "${var.instance_type}"
  tags {
    Name = "PLink_publicinstance"
  }
}

# create target group attachment

resource "aws_lb_target_group_attachment" "PLink_tg_attachment" {
  count = 2
  #availability_zone = "us-east-1a"
  target_group_arn = "${aws_lb_target_group.PLink_tg.arn}"
  target_id = "${element(aws_instance.PLink_private.*.id, count.index)}"
  port = "80"
}


# Create private link end point service on the provider side

resource "aws_vpc_endpoint_service" "PLink_serviceprovider" {
  acceptance_required = false
  network_load_balancer_arns = ["${aws_lb.PLink_nlb.arn}"]
}

output "service_provider_name" {
  description = "The name of VPC Endpoint Service"
  value       = "${aws_vpc_endpoint_service.PLink_serviceprovider.service_name}"
}



# Create the Security Group

resource "aws_security_group" "endpoint_sg" {
  vpc_id       = "${var.consumer_vpcid}"
  name         = "Endpoint_SG"
  description  = "Consumer Endpoint Security Group"
ingress {
    cidr_blocks = ["${var.privateCIDRblock}"]
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
  }
tags = {
        Name = "Endpoint_SG"
  }
}


# Create VPC interface on the consumer side

resource "aws_vpc_endpoint" "service_consumer" {
  vpc_id             = "${var.consumer_vpcid}"
  subnet_ids         = ["subnet-74268b5a"]
  security_group_ids = ["${aws_security_group.endpoint_sg.id}"]
  service_name       = "${aws_vpc_endpoint_service.PLink_serviceprovider.service_name}"
  vpc_endpoint_type  = "Interface"
}

# create route 53 resource

resource "aws_route53_zone" "service_consumer_ZONE" {
  name = "plinkendpoint.internal"
  vpc_id = "vpc-68937812"
  force_destroy = true
}

# create route 53 resource

resource "aws_route53_record" "service_consumer_CNAME" {
  zone_id = "${aws_route53_zone.service_consumer_ZONE.zone_id}"
  name    = "order.${aws_route53_zone.service_consumer_ZONE.name}"
  type    = "CNAME"
  ttl     = "300"
  records = ["${lookup(aws_vpc_endpoint.service_consumer.dns_entry[0], "dns_name")}"]
}

# ssh into the private instance on the consumer vpc and test with a simple curl cmd
# something like like this curl http://order.privatelinkendpoint.internal
