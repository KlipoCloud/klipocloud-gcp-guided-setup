#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-support.sh
source "${ROOT}/test-support.sh"

TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/kc-gcp-artifact-tests.XXXXXX")"
trap 'rm -rf "$TEST_TEMP"' EXIT INT TERM

test_release_rejections() {
  local output

  begin_case invalid-origin
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_GIT_ORIGIN="https://github.com/example/fork.git"
  run_setup_expect_failure "$output"
  assert_contains "$output" "Artifact origin is not the approved KlipoCloud repository"

  begin_case dirty-checkout
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_GIT_DIRTY=" M setup.sh"
  run_setup_expect_failure "$output"
  assert_contains "$output" "Artifact checkout contains local changes"

  begin_case moving-branch
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_GIT_BRANCH="main"
  run_setup_expect_failure "$output"
  assert_contains "$output" "Release branch does not pin the checked-out artifact commit"

  begin_case bare-commit-branch
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_GIT_BRANCH="$ARTIFACT_COMMIT"
  run_setup_expect_failure "$output"
  assert_contains "$output" "Release branch does not pin the checked-out artifact commit"

  begin_case malformed-head
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_GIT_HEAD="not-a-commit"
  run_setup_expect_failure "$output"
  assert_contains "$output" "Invalid artifact commit"

  begin_case digest-mismatch
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_CONTEXT_ARTIFACT_DIGEST
  MOCK_CONTEXT_ARTIFACT_DIGEST="$(printf 'b%.0s' {1..64})"
  run_setup_expect_failure "$output" "${SETUP_CODE}"$'\n'
  assert_contains "$output" "Artifact digest does not match the intent"
}

test_digest_dependency() {
  local output
  begin_case missing-sha256-command
  output="${MOCK_STATE_DIR}/output.txt"
  if PATH="${TESTS_ROOT}/mocks" ROOT="$ARTIFACT_ROOT" /bin/bash -c '
    source "$ROOT/lib/runtime.sh"
    source "$ROOT/lib/integrity.sh"
    require_sha256_command
  ' >"$output" 2>&1; then
    test_fail "Missing SHA-256 tooling was accepted"
  fi
  assert_contains "$output" \
    "Required SHA-256 command is unavailable: install sha256sum or shasum"
}

test_authentication_guidance() {
  local output
  begin_case unauthenticated
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_UNAUTHENTICATED=1
  run_setup_expect_failure "$output" $'n\n'
  assert_contains "$output" "This temporary Cloud Shell has no active Google identity"
  assert_contains "$output" "Google authentication is required"
}

test_strict_tenant_id() {
  local output
  begin_case version-seven-tenant
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_TENANT_ID="20000000-0000-7000-8000-0000000000ab"
  run_setup_expect_failure "$output" "${SETUP_CODE}"$'\n'
  assert_contains "$output" "Invalid public tenant ID"

  begin_case nil-tenant
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_TENANT_ID="00000000-0000-0000-0000-000000000000"
  run_setup_expect_failure "$output" "${SETUP_CODE}"$'\n'
  assert_contains "$output" "Invalid public tenant ID"

  begin_case max-tenant
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_TENANT_ID="ffffffff-ffff-ffff-ffff-ffffffffffff"
  run_setup_expect_failure "$output" "${SETUP_CODE}"$'\n'
  assert_contains "$output" "Invalid public tenant ID"

  begin_case uppercase-tenant
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_TENANT_ID="20000000-0000-4000-8000-0000000000AB"
  run_setup_expect_failure "$output" "${SETUP_CODE}"$'\n'
  assert_contains "$output" "Invalid public tenant ID"
}

