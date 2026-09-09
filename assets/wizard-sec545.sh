#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ORIG_HOME="${HOME:-}"

# Work in place: the Terraform template already lives next to this script,
# so run Terraform directly here instead of copying it into a scratch dir.
WORKDIR="${SCRIPT_DIR}"
TEMPLATE_PATH="${SCRIPT_DIR}/sec545-l02.tf"
export TF_DATA_DIR="${WORKDIR}/.terraform-data"
mkdir -p "${WORKDIR}/.terraform.d" "${TF_DATA_DIR}"

if [[ -n "${ORIG_HOME}" ]]; then
  export AWS_CONFIG_FILE="${ORIG_HOME}/.aws/config"
  export AWS_SHARED_CREDENTIALS_FILE="${ORIG_HOME}/.aws/credentials"
fi

REGION="us-east-2"
AMI_OWNER="469658012540"
AMI_FILTER="*sec545*"
ACTION=""
AUTO_CONFIRM=false
AMI_ID=""
WIZARD=false
TRUSTED_CIDR=""
AWS_PROFILE="${AWS_PROFILE:-}"
SKIP_REMOTE_TEARDOWN=false
GENAIAPP_REPO="git@gitlab.sans.labs:ai/genaiapp.git"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

SEC545 lab deploy/destroy helper.

This wizard lists the most recent shared SEC545 AMIs in us-east-2, lets you pick one,
then deploys or destroys the matching Terraform stack.

Options:
  -d, --deploy              Deploy the lab environment.
  -D, --destroy             Destroy the lab environment.
  -w, --wizard              Force wizard mode even when flags are present.
  -a, --ami-id ID           Use a specific shared AMI instead of prompting.
  -P, --profile NAME        AWS profile to use (default: default, if present).
  -r, --region REGION      AWS region to query (default: us-east-2).
  -o, --owner ACCOUNT_ID   AWS owner/account for the shared AMIs (default: 469658012540).
  -f, --filter PATTERN      Name filter for AMIs (default: *sec545*).
  -t, --template PATH      Terraform template to use (default: sec545-l02.tf next to this script).
  -p, --workdir PATH       Working directory for Terraform files/state (default: script directory).
  -c, --cidr CIDR           Trusted CIDR to pass into Terraform (optional).
  -S, --skip-remote-teardown Skip SSHing into the instance to run the genaiapp destroy_lab.sh script.
  -y, --yes                Auto-confirm prompts.
  -h, --help               Show this help message.

Examples:
  ${SCRIPT_NAME} --wizard
  ${SCRIPT_NAME} --deploy --ami-id ami-0123456789abcdef0
  ${SCRIPT_NAME} --destroy --yes
  ${SCRIPT_NAME} --deploy --region us-east-2 --owner 469658012540
EOF
}

log() {
  echo "[${SCRIPT_NAME}] $*"
}

