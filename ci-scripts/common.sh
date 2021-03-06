#!/bin/bash

##################################################################
# Common variables
##################################################################

test "${VERBOSE}" && set -x

# Override environment variables with optional file supplied from the outside
ENV_VARS_FILE="${1}"

if test -z "${ENV_VARS_FILE}"; then
  echo "Using environment variables based on CI variables"

  export REGION="${AWS_DEFAULT_REGION}"
  export CLUSTER_NAME="${EKS_CLUSTER_NAME}"
  export TENANT_DOMAIN='ci-cd.ping-oasis.com'

  [[ ${CI_COMMIT_REF_SLUG} != master ]] && export ENVIRONMENT=-${CI_COMMIT_REF_SLUG}
  export NAMESPACE=ping-cloud-${CI_COMMIT_REF_SLUG}

  export CONFIG_PARENT_DIR=aws
  export CONFIG_REPO_BRANCH=${CI_COMMIT_REF_NAME}

  export ARTIFACT_REPO_URL=s3://${CLUSTER_NAME}-artifacts-bucket
  export PING_ARTIFACT_REPO_URL=https://ping-artifacts.s3-us-west-2.amazonaws.com
  export LOG_ARCHIVE_URL=s3://${CLUSTER_NAME}-logs-bucket
  export BACKUP_URL=s3://${CLUSTER_NAME}-backup-bucket

  export PROJECT_DIR="${CI_PROJECT_DIR}"
  export AWS_PROFILE=csg
elif test -f "${ENV_VARS_FILE}"; then
  echo "Using environment variables defined in file ${ENV_VARS_FILE}"
  source "${ENV_VARS_FILE}"
else
  echo "ENV_VARS_FILE points to a non-existent file: ${ENV_VARS_FILE}"
  exit 1
fi

export LOG_SYNC_SECONDS="${LOG_SYNC_SECONDS:-5}"
export CURL_TIMEOUT_SECONDS="${CURL_TIMEOUT_SECONDS:-450}"

export ADMIN_USER=administrator
export ADMIN_PASS=2FederateM0re

export CLUSTER_NAME_LC=$(echo "${CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]')
export LOG_GROUP_NAME="/aws/containerinsights/${CLUSTER_NAME}/application"

FQDN=${ENVIRONMENT}.${TENANT_DOMAIN}

# Common
LOGS_CONSOLE=https://logs-${CLUSTER_NAME_LC}.${TENANT_DOMAIN}

# Monitoring
PROMETHEUS=https://prometheus-${CLUSTER_NAME_LC}.${TENANT_DOMAIN}
GRAFANA=https://monitoring-${CLUSTER_NAME_LC}.${TENANT_DOMAIN}

# Pingdirectory
PINGDIRECTORY_CONSOLE=https://pingdataconsole${FQDN}/console
PINGDIRECTORY_ADMIN=pingdirectory-admin${FQDN}

# Pingfederate
# admin services:
PINGFEDERATE_CONSOLE=https://pingfederate-admin${FQDN}/pingfederate/app
PINGFEDERATE_API=https://pingfederate-admin${FQDN}/pingfederate/app/pf-admin-api/api-docs

# runtime services:
PINGFEDERATE_AUTH_ENDPOINT=https://pingfederate${FQDN}
PINGFEDERATE_OAUTH_PLAYGROUND=https://pingfederate${FQDN}/OAuthPlayground

# Pingaccess
# admin services:
PINGACCESS_CONSOLE=https://pingaccess-admin${FQDN}
PINGACCESS_SWAGGER=https://pingaccess-admin${FQDN}/pa-admin-api/api-docs
PINGACCESS_API=https://pingaccess-admin${FQDN}/pa-admin-api/v3

# runtime services:
PINGACCESS_RUNTIME=https://pingaccess${FQDN}
PINGACCESS_AGENT=https://pingaccess-agent${FQDN}

# Source some utility methods.
. ${PROJECT_DIR}/utils.sh

########################################################################################################################
# Configures kubectl to be able to talk to the Kubernetes API server based on the following environment variables:
#
#   - KUBE_CA_PEM
#   - KUBE_URL
#   - EKS_CLUSTER_NAME
#   - AWS_ACCOUNT_ROLE_ARN
#
# If the environment variables are not present, then the function will exit with a non-zero return code.
########################################################################################################################
configure_kube() {
  if test -n "${SKIP_CONFIGURE_KUBE}"; then
    log "Skipping KUBE configuration"
    return
  fi

  check_env_vars "KUBE_CA_PEM" "KUBE_URL" "EKS_CLUSTER_NAME" "AWS_ACCOUNT_ROLE_ARN"
  HAS_REQUIRED_VARS=${?}

  if test ${HAS_REQUIRED_VARS} -ne 0; then
    exit 1
  fi

  log "Configuring KUBE"
  echo "${KUBE_CA_PEM}" > "$(pwd)/kube.ca.pem"

  kubectl config set-cluster "${EKS_CLUSTER_NAME}" \
    --server="${KUBE_URL}" \
    --certificate-authority="$(pwd)/kube.ca.pem"

  kubectl config set-credentials aws \
    --exec-command aws-iam-authenticator \
    --exec-api-version client.authentication.k8s.io/v1alpha1 \
    --exec-arg=token \
    --exec-arg=-i --exec-arg="${EKS_CLUSTER_NAME}" \
    --exec-arg=-r --exec-arg="${AWS_ACCOUNT_ROLE_ARN}"

  kubectl config set-context "${EKS_CLUSTER_NAME}" \
    --cluster="${EKS_CLUSTER_NAME}" \
    --user=aws

  kubectl config use-context "${EKS_CLUSTER_NAME}"
}

########################################################################################################################
# Configures the aws CLI to be able to talk to the AWS API server based on the following environment variables:
#
#   - AWS_ACCESS_KEY_ID
#   - AWS_SECRET_ACCESS_KEY
#   - AWS_DEFAULT_REGION
#   - AWS_ACCOUNT_ROLE_ARN
#
# If the environment variables are not present, then the function will exit with a non-zero return code. The AWS config
# and credentials file will be set up with a profile of ${AWS_PROFILE} environment variable defined in the common.sh
# file.
########################################################################################################################
configure_aws() {
  if test -n "${SKIP_CONFIGURE_AWS}"; then
    log "Skipping AWS CLI configuration"
    return
  fi

  check_env_vars "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_DEFAULT_REGION" "AWS_ACCOUNT_ROLE_ARN"
  HAS_REQUIRED_VARS=${?}

  if test ${HAS_REQUIRED_VARS} -ne 0; then
    exit 1
  fi

  log "Configuring AWS CLI"
  mkdir -p ~/.aws

  cat > ~/.aws/config <<EOF
  [default]
  output = json

  [profile ${AWS_PROFILE}]
  output = json
  region = ${AWS_DEFAULT_REGION}
  source_profile = default
  role_arn = ${AWS_ACCOUNT_ROLE_ARN}
EOF

  cat > ~/.aws/credentials <<EOF
  [default]
  aws_access_key_id = ${AWS_ACCESS_KEY_ID}
  aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}

  [${AWS_PROFILE}]
  role_arn = ${AWS_ACCOUNT_ROLE_ARN}
EOF
}

