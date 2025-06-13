#!/usr/bin/env bash
# Test script for advisory-creator.sh
# 
# This script tests the functionality of the advisory creator system.
# It creates a temporary test environment and runs tests against the
# advisory-creator.sh script.

set -euo pipefail

# Import the main script for testing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/advisory-creator.sh"

# Test utilities
#
# Sets up a test environment with a temporary directory and git repository
#
# Returns:
#   None
function setup_test_env() {
  # Create temporary directory for test files
  TEST_DIR=$(mktemp -d)
  mkdir -p "${TEST_DIR}/packages/kernel-5.15"
  mkdir -p "${TEST_DIR}/packages/kernel-6.1"
  mkdir -p "${TEST_DIR}/advisories/1.0.0"
  
  # Set up git repository
  pushd "$TEST_DIR" > /dev/null
  git init
  git config user.name "Test User"
  git config user.email "test@example.com"
  popd > /dev/null
  
  echo "Test environment set up at $TEST_DIR"
}

# Test version tag validation
#
# Tests the validate_version_tag function with various inputs:
# - Valid version tags
# - Invalid version tags
#
# Returns:
#   0 if all tests pass, 1 otherwise
function test_validate_version_tag() {
  echo "Testing validate_version_tag function..."
  
  # Test valid version tags
  validate_version_tag "v1.0.0"
  assert_equals $? 0 "v1.0.0 should be valid"
  
  validate_version_tag "v10.20.30"
  assert_equals $? 0 "v10.20.30 should be valid"
  
  validate_version_tag "v0.0.1"
  assert_equals $? 0 "v0.0.1 should be valid"
  
  # Test invalid version tags
  validate_version_tag "1.0.0"
  assert_equals $? 1 "1.0.0 should be invalid (missing v prefix)"
  
  validate_version_tag "v1.0"
  assert_equals $? 1 "v1.0 should be invalid (missing patch version)"
  
  validate_version_tag "v1.0.0-rc1"
  assert_equals $? 1 "v1.0.0-rc1 should be invalid (contains non-numeric suffix)"
  
  validate_version_tag "va.b.c"
  assert_equals $? 1 "va.b.c should be invalid (contains non-numeric versions)"
  
  validate_version_tag "v1.2.3.4"
  assert_equals $? 1 "v1.2.3.4 should be invalid (too many version components)"
  
  validate_version_tag ""
  assert_equals $? 1 "Empty string should be invalid"
  
  echo "validate_version_tag tests passed"
}

# Clean up the test environment
#
# Removes the temporary test directory
#
# Returns:
#   None
function cleanup_test_env() {
  if [[ -d "$TEST_DIR" ]]; then
    rm -rf "$TEST_DIR"
    echo "Test environment cleaned up"
  fi
}

# Assert that two values are equal
#
# Args:
#   $1: Actual value
#   $2: Expected value
#   $3: Optional message
#
# Returns:
#   0 if values are equal, 1 otherwise
function assert_equals() {
  local actual="$1"
  local expected="$2"
  local message="${3:-}"
  
  if [[ "$actual" != "$expected" ]]; then
    echo "Assertion failed: Expected '$expected', got '$actual'" >&2
    if [[ -n "$message" ]]; then
      echo "Message: $message" >&2
    fi
    return 1
  fi
  return 0
}

# Test finding previous version
#
# Tests the find_previous_version function with various scenarios:
# - Finding previous patch version
# - Finding previous minor version
# - Finding previous major version
#
# Returns:
#   None
function test_find_previous_version() {
  echo "Testing find_previous_version function..."
  
  # Setup
  pushd "$TEST_DIR" > /dev/null
  
  # Create tags
  git commit --allow-empty -m "Initial commit"
  git tag -a v1.0.0 -m "v1.0.0"
  git commit --allow-empty -m "Second commit"
  git tag -a v1.0.1 -m "v1.0.1"
  git commit --allow-empty -m "Third commit"
  git tag -a v1.1.0 -m "v1.1.0"
  git commit --allow-empty -m "Fourth commit"
  git tag -a v2.0.0 -m "v2.0.0"
  
  # Test cases
  local result
  
  # Test finding previous patch version
  result=$(find_previous_version "v1.0.1")
  assert_equals "$result" "v1.0.0" "Should find previous patch version"
  
  # Test finding previous minor version
  result=$(find_previous_version "v1.1.0")
  assert_equals "$result" "v1.0.1" "Should find previous minor version"
  
  # Test finding previous major version
  result=$(find_previous_version "v2.0.0")
  assert_equals "$result" "v1.1.0" "Should find previous major version"
  
  # Test out-of-order releases
  git commit --allow-empty -m "Fifth commit"
  git tag -a v1.0.2 -m "v1.0.2"
  
  result=$(find_previous_version "v1.0.2")
  assert_equals "$result" "v1.0.1" "Should handle out-of-order releases"
  
  popd > /dev/null
  echo "find_previous_version tests passed"
}

