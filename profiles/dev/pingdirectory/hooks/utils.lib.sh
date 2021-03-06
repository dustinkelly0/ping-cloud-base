#!/usr/bin/env sh

########################################################################################################################
# Function to install AWS command line tools
#
########################################################################################################################
function installAwsCliTools() {
  if test -z "$(which aws)"; then
    #   
    #  Install AWS platform specific tools
    #
    echo "Installing AWS CLI tools for S3 support"
    #
    # TODO: apk needs to move to the Docker file as the package manager is plaform specific
    #
    apk --update add python3
    pip3 install --no-cache-dir --upgrade pip
    pip3 install --no-cache-dir --upgrade awscli
  fi
}

########################################################################################################################
# Function calls installAwsCliTools() and sets required environment variables for AWS S3 bucket
#
########################################################################################################################
function initializeS3Configuration() {
  unset BUCKET_URL_NO_PROTOCOL
  unset BUCKET_NAME
  unset DIRECTORY_NAME
  unset TARGET_URL

  # Allow overriding the backup URL with an arg
  test ! -z "${1}" && BACKUP_URL="${1}"

  # Install AWS CLI if the upload location is S3
  if test "${BACKUP_URL#s3}" == "${BACKUP_URL}"; then
    echo "Upload location is not S3"
    exit 1
  else
    installAwsCliTools
  fi

  export BUCKET_URL_NO_PROTOCOL=${BACKUP_URL#s3://}
  export BUCKET_NAME=$(echo "${BUCKET_URL_NO_PROTOCOL}" | cut -d/ -f1)
  export DIRECTORY_NAME=$(echo "${PING_PRODUCT}" | tr '[:upper:]' '[:lower:]')

  if test "${BACKUP_URL}" == */"${DIRECTORY_NAME}"; then
    export TARGET_URL="${BACKUP_URL}"
  else
    export TARGET_URL="${BACKUP_URL}/${DIRECTORY_NAME}"
  fi
}