test_registration_retry_and_recovery() {
  local output input
  begin_case transient-registration
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_REGISTRATION_TRANSPORT_FAILURES=2
  run_setup "$output" || {
    cat "$output" >&2
    test_fail "Transient registration was not retried"
  }
  [[ "$(< "${MOCK_STATE_DIR}/registration-count")" == "3" ]] ||
    test_fail "Registration did not use the bounded transport retry budget"
  assert_count 2 "sleep" "${MOCK_STATE_DIR}/sleep.log"

  begin_case rejected-registration
  output="${MOCK_STATE_DIR}/output.txt"
  export MOCK_REGISTRATION_HTTP_STATUS=409
  input="$(setup_input)"$'\n'
  if printf '%s' "$input" | "$ARTIFACT_ROOT/setup.sh" > "$output" 2>&1; then
    test_fail "A definitive registration rejection was accepted"
  fi
  [[ "$(< "${MOCK_STATE_DIR}/registration-count")" == "1" ]] ||
    test_fail "A definitive registration rejection was retried"
  [[ ! -e "${MOCK_STATE_DIR}/sleep.log" ]] ||
    test_fail "A definitive registration rejection waited for a retry"
  assert_contains "$output" "KlipoCloud rejected the GCP registration"
  assert_contains "$output" "Setup stopped after cloud mutation began"
  assert_contains "$output" "Cleanup plan"
  assert_contains "$output" "service-accounts remove-iam-policy-binding"
  assert_not_contains "$output" "$SETUP_CODE"
}

assert_permission_preflight() {
  local combined="${MOCK_STATE_DIR}/permission-requests.json"
  jq -s '{endpoints: map(.endpoint), permissions: map(.permissions[]) | unique}' \
    "${MOCK_STATE_DIR}"/permission-request-*.json > "$combined"
  jq -e '
    (.endpoints | length) == 4 and
    any(.endpoints[]; contains("projects/target-proj-1:testIamPermissions")) and
    any(.endpoints[]; contains("projects/billing-query-1:testIamPermissions")) and
    any(.endpoints[]; contains("projects/billing-source-1:testIamPermissions")) and
    any(.endpoints[]; contains("billingAccounts/ABCDEF-123456-ABCDEF:testIamPermissions")) and
    (.permissions | index("iam.roles.list") != null) and
    (.permissions | index("bigquery.datasets.update") != null) and
    (.permissions | index("bigquery.datasets.setIamPolicy") != null) and
    (.permissions | index("bigquery.tables.getData") != null)
  ' "$combined" >/dev/null || test_fail "Operator permission preflight is incomplete"
}

assert_first_setup() {
  local output="$1"
  local registration="${MOCK_STATE_DIR}/registration-1.json"
  local commands="${MOCK_STATE_DIR}/commands.log"
  local mutations="${MOCK_STATE_DIR}/mutations.log"
  local view="${MOCK_STATE_DIR}/view-${MOCK_VIEW_DATASET_ID}.json"
  local expected_provider=
  expected_provider="projects/${TARGET_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${MOCK_POOL_ID}/providers/${MOCK_PROVIDER_ID}"

  jq -e --arg code "$SETUP_CODE" --arg provider "$expected_provider" \
    --arg service_account "$MOCK_SERVICE_ACCOUNT_EMAIL" '
      .setupCode == $code and
      .projectId == "target-proj-1" and
      .workloadIdentityProviderResourceName == $provider and
      .serviceAccountEmail == $service_account and
      .billingProjectId == "billing-query-1" and
      .billingScopedViewId == "project_costs"
    ' "$registration" >/dev/null || test_fail "Registration coordinates drifted"
  assert_not_contains "$output" "$SETUP_CODE"
  assert_not_contains "$commands" "$SETUP_CODE"
  assert_contains "$commands" "google.subject=assertion.sub"
  assert_contains "$commands" "assertion.connection_id"
  assert_contains "$commands" "roles/iam.workloadIdentityUser"
  assert_not_contains "$commands" "serviceAccountTokenCreator"
  assert_not_contains "$commands" "roles/owner"
  assert_not_contains "$commands" "roles/editor"
  assert_not_contains "$commands" "service-accounts keys"
  assert_contains "$commands" "roles/bigquery.metadataViewer"
  assert_contains "$commands" "roles/bigquery.dataViewer"
  assert_not_contains "$mutations" " remove-iam-policy-binding "
  assert_not_contains "$mutations" " providers delete "
  assert_not_contains "$mutations" "bq rm "
  assert_contains "$output" "KC_SOURCE_DATASET_FILE"
  assert_contains "$output" "The tenant pool is shared"
  jq -e --arg project "$BILLING_QUERY_PROJECT_ID" \
    --arg dataset "$MOCK_VIEW_DATASET_ID" '
      any(.access[]; .groupByEmail == "finance@example.com") and
      any(.access[]; .view.projectId == $project and
        .view.datasetId == $dataset and .view.tableId == "project_costs")
    ' "${MOCK_STATE_DIR}/source-dataset.json" >/dev/null ||
    test_fail "Source dataset ACL was not preserved and extended"
  jq -e --arg target "$TARGET_PROJECT_ID" '
      .type == "VIEW" and .view.useLegacySql == false and
      (.view.query | contains("WHERE project.id =")) and
      (.view.query | contains($target)) and
      (.view.query | contains("SELECT *") | not)
    ' "$view" >/dev/null || test_fail "Scoped billing view is not project-isolated"
  assert_permission_preflight
}