# Test detecting kernel updates
#
# Tests the detect_kernel_updates function with various scenarios:
# - Detecting single kernel update
# - Detecting multiple kernel updates
# - Handling no kernel updates
#
# Returns:
#   None
function test_detect_kernel_updates() {
  echo "Testing detect_kernel_updates function..."
  
  # Setup
  pushd "$TEST_DIR" > /dev/null
  
  # Create a fresh git repository for this test to avoid tag conflicts
  rm -rf .git
  git init
  git config user.name "Test User"
  git config user.email "test@example.com"
  
  # Create kernel package directories and spec files
  mkdir -p packages/kernel-5.15
  mkdir -p packages/kernel-6.1
  
  # Create initial spec files
  cat > packages/kernel-5.15/kernel-5.15.spec << EOF
Name: kernel-5.15
Version: 5.15.120
Release: 1
Summary: test
License: test

%description
test
EOF
  
  cat > packages/kernel-6.1/kernel-6.1.spec << EOF
Name: kernel-6.1
Version: 6.1.40
Release: 1
Summary: test
License: test

%description
test
EOF
  
  # Initial commit and tag
  git add .
  git commit -m "Initial kernel versions"
  git tag -a v1.0.0 -m "v1.0.0"
  
  # Update one kernel version
  cat > packages/kernel-6.1/kernel-6.1.spec << EOF
Name: kernel-6.1
Version: 6.1.41
Release: 1
Summary: test
License: test

%description
test
EOF
  
  git add .
  git commit -m "Update kernel-6.1"
  git tag -a v1.0.1 -m "v1.0.1"
  
  # Test detection of single update
  local result
  mapfile -t result < <(detect_kernel_updates "v1.0.0" "v1.0.1")
  
  assert_equals "${#result[@]}" "1" "Should detect one kernel update"
  assert_equals "${result[0]}" "kernel-6.1:6.1.41" "Should detect correct kernel update"
  
  # Update both kernels
  cat > packages/kernel-5.15/kernel-5.15.spec << EOF
Name: kernel-5.15
Version: 5.15.121
Release: 1
Summary: test
License: test

%description
test
EOF
  
  cat > packages/kernel-6.1/kernel-6.1.spec << EOF
Name: kernel-6.1
Version: 6.1.42
Release: 1
Summary: test
License: test

%description
test
EOF
  
  git add .
  git commit -m "Update both kernels"
  git tag -a v1.0.2 -m "v1.0.2"
  
  # Test detection of multiple updates
  mapfile -t result < <(detect_kernel_updates "v1.0.1" "v1.0.2")
  
  assert_equals "${#result[@]}" "2" "Should detect two kernel updates"
  
  # Sort the results for consistent testing
  local sorted_result=()
  for item in "${result[@]}"; do
    sorted_result+=("$item")
  done
  
  # Use mapfile to avoid shellcheck warning
  mapfile -t sorted_result < <(printf '%s\n' "${sorted_result[@]}" | sort)
  
  assert_equals "${sorted_result[0]}" "kernel-5.15:5.15.121" "Should detect kernel-5.15 update"
  assert_equals "${sorted_result[1]}" "kernel-6.1:6.1.42" "Should detect kernel-6.1 update"
  
  # Make a commit with no kernel updates
  git commit --allow-empty -m "No kernel updates"
  git tag -a v1.0.3 -m "v1.0.3"
  
  # Test detection of no updates
  mapfile -t result < <(detect_kernel_updates "v1.0.2" "v1.0.3")
  assert_equals "${#result[@]}" "0" "Should detect no kernel updates"
  
  popd > /dev/null
  echo "detect_kernel_updates tests passed"
}

