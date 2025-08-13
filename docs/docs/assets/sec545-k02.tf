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

  owners = ["469658012540"] # SROC account
}

data "publicip_address" "default" {
}

locals {
  allowed_cidr = (var.trusted_cidr != "600.500.400.300/200" ? var.trusted_cidr : "${data.publicip_address.default.ip}/32")
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
    cidr_blocks = [local.allowed_cidr]
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
runcmd:
  - /root/set_proxy_password
  - rm /root/.student_pat_created || true
  - echo "$(date)  ${random_pet.proxy_pass.id}" > /muck.txt
  - ls -Al /root >> /muck.txt
EOF

  tags = {
    Name = "SEC545 ${random_pet.ssh_key_name.id}"
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

  END_SUMMARY
}

# export AWS_PROFILE=
#
# terraform init
#
# terraform apply
#
