#!/usr/bin/env bash
# Deploys the core foundation stacks in dependency order. Idempotent: re-running
# only applies changes. Intended to be run as the account root user from AWS
# CloudShell (no root access keys needed).
#
# Usage: scripts/deploy.sh [--yes] <config.json> [stack-key ...]
#   --yes        skip the confirmation prompt (same as AUTO_APPROVE=1)
#   stack-key    deploy only these stacks (e.g. network-nat); default is all.
#                Keys: see STACK_KEYS in scripts/lib/common.sh.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if [[ "${1:-}" == "--yes" ]]; then AUTO_APPROVE=1; shift; fi
[[ $# -ge 1 ]] || die "Usage: $0 [--yes] <config.json> [stack-key ...]"

require_tools aws jq
load_config "$1"; shift

SELECTED=("$@")
for key in "${SELECTED[@]+"${SELECTED[@]}"}"; do
  is_known_stack "$key" || die "Unknown stack key '$key'. Valid keys: ${STACK_KEYS[*]}"
done

selected() {
  [[ ${#SELECTED[@]} -eq 0 ]] && return 0
  local key
  for key in "${SELECTED[@]}"; do [[ "$key" == "$1" ]] && return 0; done
  return 1
}

# Stack-level tags propagate to every taggable resource. ManagedBy is what the
# guardrails boundary uses to protect foundation resources from the deployer.
TAG_ARGS=("ManagedBy=${PREFIX}-foundation")
while IFS= read -r tag; do
  [[ -n "$tag" ]] && TAG_ARGS+=("$tag")
done < <(jq -r '(.tags // {}) | to_entries[] | "\(.key)=\(.value)"' "$CONFIG")

# deploy_stack <key> <template> [Param=Value ...]
deploy_stack() {
  local key="$1" template="$2"; shift 2
  local name; name="$(stack_name "$key")"
  selected "$key" || return 0

  log "Deploying $name ($template)"
  aws cloudformation deploy \
    --region "$REGION" \
    --stack-name "$name" \
    --template-file "$ROOT_DIR/templates/$template" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --tags "${TAG_ARGS[@]}" \
    --parameter-overrides "StackPrefix=$PREFIX" "$@"

  aws cloudformation update-termination-protection --region "$REGION" \
    --stack-name "$name" --enable-termination-protection >/dev/null
}

# optional_param <Name> <value>: emit "Name=value" only when value is non-empty,
# so the template default (usually "feature off") applies otherwise.
optional_param() { [[ -n "$2" ]] && echo "$1=$2" || true; }

ssm() { echo "/${PREFIX}/$1"; }

print_identity
if [[ "$CALLER_ARN" != *":root" ]]; then
  warn "You are not the root user. The foundation stacks are meant to be deployed by root;"
  warn "the deployer role is explicitly denied from managing ${PREFIX}-* stacks."
fi
log "Stacks: ${SELECTED[*]:-all}"
confirm "Proceed with deployment? [y/N]" "y"

# ------------------------------------------------------------------- IAM
ALLOWED_REGIONS="$(cfg_list .allowedRegions)"
ALLOWED_SOURCE_IPS="$(cfg_list .iam.allowedSourceIps)"

deploy_stack iam-guardrails-boundary iam/guardrails-boundary.yaml \
  "DeployerUserName=$DEPLOYER_USER" \
  "DeployerRoleName=$DEPLOYER_ROLE" \
  $(optional_param AllowedRegions "$ALLOWED_REGIONS")

deploy_stack iam-deployer-user iam/deployer-user.yaml \
  "DeployerUserName=$DEPLOYER_USER" \
  "DeployerRoleName=$DEPLOYER_ROLE" \
  "GuardrailsBoundaryArn=$(ssm iam/guardrails-boundary/arn)"

deploy_stack iam-deployer-role iam/deployer-role.yaml \
  "DeployerRoleName=$DEPLOYER_ROLE" \
  "DeployerUserArn=$(ssm iam/deployer-user/arn)" \
  "GuardrailsBoundaryArn=$(ssm iam/guardrails-boundary/arn)" \
  $(optional_param MaxSessionDuration "$(cfg .iam.maxSessionDurationSeconds)") \
  $(optional_param AllowedSourceIps "$ALLOWED_SOURCE_IPS")

# --------------------------------------------------------------- network
deploy_stack network-vpc network/vpc.yaml \
  "VpcCidr=$(cfg .network.vpcCidr)" \
  $(optional_param FlowLogRetentionDays "$(cfg .network.flowLogRetentionDays)")

for tier in public private data; do
  extra=()
  if [[ "$tier" == "data" ]]; then
    extra=("PeerCidrA=$(cfg .network.tiers.private.cidrA)"
           "PeerCidrB=$(cfg .network.tiers.private.cidrB)")
  fi
  deploy_stack "network-tier-$tier" network/subnet-tier.yaml \
    "TierName=$tier" \
    "VpcId=$(ssm network/vpc/id)" \
    "InternetGatewayId=$(ssm network/igw/id)" \
    "CidrA=$(cfg ".network.tiers.$tier.cidrA")" \
    "CidrB=$(cfg ".network.tiers.$tier.cidrB")" \
    "${extra[@]+"${extra[@]}"}"
done

if [[ "$NAT_MODE" == "none" ]]; then
  if selected network-nat; then
    log "natMode is 'none': removing the NAT stack if present (private tier loses internet egress)."
    delete_stack "$(stack_name network-nat)"
  fi
else
  deploy_stack network-nat network/nat.yaml \
    "NatMode=$NAT_MODE" \
    "PublicSubnetAId=$(ssm network/subnets/public/a/id)" \
    "PublicSubnetBId=$(ssm network/subnets/public/b/id)" \
    "PrivateRouteTableAId=$(ssm network/route-tables/private/a/id)" \
    "PrivateRouteTableBId=$(ssm network/route-tables/private/b/id)"
fi

deploy_stack network-endpoints network/endpoints.yaml \
  "VpcId=$(ssm network/vpc/id)" \
  "PrivateRouteTableAId=$(ssm network/route-tables/private/a/id)" \
  "PrivateRouteTableBId=$(ssm network/route-tables/private/b/id)"

log "Done."
