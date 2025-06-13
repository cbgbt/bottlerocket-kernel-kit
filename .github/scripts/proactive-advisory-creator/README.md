# Kernel Proactive Advisory Creator

## Overview

This GitHub Action automatically creates proactive security advisories for kernel updates in the
bottlerocket-kernel-kit repository.

Kernel updates tend to be released well-ahead of their security advisories.
This script ensures that kernel releases are marked as security updates as soon as possible, to
avoid delaying marking them as such.

## Workflow

1. Triggers when a new release tag is created (format: `v[0-9]+.[0-9]+.[0-9]+`)
2. Identifies the previous version tag for comparison
3. Detects which kernel packages have been updated between versions
4. Creates a new advisory for each kernel update
5. Opens a pull request with the new advisory file(s)

## Configuration

The action uses templates located in the `templates/` directory:

- `advisory-template.toml`: Template for generating advisory files
- `pr-title.txt`: Title for the pull request
- `pr-body.txt`: Body content for the pull request

## Usage

```bash
# Basic usage
.github/scripts/proactive-advisory-creator/advisory-creator.sh --current-tag v3.2.1 --target-repo owner/repo

# With explicit previous tag
.github/scripts/proactive-advisory-creator/advisory-creator.sh --current-tag v3.2.1 --previous-tag v3.2.0 --target-repo owner/repo

# Dry run mode (no PR creation)
.github/scripts/proactive-advisory-creator/advisory-creator.sh --current-tag v3.2.1 --target-repo owner/repo --dry-run
```

### Options

- `--current-tag TAG`: The current version tag (e.g., v3.2.1)
- `--target-repo REPO`: Target GitHub repository in format 'owner/repo'
- `--previous-tag TAG`: (Optional) The previous version tag to compare against
- `--dry-run`: Run without creating a PR
- `--debug`: Enable verbose logging

## Testing

Run the tests with:

```bash
.github/scripts/proactive-advisory-creator/advisory-creator-tests.sh
```