########################################################################################################################
# Wait for the expected count of a resource until the specified timeout.
#
# Arguments
#   ${1} -> The expected count of the resource.
#   ${2} -> The command to get the actual count of the resource. The execution of the command is expected to return
#           a number.
#   ${3} -> Wait timeout in seconds. Default is 2 minutes.
########################################################################################################################
wait_for_expected_resource_count() {
  EXPECTED=${1}
  COMMAND=${2}
  TIMEOUT_SECONDS=${3:-120}

  TIME_WAITED_SECONDS=0
  SLEEP_SECONDS=5

  while true; do
    ACTUAL=$(eval "${COMMAND}")
    if test ! -z "${ACTUAL}" && test "${ACTUAL}" -eq "${EXPECTED}"; then
      break
    fi

    sleep "${SLEEP_SECONDS}"
    TIME_WAITED_SECONDS=$((TIME_WAITED_SECONDS + SLEEP_SECONDS))

    if test "${TIME_WAITED_SECONDS}" -ge "${TIMEOUT_SECONDS}"; then
      echo "Expected count ${EXPECTED} but found ${ACTUAL} after ${TIMEOUT_SECONDS} seconds"
      return 1
    fi
  done

  return 0
}

########################################################################################################################
# Determine whether to skip the tests in the file with the provided name. If the SKIP_TESTS environment variable is set
# and contains the name of the file with its parent directory, then that test file will be skipped. For example, to
# skip the PingDirectory tests in files 03-backup-restore.sh and 20-pd-recovery-on-delete-pv.sh, set SKIP_TESTS to
# 'pingdirectory/03-backup-restore.sh chaos/20-pd-recovery-on-delete-pv.sh'.
#
# Arguments
#   ${1} -> The fully-qualified name of the test file.
#
# Returns
#   0 -> if the test should be skipped; 1 -> if the test should not be skipped.
########################################################################################################################
skipTest() {
  test -z "${SKIP_TESTS}" && return 1

  local test_file="${1}"

  readonly dir_name=$(basename "$(dirname "${test_file}")")
  readonly file_name=$(basename "${test_file}")
  readonly test_file_short_name="${dir_name}/${file_name}"

  echo "${SKIP_TESTS}" | grep -q "${test_file_short_name}" &> /dev/null

  if test $? -eq 0; then
    log "SKIP_TESTS is set to skip test file: ${test_file_short_name}"
    return 0
  fi

  return 1
}