# Test generating advisory ID
#
# Tests the generate_advisory_id function to ensure it produces IDs
# in the expected format: BRSA-[12 alphanumeric chars]
#
# Returns:
#   None
function test_generate_advisory_id() {
  echo "Testing generate_advisory_id function..."
  
  # Generate multiple IDs to ensure consistency
  local id1 id2
  id1=$(generate_advisory_id)
  id2=$(generate_advisory_id)
  
  # Test that IDs match the expected format
  if ! [[ "${id1}" =~ ^BRSA-[a-z0-9]{12}$ ]]; then
    echo "Generated ID does not match expected format: ${id1}" >&2
    return 1
  fi
  
  if ! [[ "${id2}" =~ ^BRSA-[a-z0-9]{12}$ ]]; then
    echo "Generated ID does not match expected format: ${id2}" >&2
    return 1
  fi
  
  # Test that IDs are different (randomness check)
  if [[ "${id1}" == "${id2}" ]]; then
    echo "Generated IDs are identical: ${id1} and ${id2}" >&2
    echo "This is highly unlikely and suggests a problem with ID generation" >&2
    return 1
  fi
  
  echo "generate_advisory_id tests passed"
}

# Test generating advisory file content
#
# Tests the generate_advisory_file function to ensure it produces
# correctly formatted advisory content with the expected values
#
# Returns:
#   None
function test_generate_advisory_file() {
  echo "Testing generate_advisory_file function..."
  
  # Create a temporary template file for testing
  local test_template_dir="${TEST_DIR}/templates"
  mkdir -p "${test_template_dir}"
  
  local test_template="${test_template_dir}/advisory-template.toml"
  cat > "${test_template}" << EOF
[advisory]
id = "\${ADVISORY_ID}"
title = "Bottlerocket Kernel \${KERNEL_MAJOR_MINOR} Updates"
severity = "high"
description = """
Kernel version \${KERNEL_VERSION} is now available with important fixes. \\
All users must upgrade. \\
Advisory information for the kernel is often published after new kernels become available. \\
Bottlerocket recommends that you consume the latest kernel release for your LTS version.
"""

[[advisory.products]]
package-name = "\${PACKAGE_NAME}"
patched-version = "\${KERNEL_VERSION}"
patched-epoch = "0"

[updateinfo]
author = "Bottlerocket"
issue-date = \${ISSUE_DATE}
arches = ["x86_64", "aarch64"]
version = "\${KIT_VERSION}"
EOF
  
  # Test parameters
  local test_advisory_id="BRSA-123456789abc"
  local test_kit_version="v1.2.3"
  local test_package_name="kernel-6.1"
  local test_kernel_version="6.1.42"
  
  local content
  content=$(generate_advisory_file "${test_advisory_id}" "${test_kit_version}" "${test_package_name}" "${test_kernel_version}" "${test_template}")
  
  # Check that content contains expected elements
  if ! echo "${content}" | grep -q "id = \"${test_advisory_id}\""; then
    echo "Advisory content missing expected ID" >&2
    echo "${content}" >&2
    return 1
  fi
  
  if ! echo "${content}" | grep -q "title = \"Bottlerocket Kernel 6.1 Updates\""; then
    echo "Advisory content missing expected title" >&2
    echo "${content}" >&2
    return 1
  fi
  
  if ! echo "${content}" | grep -q "package-name = \"${test_package_name}\""; then
    echo "Advisory content missing expected package name" >&2
    echo "${content}" >&2
    return 1
  fi
  
  if ! echo "${content}" | grep -q "patched-version = \"${test_kernel_version}\""; then
    echo "Advisory content missing expected version" >&2
    echo "${content}" >&2
    return 1
  fi
  
  if ! echo "${content}" | grep -q "version = \"1.2.3\""; then
    echo "Advisory content missing expected kit version" >&2
    echo "${content}" >&2
    return 1
  fi
  
  # Verify description contains kernel version
  if ! echo "${content}" | grep -q "Kernel version ${test_kernel_version} is now available"; then
    echo "Advisory content missing expected kernel version in description" >&2
    echo "${content}" >&2
    return 1
  fi
  
  echo "generate_advisory_file tests passed"
}