fail() {
  echo "[${SCRIPT_NAME}] ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

list_aws_profiles() {
  aws configure list-profiles 2>/dev/null || true
}

select_aws_profile() {
  if [[ -n "${AWS_PROFILE}" ]]; then
    export AWS_DEFAULT_PROFILE="${AWS_PROFILE}"
    return
  fi

  local profiles=()
  while IFS= read -r profile; do
    profile="${profile//[$'\r\n']}"
    [[ -n "${profile}" ]] && profiles+=("${profile}")
  done < <(list_aws_profiles)

  if (( ${#profiles[@]} == 0 )); then
    log "No AWS profiles found. Using the default AWS SDK environment."
    return
  fi

  if (( ${#profiles[@]} == 1 )); then
    AWS_PROFILE="${profiles[0]}"
    export AWS_DEFAULT_PROFILE="${AWS_PROFILE}"
    return
  fi

  if printf '%s\n' "${profiles[@]}" | grep -Fxq 'default'; then
    AWS_PROFILE="default"
    export AWS_DEFAULT_PROFILE="${AWS_PROFILE}"
    return
  fi

  echo
  echo "Available AWS profiles:"
  local index=1
  for profile in "${profiles[@]}"; do
    echo "  ${index}) ${profile}"
    ((index += 1))
  done
  echo

  local choice=""
  while true; do
    read -r -p "Select AWS profile to use [default]: " choice
    choice="${choice:-default}"
    if printf '%s\n' "${profiles[@]}" | grep -Fxq "${choice}"; then
      AWS_PROFILE="${choice}"
      export AWS_DEFAULT_PROFILE="${AWS_PROFILE}"
      return
    fi
    echo "Please choose one of the listed profiles."
  done
}

list_amis() {
  aws ec2 describe-images \
    --region "${REGION}" \
    --owners "${AMI_OWNER}" \
    --filters "Name=name,Values=${AMI_FILTER}" "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[].{ImageId:ImageId,Name:Name,CreationDate:CreationDate}" \
    --output json
}

print_ami_menu() {
  local json="$1"
  python3 - "$json" <<'PY'
import json, sys
payload = sys.argv[1]
try:
    images = json.loads(payload)
except json.JSONDecodeError:
    print("NO_IMAGES")
    raise SystemExit(0)
if not images:
    print("NO_IMAGES")
    raise SystemExit(0)
images = sorted(images, key=lambda x: x.get('CreationDate', ''), reverse=True)
for idx, image in enumerate(images, start=1):
    image_id = image.get('ImageId', 'unknown')
    name = image.get('Name', 'unknown')
    created = image.get('CreationDate', 'unknown')
    print(f"{idx}|{image_id}|{name}|{created}")
PY
}

prepare_terraform_workdir() {
  local selected_ami="$1"

  # No file copying: Terraform picks up the .tf file that's already here.
  if [[ -n "${TRUSTED_CIDR}" ]]; then
    cat > "${WORKDIR}/terraform.tfvars" <<EOF
selected_ami_id = "${selected_ami}"
trusted_cidr = "${TRUSTED_CIDR}"
EOF
  else
    cat > "${WORKDIR}/terraform.tfvars" <<EOF
selected_ami_id = "${selected_ami}"
EOF
  fi
}

has_existing_state() {
  [[ -f "${WORKDIR}/terraform.tfstate" ]] || [[ -f "${WORKDIR}/terraform.tfstate.backup" ]]
}

# Prints the AWS account/identity terraform will act as, so the user can
# confirm they're deploying into the right account before anything is built.
show_aws_account_info() {
  local identity account_id user_arn
  if ! identity="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
    log "WARNING: Could not verify the AWS account/user (aws sts get-caller-identity failed)."
    return 0
  fi
  account_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("Account",""))' <<< "${identity}")"
  user_arn="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("Arn",""))' <<< "${identity}")"
  log "AWS account: ${account_id}  |  Identity: ${user_arn}  |  Profile: ${AWS_PROFILE:-default}"
}

# Finds the lab VM's SSH key file and public IP by reading them out of the
# environment_summary output. The template writes no ssh-config, and there
# are two .pem files (web + k3s), so match the SOCKS connect line
# specifically (it has "-D"; the k3s SSH line doesn't).
find_web_ssh_target() {
  local summary match
  summary="$(terraform output -raw environment_summary 2>/dev/null)" || return 1
  match="$(echo "${summary}" | grep -Eo 'ssh -i [^ ]+\.pem -D [0-9]+ student@[0-9.]+' | head -n1)"
  [[ -n "${match}" ]] || return 1
  echo "${match}"
}

# SSHes into the running lab instance and runs the genaiapp teardown script
# before the local terraform destroy tears down the VM itself.
run_remote_teardown() {
  if [[ "${SKIP_REMOTE_TEARDOWN}" == true ]]; then
    log "Skipping remote lab teardown (--skip-remote-teardown)."
    return 0
  fi

  if ! has_existing_state; then
    return 0
  fi

  local ssh_target key_file public_ip
  ssh_target="$(find_web_ssh_target)"
  if [[ -z "${ssh_target}" ]]; then
    log "Could not determine the lab VM's SSH key/IP from Terraform output; skipping remote teardown."
    return 0
  fi
  key_file="${WORKDIR}/$(echo "${ssh_target}" | awk '{print $3}')"
  public_ip="$(echo "${ssh_target}" | awk -F'@' '{print $2}')"

  if [[ ! -f "${key_file}" ]]; then
    log "SSH key file ${key_file} not found; skipping remote teardown."
    return 0
  fi

  log "Connecting to student@${public_ip} to run the genaiapp lab teardown."

  local remote_cmd
  remote_cmd=$(cat <<'REMOTE'
set -e
mkdir -p ~/code
if [[ ! -d ~/code/genaiapp ]]; then
  echo "[remote] Cloning genaiapp repository..."
  git clone GENAIAPP_REPO_PLACEHOLDER ~/code/genaiapp
fi
cd ~/code/genaiapp
echo "[remote] Running destroy_lab.sh..."
/bin/bash ./destroy_lab.sh
REMOTE
)
  remote_cmd="${remote_cmd//GENAIAPP_REPO_PLACEHOLDER/${GENAIAPP_REPO}}"

  if ssh -i "${key_file}" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=15 \
      "student@${public_ip}" "${remote_cmd}"; then
    log "Remote lab teardown completed."
  else
    log "WARNING: Remote lab teardown failed or the instance was unreachable; continuing with terraform destroy."
  fi
}

run_terraform_action() {
  local selected_ami="$1"
  local action="$2"

  if [[ "${action}" == "deploy" ]]; then
    prepare_terraform_workdir "${selected_ami}"
  elif [[ "${action}" == "destroy" ]]; then
    # Keep the AMI already deployed (from tfvars) so the AMI data source
    # stays consistent with what's tracked in state.
    local ami_for_destroy="${selected_ami}"
    if [[ -f "${WORKDIR}/terraform.tfvars" ]]; then
      local existing_ami
      existing_ami="$(sed -n 's/^selected_ami_id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "${WORKDIR}/terraform.tfvars" | head -n1)"
      [[ -n "${existing_ami}" ]] && ami_for_destroy="${existing_ami}"
    fi
    prepare_terraform_workdir "${ami_for_destroy}"
  fi

  cd "${WORKDIR}"

  log "Running terraform init..."
  terraform init

  if [[ "${action}" == "deploy" ]]; then
    log "Deploying SEC545 lab with AMI ${selected_ami}"
    if [[ -n "${TRUSTED_CIDR}" ]]; then
      terraform apply -var="selected_ami_id=${selected_ami}" -var="trusted_cidr=${TRUSTED_CIDR}" -auto-approve
    else
      terraform apply -var="selected_ami_id=${selected_ami}" -auto-approve
    fi
  elif [[ "${action}" == "destroy" ]]; then
    if has_existing_state; then
      log "Destroying SEC545 lab with existing Terraform state."
    else
      log "No Terraform state found; preparing a fresh destroy configuration."
    fi
    run_remote_teardown
    if [[ -n "${TRUSTED_CIDR}" ]]; then
      terraform destroy -var="trusted_cidr=${TRUSTED_CIDR}" -auto-approve
    else
      terraform destroy -auto-approve
    fi
  else
    fail "Unsupported action: ${action}"
  fi
}

prompt_for_ami() {
  local images_json
  images_json="$(list_amis)"

  if [[ -z "${images_json}" || "${images_json}" == "null" ]]; then
    fail "No SEC545 AMIs found for owner ${AMI_OWNER} in ${REGION}."
  fi

  local menu
  menu="$(print_ami_menu "${images_json}")"

  if [[ "${menu}" == "NO_IMAGES" ]]; then
    fail "No available SEC545 AMIs were found for the selected owner and region."
  fi

  echo
  echo "Available SEC545 shared AMIs (most recent first):"
  echo "${menu}" | awk -F'|' '{printf "  %2s- %-20s %-60s %s\n", $1, $2, $3, $4}'
  echo

  local choice=""
  while true; do
    if [[ "${AUTO_CONFIRM}" == true ]]; then
      choice="1"
      break
    fi
    read -r -p "Select an AMI number to use [1]: " choice
    choice="${choice:-1}"
    if [[ "${choice}" =~ ^[0-9]+$ ]]; then
      local max_count
      max_count="$(echo "${menu}" | wc -l | tr -d ' ')"
      if (( choice >= 1 && choice <= max_count )); then
        break
      fi
    fi
    echo "Please enter a valid number from the menu."
  done

  local selected_line
  selected_line="$(echo "${menu}" | awk -F'|' -v n="${choice}" 'NR==n {print}')"
  IFS='|' read -r _ AMI_ID _ _ <<< "${selected_line}"
  if [[ -z "${AMI_ID}" ]]; then
    fail "Unable to determine the selected AMI ID."
  fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -d|--deploy)
        ACTION="deploy"
        ;;
      -D|--destroy)
        ACTION="destroy"
        ;;
      -w|--wizard)
        WIZARD=true
        ;;
      -a|--ami-id)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --ami-id"
        AMI_ID="$1"
        ;;
      -P|--profile)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --profile"
        AWS_PROFILE="$1"
        ;;
      -r|--region)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --region"
        REGION="$1"
        ;;
      -o|--owner)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --owner"
        AMI_OWNER="$1"
        ;;
      -f|--filter)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --filter"
        AMI_FILTER="$1"
        ;;
      -t|--template)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --template"
        TEMPLATE_PATH="$1"
        ;;
      -p|--workdir)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --workdir"
        WORKDIR="$1"
        ;;
      -c|--cidr)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --cidr"
        TRUSTED_CIDR="$1"
        ;;
      -S|--skip-remote-teardown)
        SKIP_REMOTE_TEARDOWN=true
        ;;
      -y|--yes)
        AUTO_CONFIRM=true
        ;;
      --)
        shift
        break
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  require_cmd aws
  require_cmd terraform
  require_cmd python3
  select_aws_profile
  show_aws_account_info

  if [[ ! -f "${TEMPLATE_PATH}" ]]; then
    fail "Terraform template not found: ${TEMPLATE_PATH}"
  fi

  if [[ -z "${ACTION}" && "${WIZARD}" != true ]]; then
    if [[ -n "${AMI_ID}" ]]; then
      ACTION="deploy"
    else
      WIZARD=true
    fi
  fi

  if [[ "${WIZARD}" == true ]]; then
    if [[ -z "${ACTION}" ]]; then
      echo "Build SEC545 lab range"
      echo "Choose whether to deploy or destroy the lab."
      echo
      echo "1- Build range"
      echo "2- Destroy range"
      echo "3- Quit"
      while true; do
        if [[ "${AUTO_CONFIRM}" == true ]]; then
          ACTION="deploy"
          break
        fi
        read -r -p "Select action [1]: " action_choice
        action_choice="${action_choice:-1}"
        case "${action_choice}" in
          1)
            ACTION="deploy"
            break
            ;;
          2)
            ACTION="destroy"
            break
            ;;
          3)
            exit 0
            ;;
          *)
            echo "Please enter 1, 2, or 3."
            ;;
        esac
      done
    fi

    if [[ "${ACTION}" == "deploy" && -z "${AMI_ID}" ]]; then
      prompt_for_ami
    elif [[ "${ACTION}" == "destroy" && -z "${AMI_ID}" && ! has_existing_state ]]; then
      prompt_for_ami
    fi

    if [[ "${ACTION}" == "deploy" ]]; then
      log "Using AMI ${AMI_ID} for deployment."
      run_terraform_action "${AMI_ID}" "deploy"
    else
      if has_existing_state; then
        log "Using existing Terraform state for destruction."
      else
        log "No Terraform state found; using the selected AMI for destroy prep."
      fi
      run_terraform_action "${AMI_ID:-existing-state}" "destroy"
    fi

    exit 0
  fi

  if [[ -z "${AMI_ID}" && "${ACTION}" == "deploy" ]]; then
    prompt_for_ami
  fi

  if [[ "${ACTION}" == "deploy" ]]; then
    run_terraform_action "${AMI_ID}" "deploy"
  elif [[ "${ACTION}" == "destroy" ]]; then
    run_terraform_action "${AMI_ID}" "destroy"
  else
    usage
    exit 1
  fi
}

main "$@"
