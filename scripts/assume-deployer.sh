#!/usr/bin/env bash
# Exchanges the deployer user's access key for short-lived deployer role
# credentials and prints them as shell exports.
#
# Usage: eval "$(scripts/assume-deployer.sh <config.json> [source-profile])"
#   source-profile   AWS CLI profile holding the deployer user's access key.
#                    Defaults to $AWS_PROFILE, then to the deployer user name.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

[[ $# -ge 1 ]] || die "Usage: eval \"\$($0 <config.json> [source-profile])\""

require_tools aws jq
load_config "$1"
SOURCE_PROFILE="${2:-${AWS_PROFILE:-$DEPLOYER_USER}}"

# Ignore any credentials already exported in this shell (e.g. a previous session).
aws_user() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    aws --profile "$SOURCE_PROFILE" --region "$REGION" "$@"
}

CALLER_ARN="$(aws_user sts get-caller-identity --query Arn --output text)" \
  || die "Could not authenticate with profile '$SOURCE_PROFILE'."
# arn:<partition>:iam::<account>:user/<name>
PARTITION="$(cut -d: -f2 <<<"$CALLER_ARN")"
ACCOUNT_ID="$(cut -d: -f5 <<<"$CALLER_ARN")"
ROLE_ARN="arn:${PARTITION}:iam::${ACCOUNT_ID}:role/${DEPLOYER_ROLE}"

DURATION="$(cfg .iam.maxSessionDurationSeconds)"
CREDS="$(aws_user sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "${DEPLOYER_USER}-$(date +%Y%m%d%H%M%S)" \
  --duration-seconds "${DURATION:-3600}" \
  --output json)"

log "Assumed $ROLE_ARN (expires $(jq -r .Credentials.Expiration <<<"$CREDS"))"

jq -r --arg region "$REGION" '
  .Credentials |
  "export AWS_ACCESS_KEY_ID=\(.AccessKeyId)",
  "export AWS_SECRET_ACCESS_KEY=\(.SecretAccessKey)",
  "export AWS_SESSION_TOKEN=\(.SessionToken)",
  "export AWS_REGION=\($region)",
  "export AWS_DEFAULT_REGION=\($region)",
  "unset AWS_PROFILE"
' <<<"$CREDS"
