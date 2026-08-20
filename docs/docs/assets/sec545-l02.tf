variable "vm_version" {
  type        = string
  description = "SemVer version of image or empty for latest"
  default     = ""
  validation {
    condition     = length(var.vm_version) == 0 || can(regex("[0-9]+.[0-9]+.[0-9]+", var.vm_version))
    error_message = "Sem Ver for image eg. 23.0.100 ( [0-9]+.[0-9]+.[0-9]+ ) or unset"
  }
}

variable "instance_type" {
  type    = string
  default = "m5.xlarge"
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-2a", "us-east-2b"]
}

variable "trusted_cidr" {
  type        = string
  description = "Trusted CIDR address allowed to access the VM"
  default     = "600.500.400.300/200"
}

variable "ami_owner" {
  type        = string
  description = "Account that owns the AMI"
  default     = "469658012540" # SROC account
}

terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~>3.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~>2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~>2.4"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~>4.0"
    }
    publicip = {
      source  = "nxt-engineering/publicip"
      version = "0.0.9"
    }
  }
}

provider "aws" {
  region = "us-east-2"
}

provider "publicip" {
  provider_url = "https://ipinfo.io/" # optional
  timeout      = "10s"                # optional

  # 1 request per 500ms
  rate_limit_rate  = "500ms" # optional
  rate_limit_burst = "1"     # optional
}

resource "random_pet" "ssh_key_name" {
  separator = "-"
}

data "aws_ami" "sec545" {
  most_recent = true

  filter {
    name   = "name"
    values = ["author-sec545-*-flight-simulator-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = [var.ami_owner]

}

data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "publicip_address" "default" {
}

locals {
  allowed_cidr    = (var.trusted_cidr != "600.500.400.300/200" ? var.trusted_cidr : "${data.publicip_address.default.ip}/32")
  k3s_version     = "v1.31.4+k3s1"
  aws_cli_version = "2.33.26"

  k3s_kubeconfig = <<-KUBECONFIG
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        certificate-authority-data: ${base64encode(tls_self_signed_cert.k3s_ca.cert_pem)}
        server: https://${aws_eip.k3s.public_ip}:6443
      name: k3s
    contexts:
    - context:
        cluster: k3s
        user: k3s-admin
      name: k3s
    current-context: k3s
    preferences: {}
    users:
    - name: k3s-admin
      user:
        client-certificate-data: ${base64encode(tls_locally_signed_cert.k3s_client.cert_pem)}
        client-key-data: ${base64encode(tls_private_key.k3s_client.private_key_pem)}
  KUBECONFIG
}

resource "random_pet" "proxy_pass" {
  length    = 4
  separator = "_"
  keepers = {
    ami_id = data.aws_ami.sec545.id
  }
}

resource "random_integer" "ssh_proxy_port" {
  min = 54000
  max = 54999
  keepers = {
    ami_id = data.aws_ami.sec545.id
  }
}

resource "random_uuid" "k3s_token" {}

resource "aws_vpc" "main" {
  cidr_block = "10.54.0.0/16"

  tags = {
    Name = "SEC545 ${random_pet.ssh_key_name.id}"
  }
}

resource "aws_subnet" "subnet1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.54.1.0/24"
  availability_zone = var.availability_zones[0]

  tags = {
    Name = "Subnet1"
    Type = "Public"
  }
}

resource "aws_subnet" "subnet2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.54.2.0/24"
  availability_zone = var.availability_zones[1]

  tags = {
    Name = "Subnet2"
    Type = "Public"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "rt1" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "Public"
  }
}

resource "aws_route_table_association" "rta1" {
  subnet_id      = aws_subnet.subnet1.id
  route_table_id = aws_route_table.rt1.id
}

resource "aws_route_table_association" "rta2" {
  subnet_id      = aws_subnet.subnet2.id
  route_table_id = aws_route_table.rt1.id
}

resource "aws_security_group" "sec545vm" {
  name        = "sgSEC545VM"
  description = "SEC545 VM network traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.allowed_cidr]
  }

  ingress {
    description = "54000 from anywhere"
    from_port   = 54000
    to_port     = 54000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
#    cidr_blocks = [local.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "SEC545 ${random_pet.ssh_key_name.id}"
  }
}

