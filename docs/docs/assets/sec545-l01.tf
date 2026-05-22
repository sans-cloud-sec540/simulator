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
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "k3s API server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NodePort range 30000-30085"
    from_port   = 30000
    to_port     = 30085
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NodePort backend"
    from_port   = 30800
    to_port     = 30800
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Internal VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.54.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "k3s ${random_pet.ssh_key_name.id}"
  }
}

resource "aws_security_group_rule" "k3s_allow_student" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["${aws_instance.web.public_ip}/32"]
  security_group_id = aws_security_group.k3s.id
  description       = "Allow all traffic from student VM"
}

# k3s TLS certificates
resource "tls_private_key" "k3s_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "k3s_ca" {
  private_key_pem = tls_private_key.k3s_ca.private_key_pem

  subject {
    common_name  = "k3s-ca"
    organization = "k3s"
  }

  validity_period_hours = 87600 # 10 years
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "key_encipherment",
    "digital_signature",
  ]
}

resource "tls_private_key" "k3s_client" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "k3s_client" {
  private_key_pem = tls_private_key.k3s_client.private_key_pem

  subject {
    common_name  = "k3s-admin"
    organization = "system:masters"
  }
}

resource "tls_locally_signed_cert" "k3s_client" {
  cert_request_pem   = tls_cert_request.k3s_client.cert_request_pem
  ca_private_key_pem = tls_private_key.k3s_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.k3s_ca.cert_pem

  validity_period_hours = 87600 # 10 years

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "client_auth",
  ]
}

# k3s SSH key pair
resource "tls_private_key" "k3s_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "k3s" {
  key_name   = "k3s-${random_pet.ssh_key_name.id}"
  public_key = tls_private_key.k3s_ssh.public_key_openssh
}

resource "local_sensitive_file" "k3s_private_key" {
  content  = tls_private_key.k3s_ssh.private_key_pem
  filename = "k3s-${random_pet.ssh_key_name.id}.pem"
}

