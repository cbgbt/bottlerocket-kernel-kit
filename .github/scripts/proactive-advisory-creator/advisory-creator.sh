#!/usr/bin/env bash
# This script detects kernel updates between version releases and creates proactive security
# advisories.
# It is designed to be run as part of a GitHub Action when a new version tag is pushed.
# 
# Usage: advisory-creator.sh --current-tag <tag> --target-repo <owner/repo> [--previous-tag <tag>] [--dry-run] [--debug]
#
# Arguments:
#   --current-tag <tag>   The current version tag (e.g., v3.2.1)
#   --target-repo <repo>  Target GitHub repository in format 'owner/repo'
#   --previous-tag <tag>  (Optional) The previous version tag to compare against
#   --dry-run             Run without creating a PR
#   --debug               Enable verbose logging
#   --help                Show help message and exit
#
# Example:
#   advisory-detection.sh --current-tag v3.2.1 --target-repo owner/repo
#   advisory-detection.sh --current-tag v3.2.1 --previous-tag v3.2.0 --target-repo owner/repo --dry-run

set -euo pipefail

# Script constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TEMPLATE_DIR="${SCRIPT_DIR}/templates"
readonly ADVISORY_TEMPLATE="${TEMPLATE_DIR}/advisory-template.toml"
readonly PR_TITLE_TEMPLATE="${TEMPLATE_DIR}/pr-title.txt"
readonly PR_BODY_TEMPLATE="${TEMPLATE_DIR}/pr-body.txt"
readonly ADVISORY_ID_LENGTH=12

# Global variables with default values
current_tag=""
previous_tag=""
target_repo=""
dry_run="false"
debug="false"
TEMP_DIR=""

# Print debug message if debug mode is enabled
#
# Args:
#   $*: Message to print
#
# Returns:
#   None
function debug_log() {
  if [[ "${debug}" == "true" ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

# Print error message and exit
#
# Args:
#   $*: Error message
#
# Returns:
#   Never returns, exits with code 1
function error_exit() {
  echo "[ERROR] $*" >&2
  exit 1
}

# Clean up temporary files
#
# Removes temporary directory if it exists
#
# Returns:
#   None
function cleanup() {
  local exit_code=$?
  debug_log "Cleaning up temporary files"
  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
  exit "${exit_code}"
}

# Check if a command exists
#
# Args:
#   $1: Command to check
#
# Returns:
#   0 if command exists, 1 otherwise
function command_exists() {
  command -v "$1" &> /dev/null
}

# Validate a version tag format
#
# Args:
#   $1: Version tag to validate
#
# Returns:
#   0 if valid, 1 if invalid
function validate_version_tag() {
  local tag="$1"
  [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
  return $?
}

# Set up trap for cleanup
trap cleanup EXIT

# Print usage information
#
# Displays help text for the script
#
# Returns:
#   None
function print_usage() {
  cat << EOF
Usage: $(basename "${0}") [OPTIONS]

Options:
  --current-tag TAG    The current version tag (e.g., v3.2.1)
  --target-repo REPO   Target GitHub repository in format 'owner/repo'
  --previous-tag TAG   (Optional) The previous version tag to compare against
  --dry-run            Run without creating a PR
  --debug              Enable verbose logging
  --help               Show this help message and exit

Example:
  $(basename "${0}") --current-tag v3.2.1 --target-repo owner/repo
  $(basename "${0}") --current-tag v3.2.1 --previous-tag v3.2.0 --target-repo owner/repo --dry-run
EOF
}

# Parse command line arguments
#
# Parses command line arguments and validates required parameters.
# Sets global variables based on provided arguments.
#
# Args:
#   $@: Command line arguments
#
# Returns:
#   None
function parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --current-tag)
        if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
          error_exit "Option $1 requires an argument"
        fi
        current_tag="$2"
        shift 2
        ;;
      --previous-tag)
        if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
          error_exit "Option $1 requires an argument"
        fi
        previous_tag="$2"
        shift 2
        ;;
      --target-repo)
        if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
          error_exit "Option $1 requires an argument"
        fi
        target_repo="$2"
        shift 2
        ;;
      --dry-run)
        dry_run="true"
        shift
        ;;
      --debug)
        debug="true"
        shift
        ;;
      --help)
        print_usage
        exit 0
        ;;
      *)
        error_exit "Unknown option: $1"
        ;;
    esac
  done

  # Validate required arguments
  if [[ -z "${current_tag}" ]]; then
    error_exit "Missing required option: --current-tag"
  fi
  
  if [[ -z "${target_repo}" ]]; then
    error_exit "Missing required option: --target-repo"
  fi

  # Validate tag format
  if ! validate_version_tag "${current_tag}"; then
    error_exit "Invalid current tag format: ${current_tag} (expected format: v[0-9]+.[0-9]+.[0-9]+)"
  fi

  if [[ -n "${previous_tag}" ]] && ! validate_version_tag "${previous_tag}"; then
    error_exit "Invalid previous tag format: ${previous_tag} (expected format: v[0-9]+.[0-9]+.[0-9]+)"
  fi

  debug_log "Current tag: ${current_tag}"
  if [[ -n "${previous_tag}" ]]; then
    debug_log "Previous tag: ${previous_tag}"
  fi
  if [[ -n "${target_repo}" ]]; then
    debug_log "Target repository: ${target_repo}"
  fi
  debug_log "Dry run: ${dry_run}"
}