resource "aws_security_group" "k3s" {
  name        = "sgK3S-${random_pet.ssh_key_name.id}"
  description = "k3s node network traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.allowed_cidr]
  }

  ingress {
    description = "Kubernetes API from anywhere"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "K3S-${random_pet.ssh_key_name.id}"
  }
}

resource "aws_eip" "k3s" {
  domain = "vpc"

  tags = {
    Name = "SEC545 ${random_pet.ssh_key_name.id}"
  }
}

resource "aws_instance" "sec545" {
  ami                    = data.aws_ami.sec545.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.sec545.key_name
  subnet_id              = aws_subnet.subnet1.id
  vpc_security_group_ids = [aws_security_group.sec545vm.id]

  root_block_device {
    volume_size = 200
    volume_type = "gp3"
  }

  tags = {
    Name = "SEC545 ${random_pet.ssh_key_name.id}"
  }
}

resource "aws_key_pair" "sec545" {
  key_name   = "sec545-${random_pet.ssh_key_name.id}"
  public_key = tls_private_key.sec545.public_key_openssh
}

resource "tls_private_key" "sec545" {
  algorithm = "ED25519"
}

resource "aws_eip_association" "k3s" {
  instance_id   = aws_instance.sec545.id
  allocation_id = aws_eip.k3s.id
}

resource "tls_private_key" "k3s_client" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "k3s_ca" {
  private_key_pem = tls_private_key.k3s_client.private_key_pem

  subject {
    common_name = "k3s-ca"
  }

  validity_period_hours = 8760
  is_ca_certificate     = true
  allowed_uses = [
    "cert_signing",
    "digital_signature",
    "key_encipherment",
    "server_auth",
    "client_auth",
  ]
}

resource "tls_locally_signed_cert" "k3s_client" {
  cert_request_pem = tls_cert_request.k3s_client.cert_request_pem
  ca_private_key_pem = tls_private_key.k3s_client.private_key_pem
  ca_cert_pem = tls_self_signed_cert.k3s_ca.cert_pem

  validity_period_hours = 8760

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
    "client_auth",
  ]
}

resource "tls_cert_request" "k3s_client" {
  private_key_pem = tls_private_key.k3s_client.private_key_pem

  subject {
    common_name = "k3s-admin"
  }
}

resource "local_sensitive_file" "kubeconfig" {
  content  = local.k3s_kubeconfig
  filename = "${path.module}/kubeconfig"
}

resource "local_file" "ssh_config" {
  content = <<-EOF
Host sec545-vm
  HostName ${aws_instance.sec545.public_ip}
  User student
  IdentityFile ${path.module}/${aws_key_pair.sec545.key_name}.pem
  ProxyCommand none
  ServerAliveInterval 60
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null

Host sec545-proxy
  HostName ${aws_instance.sec545.public_ip}
  User student
  IdentityFile ${path.module}/${aws_key_pair.sec545.key_name}.pem
  DynamicForward 54000
  ServerAliveInterval 60
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
  filename = "${path.module}/ssh-config"
}

resource "aws_key_pair" "student" {
  key_name   = "student-${random_pet.ssh_key_name.id}"
  public_key = tls_private_key.student.public_key_openssh
}

resource "tls_private_key" "student" {
  algorithm = "ED25519"
}

output "environment_summary" {
  value = <<EOT
Latest AMI:  ${data.aws_ami.sec545.id} - ${data.aws_ami.sec545.name}
  Running AMI: ${data.aws_ami.sec545.id}
  Public IP:   ${aws_instance.sec545.public_ip}

  Local IP:          ${aws_instance.sec545.private_ip}
  Allow CIDR:        ${local.allowed_cidr}

  Proxy Pass:        ${random_pet.proxy_pass.id}
  SmartProxy Config: SmartProxy-${random_pet.proxy_pass.id}.json

  SSH + SOCKS Connect Command

      ssh -i ${aws_key_pair.sec545.key_name}.pem -D ${random_integer.ssh_proxy_port.result} student@${aws_instance.sec545.public_ip}

EOT
}