# Test generating unique branch names
#
# Tests the generate_unique_branch_name function to ensure it produces
# unique branch names when collisions occur
#
# Returns:
#   None
function test_generate_unique_branch_name() {
  echo "Testing generate_unique_branch_name function..."
  
  # Setup
  pushd "$TEST_DIR" > /dev/null
  
  # Test with non-existent branch name
  local base_name="test-branch"
  local result
  result=$(generate_unique_branch_name "${base_name}")
  assert_equals "${result}" "${base_name}" "Should return base name when no collision exists"
  
  # Create a branch to test collision handling
  git checkout -b "${base_name}"
  
  # Test with existing branch name
  result=$(generate_unique_branch_name "${base_name}")
  if [[ "${result}" == "${base_name}" ]]; then
    echo "Failed to generate unique branch name for collision" >&2
    return 1
  fi
  
  # Verify the format of the generated name
  if ! [[ "${result}" =~ ^${base_name}-[a-z0-9]{4}$ ]]; then
    echo "Generated branch name has incorrect format: ${result}" >&2
    return 1
  fi
  
  # Create multiple branches to test multiple collisions
  git checkout -b "${result}"
  local result2
  result2=$(generate_unique_branch_name "${base_name}")
  
  # Verify we got a different name
  if [[ "${result2}" == "${base_name}" || "${result2}" == "${result}" ]]; then
    echo "Failed to generate unique branch name for multiple collisions" >&2
    return 1
  fi
  
  # Verify the format of the second generated name
  if ! [[ "${result2}" =~ ^${base_name}-[a-z0-9]{4}$ ]]; then
    echo "Second generated branch name has incorrect format: ${result2}" >&2
    return 1
  fi
  
  popd > /dev/null
  echo "generate_unique_branch_name tests passed"
}

# Run all tests
#
# Sets up the test environment, runs all test functions, and cleans up.
# Reports overall test results and exits with appropriate status code.
#
# Args:
#   $1: Optional flag to enable verbose output
#
# Returns:
#   0 if all tests pass, 1 if any test fails
function run_all_tests() {
  local verbose="${1:-false}"
  local failed_tests=0
  local total_tests=0
  local test_results=()
  
  echo "=== Running Advisory Creator Tests ==="
  echo "Starting test run at $(date)"
  
  # Setup test environment
  setup_test_env
  
  # Trap to ensure cleanup even if tests fail
  trap cleanup_test_env EXIT
  
  # Define test functions to run in order
  local test_functions=(
    "test_validate_version_tag"
    "test_find_previous_version"
    "test_detect_kernel_updates"
    "test_generate_advisory_id"
    "test_generate_advisory_file"
    "test_generate_unique_branch_name"
  )
  
  # Run each test function and track results
  for test_func in "${test_functions[@]}"; do
    total_tests=$((total_tests + 1))
    echo -n "Running ${test_func}... "
    
    # Capture output and run test
    local output
    if output=$(${test_func} 2>&1); then
      echo "PASSED"
      test_results+=("✅ ${test_func}")
      if [[ "${verbose}" == "true" ]]; then
        echo "${output}"
      fi
    else
      echo "FAILED"
      test_results+=("❌ ${test_func}")
      failed_tests=$((failed_tests + 1))
      echo "${output}"
    fi
  done
  
  # Report overall results
  echo
  echo "=== Test Results ==="
  for result in "${test_results[@]}"; do
    echo "${result}"
  done
  
  echo
  echo "Tests completed at $(date)"
  echo "Total tests: ${total_tests}"
  echo "Passed: $((total_tests - failed_tests))"
  echo "Failed: ${failed_tests}"
  
  if [[ ${failed_tests} -eq 0 ]]; then
    echo "✅ All tests passed successfully!"
    return 0
  else
    echo "❌ Some tests failed. See output above for details."
    return 1
  fi
}

# Parse command line arguments for test script
#
# Args:
#   $@: Command line arguments
#
# Returns:
#   None
function parse_test_args() {
  local verbose=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verbose|-v)
        verbose=true
        shift
        ;;
      --help|-h)
        echo "Usage: $(basename "${0}") [OPTIONS]"
        echo
        echo "Options:"
        echo "  --verbose, -v    Enable verbose output"
        echo "  --help, -h       Show this help message and exit"
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Use --help for usage information" >&2
        exit 1
        ;;
    esac
  done
  
  # Run tests with parsed arguments
  run_all_tests "${verbose}"
  exit $?
}

# Only run tests if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  parse_test_args "$@"
fi
