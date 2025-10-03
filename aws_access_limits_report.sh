#!/usr/bin/env bash

set -euo pipefail

# aws_access_limits_report.sh
# Gathers a proof bundle of:
# - Current caller identity and account alias
# - Active principal (user/role) with attached/inline policies and groups
# - Targeted permission simulation for critical actions
# - Service Quotas for selected services across specified regions

if ! command -v aws >/dev/null 2>&1; then
  echo "[ERROR] aws CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[ERROR] jq not found. Install: https://stedolan.github.io/jq/ or 'brew install jq' on macOS" >&2
  exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="aws_access_report_${timestamp}"
mkdir -p "${OUT_DIR}"

echo "[INFO] Writing output to: ${OUT_DIR}" | tee "${OUT_DIR}/_log.txt"

regions=("${@}")
if [ ${#regions[@]} -eq 0 ]; then
  # Default to current env AWS_REGION or us-east-1
  default_region="${AWS_REGION:-us-east-1}"
  regions=("${default_region}")
fi

echo "[INFO] Regions: ${regions[*]}" | tee -a "${OUT_DIR}/_log.txt"

echo "[STEP] STS get-caller-identity" | tee -a "${OUT_DIR}/_log.txt"
aws sts get-caller-identity > "${OUT_DIR}/sts_get_caller_identity.json"

account_id="$(jq -r '.Account' "${OUT_DIR}/sts_get_caller_identity.json")"
caller_arn="$(jq -r '.Arn' "${OUT_DIR}/sts_get_caller_identity.json")"

echo "[INFO] Account ID: ${account_id}" | tee -a "${OUT_DIR}/_log.txt"
echo "[INFO] Caller ARN: ${caller_arn}" | tee -a "${OUT_DIR}/_log.txt"

echo "[STEP] IAM list-account-aliases" | tee -a "${OUT_DIR}/_log.txt"
aws iam list-account-aliases > "${OUT_DIR}/iam_list_account_aliases.json"

# Determine principal type and canonical IAM principal ARN for simulation
principal_type="unknown"
principal_name=""
simulation_principal_arn=""

if [[ "${caller_arn}" == arn:aws:iam::*:user/* ]]; then
  principal_type="user"
  principal_name="${caller_arn##*/}"
  simulation_principal_arn="${caller_arn}"
elif [[ "${caller_arn}" == arn:aws:sts::*:assumed-role/* ]]; then
  principal_type="role"
  # arn:aws:sts::ACCOUNT_ID:assumed-role/RoleName/SessionName
  role_part="${caller_arn#*:assumed-role/}"
  role_name="${role_part%%/*}"
  principal_name="${role_name}"
  simulation_principal_arn="arn:aws:iam::${account_id}:role/${role_name}"
elif [[ "${caller_arn}" == arn:aws:iam::*:role/* ]]; then
  principal_type="role"
  principal_name="${caller_arn##*/}"
  simulation_principal_arn="${caller_arn}"
fi

echo "[INFO] Principal type: ${principal_type}" | tee -a "${OUT_DIR}/_log.txt"
echo "[INFO] Principal name: ${principal_name}" | tee -a "${OUT_DIR}/_log.txt"
echo "[INFO] Simulation principal ARN: ${simulation_principal_arn}" | tee -a "${OUT_DIR}/_log.txt"

echo "[STEP] Dump principal details" | tee -a "${OUT_DIR}/_log.txt"
case "${principal_type}" in
  user)
    aws iam get-user --user-name "${principal_name}" > "${OUT_DIR}/iam_get_user.json"
    aws iam list-attached-user-policies --user-name "${principal_name}" > "${OUT_DIR}/iam_list_attached_user_policies.json"
    aws iam list-user-policies --user-name "${principal_name}" > "${OUT_DIR}/iam_list_user_policies.json"
    aws iam list-groups-for-user --user-name "${principal_name}" > "${OUT_DIR}/iam_list_groups_for_user.json"
    ;;
  role)
    aws iam get-role --role-name "${principal_name}" > "${OUT_DIR}/iam_get_role.json"
    aws iam list-attached-role-policies --role-name "${principal_name}" > "${OUT_DIR}/iam_list_attached_role_policies.json"
    aws iam list-role-policies --role-name "${principal_name}" > "${OUT_DIR}/iam_list_role_policies.json"
    ;;
  *)
    echo "[WARN] Unknown principal type; skipping entity-specific dumps" | tee -a "${OUT_DIR}/_log.txt"
    ;;
esac

# Targeted permission simulation for a set of critical actions
echo "[STEP] IAM simulate-principal-policy (targeted actions)" | tee -a "${OUT_DIR}/_log.txt"

read -r -d '' ACTIONS_JSON <<'JSON'
[
  "ec2:RunInstances",
  "ec2:TerminateInstances",
  "ec2:DescribeInstances",
  "ec2:CreateTags",
  "ec2:CreateVpc",
  "ec2:CreateVolume",
  "s3:CreateBucket",
  "s3:ListBucket",
  "s3:GetObject",
  "s3:PutObject",
  "s3:DeleteObject",
  "iam:PassRole",
  "iam:CreateUser",
  "iam:CreatePolicy",
  "iam:AttachRolePolicy",
  "iam:UpdateAssumeRolePolicy",
  "lambda:CreateFunction",
  "lambda:UpdateFunctionCode",
  "lambda:InvokeFunction",
  "rds:CreateDBInstance",
  "rds:DeleteDBInstance",
  "eks:CreateCluster",
  "ecs:CreateCluster",
  "ecr:CreateRepository"
]
JSON

echo "${ACTIONS_JSON}" > "${OUT_DIR}/actions_to_simulate.json"

if [ -n "${simulation_principal_arn}" ]; then
  # shellcheck disable=SC2046
  aws iam simulate-principal-policy \
    --policy-source-arn "${simulation_principal_arn}" \
    --action-names $(jq -r '.[]' "${OUT_DIR}/actions_to_simulate.json" | xargs) \
    > "${OUT_DIR}/iam_simulate_principal_policy.json"
else
  echo "[WARN] No simulation principal ARN; skipping simulation" | tee -a "${OUT_DIR}/_log.txt"
fi

# Dump full account IAM auth details (can be large)
echo "[STEP] IAM get-account-authorization-details (may take time)" | tee -a "${OUT_DIR}/_log.txt"
aws iam get-account-authorization-details > "${OUT_DIR}/iam_account_authorization_details.json"

# Service Quotas for selected services across regions
services=(
  ec2
  lambda
  rds
  elasticloadbalancing
  ecr
  ecs
  eks
  cloudwatch
  logs
  events
  sqs
  sns
  states
)

for region in "${regions[@]}"; do
  echo "[STEP] Service Quotas in ${region}" | tee -a "${OUT_DIR}/_log.txt"
  region_dir="${OUT_DIR}/service_quotas_${region}"
  mkdir -p "${region_dir}"

  for svc in "${services[@]}"; do
    echo "  - ${svc}" | tee -a "${OUT_DIR}/_log.txt"
    aws service-quotas list-service-quotas \
      --region "${region}" \
      --service-code "${svc}" \
      > "${region_dir}/${svc}_list_service_quotas.json" || true

    aws service-quotas list-aws-default-service-quotas \
      --region "${region}" \
      --service-code "${svc}" \
      > "${region_dir}/${svc}_list_default_service_quotas.json" || true
  done
done

# Optional: collect recent AccessDenied events from CloudTrail (if Lake/Event data available)
echo "[STEP] Attempting to query recent AccessDenied events (optional)" | tee -a "${OUT_DIR}/_log.txt"
for region in "${regions[@]}"; do
  ct_dir="${OUT_DIR}/cloudtrail_${region}"
  mkdir -p "${ct_dir}"
  # This uses CloudTrail Lake if available; ignore errors otherwise
  start_time_iso="$(date -u -v-7d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '7 days ago' '+%Y-%m-%dT%H:%M:%SZ')"
  end_time_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  query='SELECT eventTime, eventSource, eventName, errorCode, errorMessage, userIdentity.type, userIdentity.arn FROM aws_cloudtrail_events WHERE errorCode LIKE "%AccessDenied%" AND eventTime BETWEEN "${start}" AND "${end}" ORDER BY eventTime DESC LIMIT 200'
  # Try to run against default event data store if configured
  if aws --region "${region}" cloudtrail list-event-data-stores >/dev/null 2>&1; then
    ds_arn="$(aws --region "${region}" cloudtrail list-event-data-stores | jq -r '.EventDataStores[0].EventDataStoreArn // empty')"
    if [ -n "${ds_arn}" ]; then
      qid="$(aws --region "${region}" cloudtrail start-query --event-data-store "${ds_arn}" --query-string "${query//\${start}/${start_time_iso}}" --query-string "${query//\${end}/${end_time_iso}}" 2>/dev/null | jq -r '.QueryId // empty' || true)"
      if [ -n "${qid}" ]; then
        # Poll briefly
        for i in {1..10}; do
          status="$(aws --region "${region}" cloudtrail get-query-results --query-id "${qid}" 2>/dev/null | jq -r '.QueryStatus // empty' || true)"
          if [ "${status}" = "FINISHED" ]; then
            aws --region "${region}" cloudtrail get-query-results --query-id "${qid}" > "${ct_dir}/access_denied_events.json" || true
            break
          fi
          sleep 2
        done
      fi
    fi
  fi
done

# Write a short README for the bundle
cat > "${OUT_DIR}/README.txt" <<README
AWS Access Limits Proof Bundle
Generated: ${timestamp}
Profile: \
  AWS_PROFILE=${AWS_PROFILE:-default} (shell env at runtime)
Regions: ${regions[*]}

Contents:
  - sts_get_caller_identity.json: Proof of current account and caller ARN
  - iam_list_account_aliases.json: Account alias(es)
  - iam_get_user.json / iam_get_role.json: Active principal details
  - iam_list_attached_*_policies.json, iam_list_*_policies.json, iam_list_groups_for_user.json: Attached/inline policies and groups
  - actions_to_simulate.json: Critical actions used for permission simulation
  - iam_simulate_principal_policy.json: Allowed/explicitly denied results for targeted actions
  - iam_account_authorization_details.json: Full IAM entities and policies snapshot (large)
  - service_quotas_<region>/...: Tracked and default Service Quotas per selected services
  - cloudtrail_<region>/access_denied_events.json: Recent AccessDenied events if CloudTrail Lake is available

Notes:
  - Service Quotas only include quotas tracked by the Service Quotas API. Some services have limits not surfaced here.
  - Permission simulation evaluates the specified actions for the active IAM principal; refine the action set as needed.
README

echo "[DONE] Bundle created at: ${OUT_DIR}" | tee -a "${OUT_DIR}/_log.txt"
echo "[HINT] To archive: tar -czf ${OUT_DIR}.tar.gz ${OUT_DIR}" | tee -a "${OUT_DIR}/_log.txt"