# Find the previous version tag for comparison
#
# Uses a hierarchical search strategy to find the previous version tag:
# 1. Same major.minor, lower patch
# 2. Same major, lower minor
# 3. Previous major
# 4. Fallback to most recent tag
#
# Args:
#   $1: Current version tag (e.g., v3.2.1)
#
# Returns:
#   Previous version tag
function find_previous_version() {
  local current_tag="$1"
  local major minor patch
  
  # Parse current version
  if [[ "${current_tag}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
  else
    error_exit "Invalid version format: ${current_tag}"
  fi
  
  debug_log "Parsed version: major=${major}, minor=${minor}, patch=${patch}"
  
  # Hierarchical search strategy:
  # 1. Same major.minor, lower patch
  debug_log "Searching for previous version with same major.minor, lower patch"
  local same_minor_tags
  same_minor_tags=$(git tag -l "v${major}.${minor}.*" | sort -V | grep -v "^${current_tag}$" || true)
  
  if [[ -n "${same_minor_tags}" ]]; then
    # Find the highest patch version that's lower than the current patch
    local prev_tag
    prev_tag=$(echo "${same_minor_tags}" | grep -E "^v${major}\.${minor}\.[0-9]+$" | 
               awk -v patch="${patch}" -F. '{ if ($3 < patch) print $0 }' | 
               sort -V | tail -n1)
    
    if [[ -n "${prev_tag}" ]]; then
      debug_log "Found previous patch version: ${prev_tag}"
      echo "${prev_tag}"
      return 0
    fi
  fi
  
  # 2. Same major, lower minor
  debug_log "Searching for previous version with same major, lower minor"
  local same_major_tags
  same_major_tags=$(git tag -l "v${major}.*.*" | sort -V | grep -v "^${current_tag}$" || true)
  
  if [[ -n "${same_major_tags}" ]]; then
    # Find the highest minor.patch version that's lower than the current minor
    local prev_tag
    prev_tag=$(echo "${same_major_tags}" | grep -E "^v${major}\.[0-9]+\.[0-9]+$" | 
               awk -v minor="${minor}" -F. '{ if ($2 < minor) print $0 }' | 
               sort -V | tail -n1)
    
    if [[ -n "${prev_tag}" ]]; then
      debug_log "Found previous minor version: ${prev_tag}"
      echo "${prev_tag}"
      return 0
    fi
  fi
  
  # 3. Previous major
  debug_log "Searching for previous version with lower major"
  local prev_major=$((major - 1))
  if [[ "${prev_major}" -ge 0 ]]; then
    local prev_major_tags
    prev_major_tags=$(git tag -l "v${prev_major}.*.*" | grep -E "^v${prev_major}\.[0-9]+\.[0-9]+$" | sort -V || true)
    
    if [[ -n "${prev_major_tags}" ]]; then
      local prev_tag
      prev_tag=$(echo "${prev_major_tags}" | tail -n1)
      debug_log "Found previous major version: ${prev_tag}"
      echo "${prev_tag}"
      return 0
    fi
  fi
  
  # 4. Fallback to most recent tag that's not the current one
  debug_log "Falling back to most recent tag"
  local all_tags
  all_tags=$(git tag -l | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$" | grep -v "^${current_tag}$" | sort -V || true)
  
  if [[ -n "${all_tags}" ]]; then
    local prev_tag
    prev_tag=$(echo "${all_tags}" | tail -n1)
    debug_log "Found fallback tag: ${prev_tag}"
    echo "${prev_tag}"
    return 0
  fi
  
  # No previous version found
  error_exit "No previous version tag found for comparison"
}

# Generate a unique advisory ID
#
# Generates a random 12-character alphanumeric ID prefixed with "BRSA-"
#
# Returns:
#   Advisory ID in the format "BRSA-[12 chars]"
function generate_advisory_id() {
  # Check for required commands
  if ! command_exists "tr" || ! command_exists "fold"; then
    error_exit "Required commands 'tr' and 'fold' not found"
  fi
  
  local id
  id=$(< /dev/urandom tr -dc 'a-z0-9' | fold -w "${ADVISORY_ID_LENGTH}" | head -n 1)
  if [[ -z "${id}" ]]; then
    error_exit "Failed to generate advisory ID"
  fi
  echo "BRSA-${id}"
}

# Generate advisory file content
#
# Creates the content for an advisory file using the template
#
# Args:
#   $1: Advisory ID
#   $2: Kit version
#   $3: Package name
#   $4: Kernel version
#
# Returns:
#   Advisory file content
function generate_advisory_file() {
  local advisory_id="$1"
  local kit_version="$2"
  local package_name="$3"
  local kernel_version="$4"
  # Optional parameter for template path with default value
  local template_path="${5:-$ADVISORY_TEMPLATE}"
  
  # Extract kernel major.minor version
  local kernel_major_minor
  if [[ "${package_name}" =~ kernel-([0-9]+\.[0-9]+) ]]; then
    kernel_major_minor="${BASH_REMATCH[1]}"
  else
    error_exit "Invalid package name format: ${package_name}"
  fi
  
  debug_log "Extracted kernel major.minor version: ${kernel_major_minor}"
  
  # Check if template file exists
  if [[ ! -f "${template_path}" ]]; then
    error_exit "Advisory template file not found: ${template_path}"
  fi
  
  # Read template
  local template
  template=$(<"${template_path}")
  
  # Generate current timestamp in RFC 3339 format for TOML date
  local issue_date
  issue_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  debug_log "Setting up environment variables for template processing"
  
  # Check if envsubst is available
  if ! command_exists "envsubst"; then
    error_exit "Required command 'envsubst' not found"
  fi
  
  # Set up environment variables for envsubst
  export ADVISORY_ID="${advisory_id}"
  export KERNEL_MAJOR_MINOR="${kernel_major_minor}"
  export KERNEL_VERSION="${kernel_version}"
  export PACKAGE_NAME="${package_name}"
  export ISSUE_DATE="${issue_date}"
  export KIT_VERSION="${kit_version#v}"
  
  debug_log "Processing template with envsubst"
  
  # Use envsubst to replace variables
  local content

  # shellcheck disable=SC2016
  content=$(echo "${template}" | envsubst '${ADVISORY_ID} ${KERNEL_MAJOR_MINOR} ${KERNEL_VERSION} ${PACKAGE_NAME} ${ISSUE_DATE} ${KIT_VERSION}')
  
  # Check if envsubst succeeded
  if [[ $? -ne 0 || -z "${content}" ]]; then
    error_exit "Failed to process template with envsubst"
  fi
  
  # Clean up environment
  unset ADVISORY_ID KERNEL_MAJOR_MINOR KERNEL_VERSION PACKAGE_NAME ISSUE_DATE KIT_VERSION
  
  echo "${content}"
}

# Detect kernel updates between versions
#
# Compares kernel package versions between two tags and identifies updates
#
# Args:
#   $1: Previous version tag
#   $2: Current version tag
#
# Returns:
#   Newline-separated list of updated kernel packages with their versions
function detect_kernel_updates() {
  local previous_tag="$1"
  local current_tag="$2"
  local kernel_updates=()
  
  debug_log "Detecting kernel updates between ${previous_tag} and ${current_tag}"
  
  TEMP_DIR=$(mktemp -d)
  if [[ ! -d "${TEMP_DIR}" ]]; then
    error_exit "Failed to create temporary directory"
  fi
  chmod 700 "${TEMP_DIR}"
  debug_log "Created temporary directory: ${TEMP_DIR}"
  
  # Find kernel package directories
  local kernel_dirs
  kernel_dirs=$(find ./packages -type d -name "kernel-[0-9]*.[0-9]*" 2>/dev/null | sort || echo "")
  
  if [[ -z "${kernel_dirs}" ]]; then
    debug_log "No kernel package directories found"
    return 0
  fi
  
  debug_log "Found kernel package directories: ${kernel_dirs}"
  
  for kernel_dir in ${kernel_dirs}; do
    # Extract package name from directory
    local package_name
    package_name=$(basename "${kernel_dir}")
    
    debug_log "Processing package: ${package_name}"
    
    # Find spec file
    local spec_file
    spec_file=$(find "${kernel_dir}" -name "*.spec" | head -n 1)
    
    if [[ -z "${spec_file}" ]]; then
      debug_log "Warning: No spec file found in ${kernel_dir}"
      continue
    fi
    
    debug_log "Found spec file: ${spec_file}"
    
    # Extract version information using grep
    local previous_version current_version
    
    debug_log "Using grep to extract version information"
    
    # Get previous version
    if ! git show "${previous_tag}:${spec_file}" > "${TEMP_DIR}/previous_spec" 2>/dev/null; then
      debug_log "Warning: Could not get spec file from ${previous_tag}"
      continue
    fi
    
    previous_version=$(grep -E "^Version:\s*([0-9]+\.[0-9]+\.[0-9]+)" "${TEMP_DIR}/previous_spec" | sed -E 's/^Version:\s*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' 2>/dev/null || echo "")
    
    # Get current version
    if ! git show "${current_tag}:${spec_file}" > "${TEMP_DIR}/current_spec" 2>/dev/null; then
      debug_log "Warning: Could not get spec file from ${current_tag}"
      continue
    fi
    
    current_version=$(grep -E "^Version:\s*([0-9]+\.[0-9]+\.[0-9]+)" "${TEMP_DIR}/current_spec" | sed -E 's/^Version:\s*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' 2>/dev/null || echo "")
    
    if [[ -z "${previous_version}" || -z "${current_version}" ]]; then
      debug_log "Warning: Could not extract version information for ${package_name}"
      continue
    fi
    
    debug_log "Previous version: ${previous_version}, Current version: ${current_version}"
    
    # Compare versions
    if [[ "${previous_version}" != "${current_version}" ]]; then
      debug_log "Detected update: ${package_name} from ${previous_version} to ${current_version}"
      kernel_updates+=("${package_name}:${current_version}")
    fi
  done
  
  # Return the list of updated kernel packages
  if [[ ${#kernel_updates[@]} -eq 0 ]]; then
    debug_log "No kernel updates detected"
    return 0
  fi
  
  debug_log "Detected ${#kernel_updates[@]} kernel updates"
  
  # Return updates as a newline-separated list to handle spaces in package names or versions
  printf "%s\n" "${kernel_updates[@]}"
}

# Generate a unique branch name by adding a random suffix if needed
#
# Args:
#   $1: Base branch name
#
# Returns:
#   Unique branch name
function generate_unique_branch_name() {
  local base_name="$1"
  local unique_name="${base_name}"
  
  # If the branch already exists, add a random suffix
  while git show-ref --quiet "refs/heads/${unique_name}"; do
    # Generate a 4-character random alphanumeric suffix
    local suffix
    suffix=$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
    unique_name="${base_name}-${suffix}"
  done
  
  echo "${unique_name}"
}

# Create a pull request with the new advisories
#
# Creates a new branch, adds advisory files, and creates a PR
#
# Args:
#   $1: Kit version
#   $2: Previous version
#   $3+: Advisory files in the format "advisory_id:package_name:version:content"
#
# Returns:
#   None
function create_pull_request() {
  local kit_version="$1"
  local previous_version="$2"
  shift 2
  local advisory_files=("$@")
  
  debug_log "Creating pull request for ${#advisory_files[@]} advisory files"
  
  # Create branch for PR
  local base_branch_name="proactive-kernel-advisories-${kit_version#v}"
  local branch_name
  branch_name=$(generate_unique_branch_name "${base_branch_name}")
  debug_log "Creating branch: ${branch_name}"
  
  # Create new branch from current HEAD
  if ! git checkout -b "${branch_name}"; then
    error_exit "Failed to create branch: ${branch_name}"
  fi
  
  # Create advisory directory if it doesn't exist
  local advisory_dir="./advisories/${kit_version#v}"
  debug_log "Creating advisory directory: ${advisory_dir}"
  mkdir -p "${advisory_dir}"
  
  # Write advisory files
  for file_info in "${advisory_files[@]}"; do
    local advisory_id package_name version content
    
    # Parse file info (format: advisory_id:package_name:version:content)
    local IFS_OLD="$IFS"
    IFS=':' read -r advisory_id package_name version content <<< "${file_info}"
    IFS="$IFS_OLD"
    
    # Determine file path
    local file_path="${advisory_dir}/${advisory_id}-${package_name}.toml"
    debug_log "Writing advisory file: ${file_path}"
    
    # Write content to file
    echo "${content}" > "${file_path}"
    
    # Add file to git
    if ! git add "${file_path}"; then
      error_exit "Failed to add file to git: ${file_path}"
    fi
  done
  
  # Check if PR templates exist
  if [[ ! -f "${PR_TITLE_TEMPLATE}" ]]; then
    error_exit "PR title template not found: ${PR_TITLE_TEMPLATE}"
  fi
  
  if [[ ! -f "${PR_BODY_TEMPLATE}" ]]; then
    error_exit "PR body template not found: ${PR_BODY_TEMPLATE}"
  fi
  
  # Read PR templates
  local pr_title_template pr_body_template
  pr_title_template=$(<"${PR_TITLE_TEMPLATE}")
  pr_body_template=$(<"${PR_BODY_TEMPLATE}")
  
  # Format kernel updates list for PR body
  local kernel_updates_str=""
  for file_info in "${advisory_files[@]}"; do
    local advisory_id package_name version
    local IFS_OLD="$IFS"
    IFS=':' read -r advisory_id package_name version <<< "${file_info}"
    IFS="$IFS_OLD"
    kernel_updates_str+="- ${package_name} (${version})\n"
  done
  
  # Set up environment variables for envsubst
  export KIT_VERSION="${kit_version#v}"
  export PREVIOUS_VERSION="${previous_version#v}"
  export KERNEL_UPDATES="${kernel_updates_str}"
  
  # Process templates with envsubst
  local pr_title pr_body
  # shellcheck disable=SC2016
  pr_title=$(echo "${pr_title_template}" | envsubst '${KIT_VERSION}')
  # shellcheck disable=SC2016
  pr_body=$(echo "${pr_body_template}" | envsubst '${KIT_VERSION} ${PREVIOUS_VERSION} ${KERNEL_UPDATES}')
  
  # Clean up environment variables
  unset KIT_VERSION PREVIOUS_VERSION KERNEL_UPDATES
  
  # Commit changes
  debug_log "Committing changes with title: ${pr_title}"
  if ! git commit -m "${pr_title}"; then
    error_exit "Failed to commit changes"
  fi
  
  # If dry run, don't push or create PR
  if [[ "${dry_run}" == "true" ]]; then
    echo "Dry run: Would create PR with title: ${pr_title}"
    echo "PR body:"
    echo -e "${pr_body}"
    
    # Return to original branch
    git checkout - || true
    return 0
  fi
  
  # Push branch to remote
  debug_log "Pushing branch to remote"
  if ! git push -u origin "${branch_name}"; then
    error_exit "Failed to push branch to remote"
  fi
  
  # Create PR using GitHub CLI
  debug_log "Creating PR using GitHub CLI"
  if ! command_exists "gh"; then
    error_exit "GitHub CLI (gh) not found. Please install it to create PRs."
  fi
  
  # Determine which repository to use for the PR
  debug_log "Using target repository: ${target_repo}"
  
  if ! gh pr create --title "${pr_title}" --body "${pr_body}" --repo "${target_repo}"; then
    error_exit "Failed to create PR using GitHub CLI"
  fi
  
  # Return to original branch
  git checkout - || true
}

# Main function
#
# Orchestrates the advisory detection and creation process
#
# Args:
#   $@: Command line arguments
#
# Returns:
#   None
function main() {
  # Parse arguments
  parse_args "$@"
  
  # Find previous version if not specified
  if [[ -z "${previous_tag}" ]]; then
    previous_tag=$(find_previous_version "${current_tag}")
    debug_log "Determined previous tag: ${previous_tag}"
  fi
  
  # Detect kernel updates
  local kernel_updates
  mapfile -t kernel_updates < <(detect_kernel_updates "${previous_tag}" "${current_tag}")
  
  if [[ ${#kernel_updates[@]} -eq 0 || (-n "${kernel_updates[0]}" && "${kernel_updates[0]}" == "") ]]; then
    echo "No kernel updates detected between ${previous_tag} and ${current_tag}"
    exit 0
  fi
  
  echo "Detected ${#kernel_updates[@]} kernel updates:"
  local advisory_files=()
  for update in "${kernel_updates[@]}"; do
    if [[ -n "${update}" ]]; then
      local package_name version
      package_name="${update%%:*}"
      version="${update#*:}"
      echo "  - ${package_name}: ${version}"
    fi
  done
  
  # Parse kernel updates
  local kernel_updates_array=()
  for update in "${kernel_updates[@]}"; do
    if [[ -n "${update}" ]]; then
      local package_name version
      package_name="${update%%:*}"
      version="${update#*:}"
      
      # Generate advisory ID
      local advisory_id
      advisory_id=$(generate_advisory_id)
      debug_log "Generated advisory ID: ${advisory_id}"
      
      # Generate advisory file content
      local advisory_content
      advisory_content=$(generate_advisory_file "${advisory_id}" "${current_tag}" "${package_name}" "${version}")
      
      # Add to advisory files list (format: advisory_id:package_name:version:content)
      advisory_files+=("${advisory_id}:${package_name}:${version}:${advisory_content}")
      kernel_updates_array+=("${package_name}: ${version}")
    fi
  done
  
  # Create PR with the new advisories
  if [[ "${dry_run}" != "true" ]]; then
    create_pull_request "${current_tag}" "${previous_tag}" "${advisory_files[@]}"
    echo "Pull request created successfully"
  else
    echo "Dry run: Would create advisories for ${#kernel_updates[@]} kernel updates"
    for file_info in "${advisory_files[@]}"; do
      local advisory_id package_name version content
      IFS=':' read -r advisory_id package_name version content <<< "${file_info}"
      
      echo "File: ./advisories/${current_tag#v}/${advisory_id}-${package_name}.toml"
      echo "${content}"
      echo
    done
  fi
  
  echo "Advisory detection script completed successfully"
}

# Execute main function if script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