# k3s IAM
resource "aws_iam_role" "k3s" {
  name = "k3s-${random_pet.ssh_key_name.id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "k3s_ecr_readonly" {
  role       = aws_iam_role.k3s.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "k3s" {
  name = "k3s-inline-${random_pet.ssh_key_name.id}"
  role = aws_iam_role.k3s.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:*",
          "s3:*",
          "ec2:*",
          "bedrock:*",
          "logs:*",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "k3s" {
  name = "k3s-${random_pet.ssh_key_name.id}"
  role = aws_iam_role.k3s.name
}

# k3s Elastic IP
resource "aws_eip" "k3s" {
  domain = "vpc"

  tags = {
    Name = "k3s ${random_pet.ssh_key_name.id}"
  }
}

resource "aws_eip_association" "k3s" {
  instance_id   = aws_instance.k3s.id
  allocation_id = aws_eip.k3s.id
}

# Student VM
resource "aws_instance" "web" {
  ami                    = data.aws_ami.sec545.id
  instance_type          = "m5.xlarge"
  key_name               = random_pet.ssh_key_name.id
  subnet_id              = aws_subnet.subnet1.id
  vpc_security_group_ids = [aws_security_group.sec545vm.id]
  root_block_device {
    volume_size = 100
  }

  associate_public_ip_address = true

  lifecycle {
    ignore_changes = [ami]
  }

  #userdata
  user_data_replace_on_change = false
  user_data                   = <<EOF
#cloud-config
cloud_final_modules:
- [users-groups,always]
- [write_files,always]
- [scripts_user,always]
users:
  - name: student
    shell: /bin/bash
    lock_passwd: false
    ssh-authorized-keys:
    - ${tls_private_key.example.public_key_openssh}
write_files:
  - content: |
      #!/bin/bash
      echo student:StartTheLabs | chpasswd || true
      rm /home/student/.ssh/known_hosts || true
      sed --in-place -e 's#REPLACE_SOCKS_PASSWORD#${random_pet.proxy_pass.id}#g' /usr/share/nginx/landing_page/static/SmartProxy-Config.json || true
      chmod 0644 /usr/share/nginx/landing_page/static/SmartProxy-Config.json
      sed --in-place -e 's#REPLACE_SOCKS_PASSWORD#${random_pet.proxy_pass.id}#g' /etc/systemd/system/microsocks.service || true
      systemctl daemon-reload
      systemctl restart microsocks
      echo "${random_pet.proxy_pass.id}" > /home/socks.txt
    path: /root/set_proxy_password
    permissions: '0700'
  - path: /home/student/.kube/config
    permissions: '0600'
    owner: student:student
    encoding: b64
    content: ${base64encode(local.k3s_kubeconfig)}
  - path: /opt/gitlab-runner/.kube/config
    permissions: '0600'
    encoding: b64
    content: ${base64encode(local.k3s_kubeconfig)}
runcmd:
  - /root/set_proxy_password
  - rm /root/.student_pat_created || true
  - echo "$(date)  ${random_pet.proxy_pass.id}" > /muck.txt
  - ls -Al /root >> /muck.txt
  - chown -R student:student /home/student/.kube
  - mkdir -p /opt/gitlab-runner/.kube
  - chown -R gitlab-runner:gitlab-runner /opt/gitlab-runner/.kube
EOF

  tags = {
    Name = "SEC545 ${random_pet.ssh_key_name.id}"
  }
}

# k3s EC2 Instance
resource "aws_instance" "k3s" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = "t3.large"
  key_name               = aws_key_pair.k3s.key_name
  subnet_id              = aws_subnet.subnet1.id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.k3s.name

  root_block_device {
    volume_size = 150
  }

  user_data = <<EOF
#cloud-config
cloud_final_modules:
- [users-groups,always]
- [write_files,always]
- [scripts_user,always]
users:
  - name: k3s
    shell: /bin/bash
    lock_passwd: true
    ssh-authorized-keys:
    - ${tls_private_key.k3s_ssh.public_key_openssh}
write_files:
  - path: /var/lib/rancher/k3s/server/tls/server-ca.crt
    permissions: '0644'
    owner: root:root
    encoding: b64
    content: ${base64encode(tls_self_signed_cert.k3s_ca.cert_pem)}
  - path: /var/lib/rancher/k3s/server/tls/server-ca.key
    permissions: '0600'
    owner: root:root
    encoding: b64
    content: ${base64encode(tls_private_key.k3s_ca.private_key_pem)}
  - path: /var/lib/rancher/k3s/server/tls/client-ca.crt
    permissions: '0644'
    owner: root:root
    encoding: b64
    content: ${base64encode(tls_self_signed_cert.k3s_ca.cert_pem)}
  - path: /var/lib/rancher/k3s/server/tls/client-ca.key
    permissions: '0600'
    owner: root:root
    encoding: b64
    content: ${base64encode(tls_private_key.k3s_ca.private_key_pem)}
  - path: /root/install-k3s
    permissions: '0700'
    owner: root:root
    content: |
      #!/bin/bash
      set -euo pipefail

      IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
      PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        http://169.254.169.254/latest/meta-data/public-ipv4)

      echo "Discovered public IP: $PUBLIC_IP"

      AWS_CLI_VERSION="${local.aws_cli_version}"
      apt-get update
      apt-get install -y unzip amazon-ecr-credential-helper
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-$${AWS_CLI_VERSION}.zip" -o "/tmp/awscliv2.zip"
      unzip -q /tmp/awscliv2.zip -d /tmp
      /tmp/aws/install
      rm -rf /tmp/awscliv2.zip /tmp/aws
      echo "AWS CLI $(aws --version) installed"

      /usr/local/bin/refresh-ecr-creds

      curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="${local.k3s_version}" \
        K3S_TOKEN="${random_uuid.k3s_token.result}" \
        sh -s - server \
          --tls-san "$PUBLIC_IP" \
          --secrets-encryption

      echo "Waiting for k3s to be ready..."
      for i in $(seq 1 60); do
        if kubectl get nodes >/dev/null 2>&1; then
          echo "k3s is ready"
          break
        fi
        echo "Waiting... ($i/60)"
        sleep 5
      done

      K3S_USER_HOME="/home/k3s"
      mkdir -p "$K3S_USER_HOME/.kube"
      cp /etc/rancher/k3s/k3s.yaml "$K3S_USER_HOME/.kube/config"
      sed -i "s|https://127.0.0.1:6443|https://$PUBLIC_IP:6443|g" "$K3S_USER_HOME/.kube/config"
      chown -R k3s:k3s "$K3S_USER_HOME/.kube"
      chmod 600 "$K3S_USER_HOME/.kube/config"

      systemctl daemon-reload
      systemctl enable --now refresh-ecr-creds.service
      systemctl enable --now refresh-ecr-creds.timer

      echo "k3s installation complete"
  - path: /usr/local/bin/refresh-ecr-creds
    permissions: '0700'
    owner: root:root
    content: |
      #!/bin/bash
      set -euo pipefail

      aws ecr get-login-password --region us-east-1 \
      | docker login \
        --username AWS \
        --password-stdin $(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com
  - path: /etc/systemd/system/refresh-ecr-creds.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Refresh ECR credentials for k3s
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/refresh-ecr-creds
  - path: /etc/systemd/system/refresh-ecr-creds.timer
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Refresh ECR credentials every 6 hours

      [Timer]
      OnBootSec=6h
      OnUnitActiveSec=6h

      [Install]
      WantedBy=timers.target
runcmd:
  - /root/install-k3s
EOF

  tags = {
    Name = "k3s ${random_pet.ssh_key_name.id}"
  }
}

resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = random_pet.ssh_key_name.id
  public_key = tls_private_key.example.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content  = tls_private_key.example.private_key_pem
  filename = "${random_pet.ssh_key_name.id}.pem"
}

resource "local_file" "proxy_config" {
  filename        = "SmartProxy-${random_pet.ssh_key_name.id}.json"
  file_permission = "0640"
  content         = <<END_SMART_PROXY
    {
      "product": "SmartProxy",
      "version": "1.3.0",
      "proxyProfiles": [
        {
          "enabled": true,
          "proxyRules": [],
          "rulesSubscriptions": [],
          "profileType": 0,
          "profileId": "InternalProfile_Direct",
          "profileName": "Direct (No Proxy)",
          "profileProxyServerId": null,
          "profileTypeConfig": {
            "builtin": true,
            "editable": false,
            "selectable": true,
            "supportsSubscriptions": false,
            "supportsProfileProxy": false,
            "customProxyPerRule": false,
            "canBeDisabled": false,
            "supportsRuleActionWhitelist": false,
            "defaultRuleActionIsWhitelist": null
          }
        },
        {
          "enabled": true,
          "proxyRules": [
            {
              "enabled": true,
              "whiteList": false,
              "ruleId": 1916784186802454,
              "autoGeneratePattern": true,
              "ruleType": 5,
              "hostName": "sans.labs",
              "rulePattern": "",
              "ruleRegex": "",
              "ruleExact": "",
              "proxy": null,
              "proxyServerId": "-2",
              "ruleSearch": "sans.labs"
            },
            {
              "enabled": true,
              "whiteList": false,
              "ruleId": 782360404,
              "autoGeneratePattern": true,
              "ruleType": 5,
              "hostName": "dm.paper",
              "rulePattern": "",
              "ruleRegex": "",
              "ruleExact": "",
              "proxy": null,
              "proxyServerId": "-2",
              "ruleSearch": "dm.paper"
            }
          ],
          "rulesSubscriptions": [],
          "profileType": 2,
          "profileId": "InternalProfile_SmartRules",
          "profileName": "SEC545-Range",
          "profileProxyServerId": "cfr8zljbs0dye",
          "profileTypeConfig": {
            "builtin": true,
            "editable": true,
            "selectable": true,
            "supportsSubscriptions": true,
            "supportsProfileProxy": true,
            "customProxyPerRule": true,
            "canBeDisabled": true,
            "supportsRuleActionWhitelist": true,
            "defaultRuleActionIsWhitelist": false
          }
        },
        {
          "enabled": false,
          "proxyRules": [],
          "rulesSubscriptions": [],
          "profileType": 3,
          "profileId": "InternalProfile_AlwaysEnabled",
          "profileName": "Always Enable",
          "profileProxyServerId": "cfr8zljbs0dye",
          "profileTypeConfig": {
            "builtin": true,
            "editable": true,
            "selectable": true,
            "supportsSubscriptions": true,
            "supportsProfileProxy": true,
            "customProxyPerRule": true,
            "canBeDisabled": true,
            "supportsRuleActionWhitelist": true,
            "defaultRuleActionIsWhitelist": true
          }
        },
        {
          "enabled": true,
          "proxyRules": [],
          "rulesSubscriptions": [],
          "profileType": 1,
          "profileId": "InternalProfile_SystemProxy",
          "profileName": "System Proxy",
          "profileProxyServerId": null,
          "profileTypeConfig": {
            "builtin": true,
            "editable": false,
            "selectable": true,
            "supportsSubscriptions": false,
            "supportsProfileProxy": false,
            "customProxyPerRule": false,
            "canBeDisabled": false,
            "supportsRuleActionWhitelist": false,
            "defaultRuleActionIsWhitelist": null
          }
        },
        {
          "enabled": true,
          "proxyRules": [],
          "rulesSubscriptions": [],
          "profileType": 4,
          "profileId": "profile-zqshjljbrzeqk",
          "profileName": "Ignore Failure Rules",
          "profileTypeConfig": {
            "builtin": true,
            "editable": false,
            "selectable": false,
            "supportsSubscriptions": false,
            "supportsProfileProxy": false,
            "customProxyPerRule": false,
            "canBeDisabled": false,
            "supportsRuleActionWhitelist": false,
            "defaultRuleActionIsWhitelist": null
          }
        }
      ],
      "activeProfileId": "InternalProfile_SmartRules",
      "proxyServers": [
        {
          "name": "SEC545-name",
          "id": "cfr8zljbs0dye",
          "order": 4,
          "host": "${aws_instance.web.public_ip}",
          "port": "54000",
          "protocol": "SOCKS5",
          "username": "student",
          "password": "${random_pet.proxy_pass.id}",
          "proxyDNS": true,
          "failoverTimeout": null
        },
        {
          "name": "SEC545-SSH-Local-${random_integer.ssh_proxy_port.id}",
          "id": "cfrifmlkd1dyq",
          "order": 2,
          "host": "127.0.0.1",
          "port": ${random_integer.ssh_proxy_port.id},
          "protocol": "SOCKS5",
          "username": "",
          "password": "",
          "proxyDNS": true,
          "failoverTimeout": null
        }
      ],
      "proxyServerSubscriptions": [],
      "firstEverInstallNotified": true,
      "updateInfo": null,
      "options": {
        "syncSettings": false,
        "syncActiveProfile": false,
        "syncActiveProxy": false,
        "detectRequestFailures": true,
        "displayFailedOnBadge": true,
        "displayAppliedProxyOnBadge": true,
        "displayMatchedRuleOnBadge": true,
        "refreshTabOnConfigChanges": false,
        "proxyPerOrigin": false,
        "enableShortcuts": false,
        "shortcutNotification": false,
        "themeType": 0,
        "themesDark": "themes-cosmo-dark",
        "activeIncognitoProfileId": "",
        "themesLight": "",
        "themesLightCustomUrl": "",
        "themesDarkCustomUrl": ""
      },
      "defaultProxyServerId": "cfr8zljbs0dye"
    }
  END_SMART_PROXY
}

output "environment_summary" {
  value = <<END_SUMMARY
  Latest AMI:  ${data.aws_ami.sec545.id} - ${data.aws_ami.sec545.name}
  Running AMI: ${aws_instance.web.ami}
  Public IP:   ${aws_instance.web.public_ip}

  Local IP:          ${data.publicip_address.default.ip}
  Allow CIDR:        ${local.allowed_cidr}

  Proxy Pass:        ${random_pet.proxy_pass.id}
  SmartProxy Config: SmartProxy-${random_pet.ssh_key_name.id}.json

  SSH + SOCKS Connect Command

    ssh -i ${random_pet.ssh_key_name.id}.pem -D ${random_integer.ssh_proxy_port.id} student@${aws_instance.web.public_ip}

  k3s Public IP:  ${aws_eip.k3s.public_ip}
  k3s SSH:        ssh -i k3s-${random_pet.ssh_key_name.id}.pem k3s@${aws_eip.k3s.public_ip}
  k3s API:        https://${aws_eip.k3s.public_ip}:6443

  END_SUMMARY
}

# export AWS_PROFILE=
#
# terraform init
#
# terraform apply
#
