#!/usr/bin/env bash

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="$(cd "${TESTS_ROOT}/.." && pwd)"
REAL_PATH="$PATH"

# shellcheck source=lib/integrity.sh
source "${ARTIFACT_ROOT}/lib/integrity.sh"

SETUP_CODE="abcdefghijklmnopqrstuvwxyzABCDEFGH012345678"
ARTIFACT_COMMIT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TENANT_ID="20000000-0000-4000-8000-000000000002"
TARGET_PROJECT_ID="target-proj-1"
TARGET_PROJECT_NUMBER="123456789012"
BILLING_ACCOUNT_ID="ABCDEF-123456-ABCDEF"
BILLING_SOURCE_PROJECT_ID="billing-source-1"
BILLING_SOURCE_DATASET_ID="billing_export"
BILLING_QUERY_PROJECT_ID="billing-query-1"
POSTURE="read_scoped_optimize"

test_fail() {
  printf 'TEST FAILURE: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" ||
    test_fail "Expected ${file} to contain: ${expected}"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    test_fail "Expected ${file} not to contain: ${unexpected}"
  fi
}

assert_count() {
  local expected="$1"
  local pattern="$2"
  local file="$3"
  local actual
  actual="$(grep -Fc -- "$pattern" "$file" || true)"
  [[ "$actual" == "$expected" ]] ||
    test_fail "Expected ${expected} occurrences of ${pattern}; found ${actual}"
}

artifact_digest() {
  ROOT="$ARTIFACT_ROOT" bash -c '
    source "$ROOT/lib/runtime.sh"
    source "$ROOT/lib/integrity.sh"
    compute_artifact_digest
  '
}

configure_binding() {
  local binding_id="$1"
  local binding_compact="${binding_id//-/}"
  local tenant_digest
  tenant_digest="$(printf '%s' "$TENANT_ID" | hash_stream)"
  export MOCK_BINDING_ID="$binding_id"
  export MOCK_POOL_ID="kc-${tenant_digest:0:20}"
  export MOCK_PROVIDER_ID="kc-${binding_compact:0:24}"
  export MOCK_SERVICE_ACCOUNT_EMAIL=
  MOCK_SERVICE_ACCOUNT_EMAIL="kc-${binding_compact:0:20}@${TARGET_PROJECT_ID}.iam.gserviceaccount.com"
  export MOCK_VIEW_DATASET_ID="kc_billing_${binding_compact:0:16}"
}

begin_case() {
  local case_name="$1"
  MOCK_STATE_DIR="${TEST_TEMP}/${case_name}"
  mkdir -p "$MOCK_STATE_DIR"
  export MOCK_STATE_DIR ARTIFACT_ROOT
  export MOCK_REPOSITORY_ROOT="$ARTIFACT_ROOT"
  export MOCK_GIT_HEAD="$ARTIFACT_COMMIT"
  export MOCK_GIT_BRANCH="release-${ARTIFACT_COMMIT}"
  export MOCK_GIT_ORIGIN=
  MOCK_GIT_ORIGIN="https://github.com/KlipoCloud/klipocloud-gcp-guided-setup.git"
  export MOCK_GIT_DIRTY=""
  export MOCK_ARTIFACT_DIGEST
  MOCK_ARTIFACT_DIGEST="$(artifact_digest)"
  export MOCK_CONTEXT_ARTIFACT_DIGEST="$MOCK_ARTIFACT_DIGEST"
  export MOCK_TENANT_ID="$TENANT_ID"
  export MOCK_TARGET_PROJECT_ID="$TARGET_PROJECT_ID"
  export MOCK_TARGET_PROJECT_NUMBER="$TARGET_PROJECT_NUMBER"
  export MOCK_BILLING_LOCATION="US"
  export MOCK_POSTURE="$POSTURE"
  export MOCK_UNAUTHENTICATED=0
  export MOCK_REGISTRATION_TRANSPORT_FAILURES=0
  export MOCK_REGISTRATION_HTTP_STATUS=202
  export TARGET_PROJECT_ID TARGET_PROJECT_NUMBER BILLING_ACCOUNT_ID
  export BILLING_SOURCE_PROJECT_ID BILLING_SOURCE_DATASET_ID
  export BILLING_QUERY_PROJECT_ID
  export PATH="${TESTS_ROOT}/mocks:${REAL_PATH}"
  configure_binding "30000000-0000-4000-8000-000000000003"
  jq -n '{access: [{role: "READER", groupByEmail: "finance@example.com"}]}' \
    > "${MOCK_STATE_DIR}/source-dataset.json"
}

setup_input() {
  printf '%s\n' \
    "$SETUP_CODE" \
    "$TARGET_PROJECT_ID" \
    "$BILLING_ACCOUNT_ID" \
    "$BILLING_SOURCE_PROJECT_ID" \
    "$BILLING_SOURCE_DATASET_ID" \
    "$BILLING_QUERY_PROJECT_ID" \
    "$TARGET_PROJECT_ID"
}

run_setup() {
  local output_file="$1"
  setup_input | "$ARTIFACT_ROOT/setup.sh" > "$output_file" 2>&1
}

run_setup_expect_failure() {
  local output_file="$1"
  local input="${2:-}"
  if printf '%s' "$input" | "$ARTIFACT_ROOT/setup.sh" > "$output_file" 2>&1; then
    test_fail "Expected setup to fail"
  fi
  [[ ! -s "${MOCK_STATE_DIR}/mutations.log" ]] ||
    test_fail "Setup mutated mock cloud state before rejecting invalid input"
}
