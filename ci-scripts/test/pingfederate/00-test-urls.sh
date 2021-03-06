#!/bin/bash

SCRIPT_HOME=$(cd $(dirname ${0}); pwd)
. "${SCRIPT_HOME}"/../../common.sh "${1}"

if skipTest "${0}"; then
  log "Skipping test ${0}"
  exit 0
fi

testUrl ${PINGFEDERATE_CONSOLE} ${PINGFEDERATE_API} ${PINGFEDERATE_OAUTH_PLAYGROUND}
exit ${?}