########################################################################################################################
# Search for password regex pattern within log file.
#
# Arguments
#   ${1} -> Name of server
#   ${2} -> Regex pattern of all passwords used within server
#   ${3} -> Temp file used to store logs
#
# Returns
#   0 -> If product password is not found in logs; 1 -> If password was found in logs
########################################################################################################################
check_for_password_in_logs() {
  set +x
  local server="${1}"
  local pattern="${2}"
  local log_file=${3}

  # Search for password within logs
  local result=$( cat ${log_file} | grep "${pattern}" )

  test -z "${result}" && return 0
  set -x

  # Password found
  log "${server}: password(s) found in log file.
    1) You must resolve this issue. 
    2) Change all existing passwords. 
    3) Rerun test"
  return 1
}

########################################################################################################################
# Get last 60min logs from server and write its output to temp file.
#
# Arguments
#   ${1} -> Name of server
#   ${2} -> Name of pod container
#   ${3} -> Temp file used to store logs
#
########################################################################################################################
set_log_file() {
  local server="${1}"
  local container="${2}"
  local log_file=${3}

  kubectl logs -n "${NAMESPACE}" "${server}" -c "${container}" --since=60m > ${log_file}
}

########################################################################################################################
# Compares a sample of logs within Kubernetes and AWS CloudWatch
#
# Arguments
#   ${1} -> Name of log stream within CloudWatch
#   ${2} -> Full pathname to log file within the container
#   ${3} -> Name of pod
#   ${4} -> Name of container within pod
#   ${5} -> Existence of any value specifies to inverse grep to look for all logs that do not match ${2}.
#           This is used for default log stream in each product
#
# Returns
#   0 -> If all logs present within Kubernetes are also present within CloudWatch
#   1 -> If a log entry within Kubernetes does not appear within CloudWatch
########################################################################################################################
function log_events_exist() {
  local log_stream=$1
  local full_pathname=$2
  local pod=$3
  local container=$4
  local inverse=
  if [ -n "$5" ]; then
    inverse="-v "
  fi
  local grep_args="${inverse}^${full_pathname}"
  local temp_log_file=$(mktemp)
  local cwatch_log_events=

  # Save current state of logs into a temp file
  kubectl logs "${pod}" -c "${container}" -n "${NAMESPACE}" |
    grep $grep_args |
    tail -100 |
    # remove all ansi escape sequences, remove all '\' and '-', remove '\r'
    sed -E 's/'"$(printf '\x1b')"'\[(([0-9]+)(;[0-9]+)*)?[m,K,H,f,J]//g' |
    sed -E 's/\\//g' |
    sed -E 's/-//g' |
    tr -d '\r' > "${temp_log_file}"

  # Let the aws logs catch up to the kubectl logs in temp file
  sleep "${LOG_SYNC_SECONDS}"

  cwatch_log_events=$(aws logs --profile "${AWS_PROFILE}" get-log-events \
    --log-group-name "${LOG_GROUP_NAME}" \
    --log-stream-name "${log_stream}" \
    --no-start-from-head --limit 150 |
    # Replace groups of 3 and 2 '\' with 1 '\', remove '\r', '\n', replace '\t' with tab spaces,
    # remove all ansi escape sequences, remove all '\' and '-'
    sed -E 's/\\{3,}/\\/g' |
    sed -E 's/\\{1,}/\\/g' |
    sed -E 's/\\r//g' |
    sed -E 's/\\n//g' |
    sed -E 's/\\t/'"$(printf '\t')"'/g' |
    sed -E 's/\\u001B\[(([0-9]+)(;[0-9]+)*)?[m,K,H,f,J]//g' |
    sed -E 's/\\//g' |
    sed -E 's/-//g')

  while read -r event; do
    count=$(echo "${cwatch_log_events}" | grep -Fc "${event}")
    if test "${count}" -lt 1; then
      echo "Event not found: "
      echo "${event}"
      rm "${temp_log_file}"
      return 1
    fi
  done< <(cat "${temp_log_file}")
  rm "${temp_log_file}"
  return 0
}

########################################################################################################################
# Checks for existence of a particular log stream within AWS CloudWatch
#
# Arguments
#   ${1} -> Name of log stream within CloudWatch
#
# Returns
#   0 -> If log stream is present within CloudWatch
#   1 -> If log stream is not present within CloudWatch
########################################################################################################################
function log_streams_exist() {
  local log_stream_prefixes=$1
  for log in ${log_stream_prefixes}; do
    log_stream_count=$(aws logs --profile "${AWS_PROFILE}" describe-log-streams \
      --log-group-name "${LOG_GROUP_NAME}" \
      --log-stream-name-prefix "${log}" | jq '.logStreams | length')
    if test "${log_stream_count}" -lt 1; then
      echo "Log stream with prefix '$log' not found in CloudWatch"
      return 1
    fi
  done
  return 0
}
