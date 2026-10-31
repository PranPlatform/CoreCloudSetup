# Shared helpers for the deploy/teardown/assume scripts. Source, don't execute.
# Written for bash 3.2+ (macOS default) as well as CloudShell's bash 5.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Every stack, in deployment order. Stack name = "<stackPrefix>-<key>".
STACK_KEYS=(
  iam-guardrails-boundary
  iam-deployer-user
  iam-deployer-role
  network-vpc
  network-tier-public
  network-tier-private
  network-tier-data
  network-nat
  network-endpoints
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not installed."
  done
}

# cfg <jq-path>: read a scalar from the config, empty string if missing/null.
cfg() { jq -r "$1 // empty" "$CONFIG"; }

# cfg_list <jq-path>: read an array from the config as a comma-separated string.
cfg_list() { jq -r "($1 // []) | join(\",\")" "$CONFIG"; }

# load_config <path>: validate the config file and export the common settings.
load_config() {
  CONFIG="$1"
  [[ -f "$CONFIG" ]] || die "Config file not found: $CONFIG"
  jq empty "$CONFIG" 2>/dev/null || die "Config file is not valid JSON: $CONFIG"

  local key missing=()
  for key in .region .stackPrefix .iam.deployerUserName .iam.deployerRoleName \
             .network.vpcCidr .network.natMode \
             .network.tiers.public.cidrA .network.tiers.public.cidrB \
             .network.tiers.private.cidrA .network.tiers.private.cidrB \
             .network.tiers.data.cidrA .network.tiers.data.cidrB; do
    [[ -n "$(cfg "$key")" ]] || missing+=("$key")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Missing required config keys: ${missing[*]}"

  REGION="$(cfg .region)"
  PREFIX="$(cfg .stackPrefix)"
  DEPLOYER_USER="$(cfg .iam.deployerUserName)"
  DEPLOYER_ROLE="$(cfg .iam.deployerRoleName)"
  NAT_MODE="$(cfg .network.natMode)"

  [[ "$PREFIX" =~ ^[a-z][a-z0-9-]{1,19}$ ]] \
    || die "stackPrefix must be 2-20 chars of lowercase letters, digits and dashes, starting with a letter."
  case "$NAT_MODE" in
    none|single|per-az) ;;
    *) die "network.natMode must be one of: none, single, per-az (got '$NAT_MODE')." ;;
  esac
}

stack_name() { echo "${PREFIX}-$1"; }

is_known_stack() {
  local key
  for key in "${STACK_KEYS[@]}"; do [[ "$key" == "$1" ]] && return 0; done
  return 1
}

stack_exists() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" >/dev/null 2>&1
}

# delete_stack <name>: lift termination protection, delete, and wait.
delete_stack() {
  local name="$1"
  if ! stack_exists "$name"; then
    log "Stack $name does not exist, skipping."
    return 0
  fi
  log "Deleting $name"
  aws cloudformation update-termination-protection --region "$REGION" \
    --stack-name "$name" --no-enable-termination-protection >/dev/null
  aws cloudformation delete-stack --region "$REGION" --stack-name "$name"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$name"
}

print_identity() {
  local identity
  identity="$(aws sts get-caller-identity --output json)" \
    || die "Unable to call sts:GetCallerIdentity. Are AWS credentials configured?"
  ACCOUNT_ID="$(jq -r .Account <<<"$identity")"
  CALLER_ARN="$(jq -r .Arn <<<"$identity")"
  log "Account: $ACCOUNT_ID  Region: $REGION  Caller: $CALLER_ARN"
}

# confirm <prompt> <expected-answer>: skipped when AUTO_APPROVE=1.
confirm() {
  [[ "${AUTO_APPROVE:-0}" == "1" ]] && return 0
  local answer
  read -r -p "$1 " answer
  [[ "$answer" == "$2" ]] || die "Aborted."
}