test_full_setup_rerun_and_replacement() {
  local output first_registration second_registration
  begin_case complete
  output="${MOCK_STATE_DIR}/first-output.txt"
  run_setup "$output" || {
    cat "$output" >&2
    test_fail "First complete setup failed"
  }
  assert_first_setup "$output"
  first_registration="${MOCK_STATE_DIR}/registration-1.json"

  output="${MOCK_STATE_DIR}/rerun-output.txt"
  run_setup "$output" || {
    cat "$output" >&2
    test_fail "Idempotent rerun failed"
  }
  second_registration="${MOCK_STATE_DIR}/registration-2.json"
  jq -s -e '.[0] == .[1]' "$first_registration" "$second_registration" \
    >/dev/null || test_fail "Rerun changed deterministic registration coordinates"
  assert_count 1 "bq mk --use_legacy_sql=false" \
    "${MOCK_STATE_DIR}/commands.log"
  assert_count 1 "bq update --update_mode=UPDATE_FULL --source" \
    "${MOCK_STATE_DIR}/commands.log"

  configure_binding "40000000-0000-4000-8000-000000000004"
  output="${MOCK_STATE_DIR}/replacement-output.txt"
  run_setup "$output" || {
    cat "$output" >&2
    test_fail "Replacement binding setup failed"
  }
  assert_count 1 "gcloud iam workload-identity-pools create ${MOCK_POOL_ID}" \
    "${MOCK_STATE_DIR}/commands.log"
  assert_count 2 "workload-identity-pools providers create-oidc" \
    "${MOCK_STATE_DIR}/commands.log"
  jq -s -e '.[0].workloadIdentityProviderResourceName !=
    .[1].workloadIdentityProviderResourceName' \
    "$first_registration" "${MOCK_STATE_DIR}/registration-3.json" >/dev/null ||
    test_fail "Replacement binding reused connection-specific identity resources"
}

test_soft_deleted_resources_are_recovered() {
  local output
  begin_case soft-deleted
  printf 'DELETED' > "${MOCK_STATE_DIR}/pool-${MOCK_POOL_ID}-state"
  printf 'DELETED' > "${MOCK_STATE_DIR}/provider-${MOCK_PROVIDER_ID}-state"
  output="${MOCK_STATE_DIR}/output.txt"
  run_setup "$output" || {
    cat "$output" >&2
    test_fail "Soft-deleted resource recovery failed"
  }
  assert_contains "${MOCK_STATE_DIR}/commands.log" \
    "gcloud iam workload-identity-pools undelete ${MOCK_POOL_ID}"
  assert_contains "${MOCK_STATE_DIR}/commands.log" \
    "workload-identity-pools providers undelete ${MOCK_PROVIDER_ID}"
  assert_not_contains "${MOCK_STATE_DIR}/commands.log" \
    "gcloud iam workload-identity-pools create ${MOCK_POOL_ID}"
  assert_not_contains "${MOCK_STATE_DIR}/commands.log" \
    "workload-identity-pools providers create-oidc"
}

test_release_rejections
test_digest_dependency
test_authentication_guidance
test_strict_tenant_id
test_registration_retry_and_recovery
test_full_setup_rerun_and_replacement
test_soft_deleted_resources_are_recovered
printf 'GCP guided setup executable tests passed\n'
