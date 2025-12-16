#!/usr/bin/env bash

# upgrade-manifest.sh - Infinibay Upgrade Manifest Library
#
# This library provides functions for loading, parsing, and validating upgrade
# manifests in YAML format. It handles version compatibility checking and
# listing available upgrades.
#
# Main Functions:
#   parse_manifest(manifest_path)           - Load and parse a manifest.yml file
#   validate_manifest(manifest_path)        - Validate manifest structure and required fields
#   check_version_compatibility(manifest)   - Check if upgrade is compatible with current version
#   list_available_upgrades(upgrades_dir)   - List all available upgrades with status
#   get_current_version()                   - Get the current installed version
#
# Dependencies:
#   - yq: YAML parser (install with: sudo snap install yq OR sudo apt install yq)
#
# Usage:
#   source lib/upgrade-manifest.sh
#   get_current_version
#   list_available_upgrades "/path/to/upgrades"
#   parse_manifest "/path/to/upgrades/v0.3.0/manifest.yml"

# Color definitions for consistent output formatting
# Note: These may already be defined by backup.sh or run.sh, so we check first
if [[ -z "${GREEN:-}" ]]; then
    readonly GREEN='\033[0;32m'
fi
if [[ -z "${YELLOW:-}" ]]; then
    readonly YELLOW='\033[1;33m'
fi
if [[ -z "${RED:-}" ]]; then
    readonly RED='\033[0;31m'
fi
if [[ -z "${BLUE:-}" ]]; then
    readonly BLUE='\033[0;34m'
fi
if [[ -z "${NC:-}" ]]; then
    readonly NC='\033[0m' # No Color
fi

# Global configuration variables
UPGRADES_BASE_DIR="${UPGRADES_BASE_DIR:-$(dirname "$(dirname "${BASH_SOURCE[0]}")")/upgrades}"
VERSION_FILE="current_version.txt"

# Parsed manifest data (populated by parse_manifest)
MANIFEST_VERSION=""
MANIFEST_FROM_VERSION=""
MANIFEST_DESCRIPTION=""
declare -a MANIFEST_BREAKING_CHANGES=()
declare -a MANIFEST_PRE_FLIGHT=()
declare -a MANIFEST_STEPS=()
declare -a MANIFEST_VALIDATION=()
declare -a MANIFEST_ROLLBACK_STEPS=()
MANIFEST_BACKUP_DATABASE=""
MANIFEST_BACKUP_REDIS=""
MANIFEST_BACKUP_CODE=""
MANIFEST_ROLLBACK_AUTOMATIC=""

# check_yq_installed - Verify that yq is installed and available
#
# Returns:
#   0 - yq is installed
#   1 - yq is not installed (prints installation instructions)
check_yq_installed() {
    if ! command -v yq &> /dev/null; then
        echo -e "${RED}[upgrade-manifest]${NC} Error: yq command not found"
        echo -e "${YELLOW}[upgrade-manifest]${NC} yq is required for parsing YAML manifests"
        echo ""
        echo -e "${BLUE}[upgrade-manifest]${NC} Install yq using one of these methods:"
        echo -e "  ${GREEN}sudo snap install yq${NC}        # Recommended for Ubuntu/Debian"
        echo -e "  ${GREEN}sudo apt install yq${NC}         # Alternative method"
        echo -e "  ${GREEN}brew install yq${NC}             # For macOS"
        echo ""
        return 1
    fi
    return 0
}

# get_current_version - Get the current installed Infinibay version
#
# Reads the version from the current_version.txt file in the upgrades directory.
#
# Returns:
#   Prints the current version to stdout (e.g., "0.2.0")
#   Prints "unknown" if the version file doesn't exist
get_current_version() {
    local version_path="$UPGRADES_BASE_DIR/$VERSION_FILE"

    if [[ -f "$version_path" ]]; then
        cat "$version_path" | tr -d '\n' | tr -d ' '
    else
        echo "unknown"
    fi
}

# set_current_version - Update the current version tracking file
#
# Arguments:
#   $1 - New version string (e.g., "0.3.0")
#
# Returns:
#   0 - Success
#   1 - Failed to write version file
set_current_version() {
    local new_version="$1"
    local version_path="$UPGRADES_BASE_DIR/$VERSION_FILE"

    if [[ -z "$new_version" ]]; then
        echo -e "${RED}[upgrade-manifest]${NC} Error: Version string is required"
        return 1
    fi

    if ! echo "$new_version" > "$version_path"; then
        echo -e "${RED}[upgrade-manifest]${NC} Error: Failed to write version file"
        return 1
    fi

    echo -e "${GREEN}[upgrade-manifest]${NC} Version updated to: $new_version"
    return 0
}

# parse_manifest - Load and parse a manifest.yml file
#
# Parses the YAML manifest file and populates global variables with the
# extracted data for use by other functions.
#
# Arguments:
#   $1 - Path to manifest.yml file
#
# Populates:
#   MANIFEST_VERSION, MANIFEST_FROM_VERSION, MANIFEST_DESCRIPTION
#   MANIFEST_BREAKING_CHANGES[], MANIFEST_PRE_FLIGHT[], MANIFEST_STEPS[]
#   MANIFEST_VALIDATION[], MANIFEST_BACKUP_*, MANIFEST_ROLLBACK_*
#
# Returns:
#   0 - Success
#   1 - Error (file not found, invalid YAML, etc.)
parse_manifest() {
    local manifest_path="$1"

    # Check yq is installed
    if ! check_yq_installed; then
        return 1
    fi

    # Check manifest file exists
    if [[ ! -f "$manifest_path" ]]; then
        echo -e "${RED}[upgrade-manifest]${NC} Error: Manifest not found: $manifest_path"
        return 1
    fi

    # Reset global variables
    MANIFEST_VERSION=""
    MANIFEST_FROM_VERSION=""
    MANIFEST_DESCRIPTION=""
    MANIFEST_BREAKING_CHANGES=()
    MANIFEST_PRE_FLIGHT=()
    MANIFEST_STEPS=()
    MANIFEST_VALIDATION=()
    MANIFEST_ROLLBACK_STEPS=()
    MANIFEST_BACKUP_DATABASE=""
    MANIFEST_BACKUP_REDIS=""
    MANIFEST_BACKUP_CODE=""
    MANIFEST_ROLLBACK_AUTOMATIC=""

    # Parse basic fields
    set +e
    MANIFEST_VERSION=$(yq '.version' "$manifest_path" 2>/dev/null | tr -d '"')
    MANIFEST_FROM_VERSION=$(yq '.from_version' "$manifest_path" 2>/dev/null | tr -d '"')
    MANIFEST_DESCRIPTION=$(yq '.description' "$manifest_path" 2>/dev/null | tr -d '"')

    # Parse backup configuration
    MANIFEST_BACKUP_DATABASE=$(yq '.backup.database' "$manifest_path" 2>/dev/null | tr -d '"')
    MANIFEST_BACKUP_REDIS=$(yq '.backup.redis' "$manifest_path" 2>/dev/null | tr -d '"')
    MANIFEST_BACKUP_CODE=$(yq '.backup.code' "$manifest_path" 2>/dev/null | tr -d '"')

    # Parse rollback configuration
    MANIFEST_ROLLBACK_AUTOMATIC=$(yq '.rollback.automatic' "$manifest_path" 2>/dev/null | tr -d '"')

    # Parse breaking changes array
    local breaking_count
    breaking_count=$(yq '.breaking_changes | length' "$manifest_path" 2>/dev/null)
    if [[ "$breaking_count" =~ ^[0-9]+$ ]] && [[ "$breaking_count" -gt 0 ]]; then
        for ((i=0; i<breaking_count; i++)); do
            local change
            change=$(yq ".breaking_changes[$i]" "$manifest_path" 2>/dev/null | tr -d '"')
            MANIFEST_BREAKING_CHANGES+=("$change")
        done
    fi

    # Parse pre_flight checks array (store as JSON strings for later parsing)
    local preflight_count
    preflight_count=$(yq '.pre_flight | length' "$manifest_path" 2>/dev/null)
    if [[ "$preflight_count" =~ ^[0-9]+$ ]] && [[ "$preflight_count" -gt 0 ]]; then
        for ((i=0; i<preflight_count; i++)); do
            local check_json
            check_json=$(yq -o=json ".pre_flight[$i]" "$manifest_path" 2>/dev/null)
            MANIFEST_PRE_FLIGHT+=("$check_json")
        done
    fi

    # Parse steps array (store as JSON strings for later parsing)
    local steps_count
    steps_count=$(yq '.steps | length' "$manifest_path" 2>/dev/null)
    if [[ "$steps_count" =~ ^[0-9]+$ ]] && [[ "$steps_count" -gt 0 ]]; then
        for ((i=0; i<steps_count; i++)); do
            local step_json
            step_json=$(yq -o=json ".steps[$i]" "$manifest_path" 2>/dev/null)
            MANIFEST_STEPS+=("$step_json")
        done
    fi

    # Parse validation checks array (store as JSON strings for later parsing)
    local validation_count
    validation_count=$(yq '.validation | length' "$manifest_path" 2>/dev/null)
    if [[ "$validation_count" =~ ^[0-9]+$ ]] && [[ "$validation_count" -gt 0 ]]; then
        for ((i=0; i<validation_count; i++)); do
            local check_json
            check_json=$(yq -o=json ".validation[$i]" "$manifest_path" 2>/dev/null)
            MANIFEST_VALIDATION+=("$check_json")
        done
    fi

    # Parse rollback.steps array (store as JSON strings for later parsing)
    local rollback_steps_count
    rollback_steps_count=$(yq '.rollback.steps | length' "$manifest_path" 2>/dev/null)
    if [[ "$rollback_steps_count" =~ ^[0-9]+$ ]] && [[ "$rollback_steps_count" -gt 0 ]]; then
        for ((i=0; i<rollback_steps_count; i++)); do
            local step_json
            step_json=$(yq -o=json ".rollback.steps[$i]" "$manifest_path" 2>/dev/null)
            MANIFEST_ROLLBACK_STEPS+=("$step_json")
        done
    fi
    set -e

    # Validate required fields were parsed
    if [[ -z "$MANIFEST_VERSION" ]] || [[ "$MANIFEST_VERSION" == "null" ]]; then
        echo -e "${RED}[upgrade-manifest]${NC} Error: Failed to parse 'version' from manifest"
        return 1
    fi

    if [[ -z "$MANIFEST_FROM_VERSION" ]] || [[ "$MANIFEST_FROM_VERSION" == "null" ]]; then
        echo -e "${RED}[upgrade-manifest]${NC} Error: Failed to parse 'from_version' from manifest"
        return 1
    fi

    return 0
}

# validate_manifest - Validate manifest structure and required fields
#
# Performs comprehensive validation of a manifest file including:
# - Required fields (version, from_version, description)
# - Steps array is not empty
# - Field-level validation for steps (name, script, timeout, rollback_on_fail)
# - Field-level validation for validation checks (name, script, critical)
# - Dependency validation (depends_on references valid step names)
# - Referenced scripts exist and are executable
# - Valid container names
# - Rollback steps script existence
#
# Arguments:
#   $1 - Path to manifest.yml file
#
# Returns:
#   0 - Manifest is valid
#   1 - Manifest validation failed (errors printed to stderr)
validate_manifest() {
    local manifest_path="$1"
    local manifest_dir
    manifest_dir=$(dirname "$manifest_path")
    local validation_errors=0

    echo -e "${BLUE}[upgrade-manifest]${NC} Validating manifest: $manifest_path"

    # Parse the manifest first
    if ! parse_manifest "$manifest_path"; then
        return 1
    fi

    # Check required fields
    if [[ -z "$MANIFEST_VERSION" ]] || [[ "$MANIFEST_VERSION" == "null" ]]; then
        echo -e "${RED}[upgrade-manifest]${NC} ✗ Missing required field: version"
        validation_errors=$((validation_errors + 1))
    else
        echo -e "${GREEN}[upgrade-manifest]${NC} ✓ version: $MANIFEST_VERSION"
    fi

    if [[ -z "$MANIFEST_FROM_VERSION" ]] || [[ "$MANIFEST_FROM_VERSION" == "null" ]]; then
        echo -e "${RED}[upgrade-manifest]${NC} ✗ Missing required field: from_version"
        validation_errors=$((validation_errors + 1))
    else
        echo -e "${GREEN}[upgrade-manifest]${NC} ✓ from_version: $MANIFEST_FROM_VERSION"
    fi

    if [[ -z "$MANIFEST_DESCRIPTION" ]] || [[ "$MANIFEST_DESCRIPTION" == "null" ]]; then
        echo -e "${RED}[upgrade-manifest]${NC} ✗ Missing required field: description"
        validation_errors=$((validation_errors + 1))
    else
        echo -e "${GREEN}[upgrade-manifest]${NC} ✓ description: $MANIFEST_DESCRIPTION"
    fi

    # Check steps array is not empty
    if [[ ${#MANIFEST_STEPS[@]} -eq 0 ]]; then
        echo -e "${RED}[upgrade-manifest]${NC} ✗ Steps array is empty (at least one step required)"
        validation_errors=$((validation_errors + 1))
    else
        echo -e "${GREEN}[upgrade-manifest]${NC} ✓ steps: ${#MANIFEST_STEPS[@]} step(s) defined"
    fi

    # Collect all step names for dependency validation
    local -a step_names=()

    # Validate container names and field-level validation for steps
    local valid_containers=("infinibay-backend" "infinibay-frontend" "infinibay-postgres" "infinibay-redis")
    for step_json in "${MANIFEST_STEPS[@]}"; do
        local step_name step_script step_timeout step_rollback_on_fail container

        step_name=$(echo "$step_json" | yq '.name' 2>/dev/null | tr -d '"')
        step_script=$(echo "$step_json" | yq '.script' 2>/dev/null | tr -d '"')
        step_timeout=$(echo "$step_json" | yq '.timeout' 2>/dev/null | tr -d '"')
        step_rollback_on_fail=$(echo "$step_json" | yq '.rollback_on_fail' 2>/dev/null | tr -d '"')
        container=$(echo "$step_json" | yq '.container' 2>/dev/null | tr -d '"')

        # Validate name is non-empty
        if [[ -z "$step_name" ]] || [[ "$step_name" == "null" ]]; then
            echo -e "${RED}[upgrade-manifest]${NC} ✗ Step missing required field: name"
            validation_errors=$((validation_errors + 1))
        else
            step_names+=("$step_name")
        fi

        # Validate script is non-empty
        if [[ -z "$step_script" ]] || [[ "$step_script" == "null" ]]; then
            echo -e "${RED}[upgrade-manifest]${NC} ✗ Step '$step_name' missing required field: script"
            validation_errors=$((validation_errors + 1))
        fi

        # Validate timeout is numeric if present
        if [[ -n "$step_timeout" ]] && [[ "$step_timeout" != "null" ]]; then
            if ! [[ "$step_timeout" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}[upgrade-manifest]${NC} ✗ Step '$step_name' has non-numeric timeout: $step_timeout"
                validation_errors=$((validation_errors + 1))
            fi
        fi

        # Validate rollback_on_fail is true or false if present
        if [[ -n "$step_rollback_on_fail" ]] && [[ "$step_rollback_on_fail" != "null" ]]; then
            if [[ "$step_rollback_on_fail" != "true" ]] && [[ "$step_rollback_on_fail" != "false" ]]; then
                echo -e "${RED}[upgrade-manifest]${NC} ✗ Step '$step_name' has invalid rollback_on_fail: $step_rollback_on_fail (must be true or false)"
                validation_errors=$((validation_errors + 1))
            fi
        fi

        # Validate container name
        if [[ -n "$container" ]] && [[ "$container" != "null" ]]; then
            local is_valid=0
            for valid in "${valid_containers[@]}"; do
                if [[ "$container" == "$valid" ]]; then
                    is_valid=1
                    break
                fi
            done
            if [[ $is_valid -eq 0 ]]; then
                echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Unknown container in step '$step_name': $container"
            fi
        fi
    done

    # Second pass: validate depends_on references
    for step_json in "${MANIFEST_STEPS[@]}"; do
        local step_name depends_on_type depends_on_count

        step_name=$(echo "$step_json" | yq '.name' 2>/dev/null | tr -d '"')
        depends_on_type=$(echo "$step_json" | yq '.depends_on | type' 2>/dev/null | tr -d '"')

        if [[ "$depends_on_type" == "!!seq" ]]; then
            depends_on_count=$(echo "$step_json" | yq '.depends_on | length' 2>/dev/null)
            if [[ "$depends_on_count" =~ ^[0-9]+$ ]] && [[ "$depends_on_count" -gt 0 ]]; then
                for ((i=0; i<depends_on_count; i++)); do
                    local dep_name
                    dep_name=$(echo "$step_json" | yq ".depends_on[$i]" 2>/dev/null | tr -d '"')
                    if [[ -n "$dep_name" ]] && [[ "$dep_name" != "null" ]]; then
                        # Check if dependency exists in step_names
                        local dep_found=0
                        for existing_name in "${step_names[@]}"; do
                            if [[ "$existing_name" == "$dep_name" ]]; then
                                dep_found=1
                                break
                            fi
                        done
                        if [[ $dep_found -eq 0 ]]; then
                            echo -e "${RED}[upgrade-manifest]${NC} ✗ Step '$step_name' depends on unknown step: $dep_name"
                            validation_errors=$((validation_errors + 1))
                        fi
                    fi
                done
            fi
        elif [[ -n "$depends_on_type" ]] && [[ "$depends_on_type" != "null" ]] && [[ "$depends_on_type" != "!!null" ]]; then
            echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Step '$step_name' has depends_on that is not an array"
        fi
    done

    # Validate pre-flight checks (name, script, and executability)
    for check_json in "${MANIFEST_PRE_FLIGHT[@]}"; do
        local check_name check_script script_path

        check_name=$(echo "$check_json" | yq '.name' 2>/dev/null | tr -d '"')
        check_script=$(echo "$check_json" | yq '.script' 2>/dev/null | tr -d '"')

        # Validate name is non-empty
        if [[ -z "$check_name" ]] || [[ "$check_name" == "null" ]]; then
            echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Pre-flight check missing name field"
        fi

        # Validate script is non-empty and check existence/executability
        if [[ -z "$check_script" ]] || [[ "$check_script" == "null" ]]; then
            echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Pre-flight check '$check_name' missing script field"
        else
            script_path="$manifest_dir/$check_script"
            if [[ ! -f "$script_path" ]]; then
                echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Pre-flight script not found: $check_script"
            elif [[ ! -x "$script_path" ]]; then
                echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Pre-flight script not executable: $check_script (may fail at runtime)"
            fi
        fi
    done

    # Validate validation checks (name, script, critical, and executability)
    for check_json in "${MANIFEST_VALIDATION[@]}"; do
        local check_name check_script check_critical script_path

        check_name=$(echo "$check_json" | yq '.name' 2>/dev/null | tr -d '"')
        check_script=$(echo "$check_json" | yq '.script' 2>/dev/null | tr -d '"')
        check_critical=$(echo "$check_json" | yq '.critical' 2>/dev/null | tr -d '"')

        # Validate name is non-empty
        if [[ -z "$check_name" ]] || [[ "$check_name" == "null" ]]; then
            echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Validation check missing name field"
        fi

        # Validate script is non-empty and check existence/executability
        if [[ -z "$check_script" ]] || [[ "$check_script" == "null" ]]; then
            echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Validation check '$check_name' missing script field"
        else
            script_path="$manifest_dir/$check_script"
            if [[ ! -f "$script_path" ]]; then
                echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Validation script not found: $check_script"
            elif [[ ! -x "$script_path" ]]; then
                echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Validation script not executable: $check_script (may fail at runtime)"
            fi
        fi

        # Validate critical is true or false if present
        if [[ -n "$check_critical" ]] && [[ "$check_critical" != "null" ]]; then
            if [[ "$check_critical" != "true" ]] && [[ "$check_critical" != "false" ]]; then
                echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Validation check '$check_name' has invalid critical: $check_critical (should be true or false)"
            fi
        fi
    done

    # Validate rollback steps (script existence)
    for step_json in "${MANIFEST_ROLLBACK_STEPS[@]}"; do
        local step_name step_script script_path

        step_name=$(echo "$step_json" | yq '.name' 2>/dev/null | tr -d '"')
        step_script=$(echo "$step_json" | yq '.script' 2>/dev/null | tr -d '"')

        if [[ -n "$step_script" ]] && [[ "$step_script" != "null" ]]; then
            script_path="$manifest_dir/$step_script"
            if [[ ! -f "$script_path" ]]; then
                echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Rollback script not found: $step_script"
            elif [[ ! -x "$script_path" ]]; then
                echo -e "${YELLOW}[upgrade-manifest]${NC} ⚠ Rollback script not executable: $step_script (may fail at runtime)"
            fi
        fi
    done

    # Final result
    echo ""
    if [[ $validation_errors -gt 0 ]]; then
        echo -e "${RED}[upgrade-manifest]${NC} Validation FAILED with $validation_errors error(s)"
        return 1
    else
        echo -e "${GREEN}[upgrade-manifest]${NC} Validation PASSED"
        return 0
    fi
}

# check_version_compatibility - Check if upgrade is compatible with current version
#
# Compares the current system version with the manifest's from_version field.
#
# Arguments:
#   $1 - Path to manifest.yml file (must be parsed first)
#
# Returns:
#   0 - Compatible (current version == from_version)
#   1 - Incompatible (version mismatch)
check_version_compatibility() {
    local manifest_path="$1"
    local current_version

    current_version=$(get_current_version)

    # Parse manifest if not already parsed
    if [[ -z "$MANIFEST_FROM_VERSION" ]]; then
        if ! parse_manifest "$manifest_path"; then
            return 1
        fi
    fi

    if [[ "$current_version" == "$MANIFEST_FROM_VERSION" ]]; then
        return 0
    else
        echo -e "${RED}[upgrade-manifest]${NC} Version incompatible"
        echo -e "${RED}[upgrade-manifest]${NC} Current version: $current_version"
        echo -e "${RED}[upgrade-manifest]${NC} Required version: $MANIFEST_FROM_VERSION"
        echo -e "${YELLOW}[upgrade-manifest]${NC} Hint: You may need to upgrade incrementally"
        return 1
    fi
}

# list_available_upgrades - List all available upgrades with compatibility status
#
# Scans the upgrades directory for version subdirectories, parses each manifest,
# and displays a formatted list showing version, description, and compatibility.
#
# Arguments:
#   $1 - Path to upgrades directory (optional, defaults to UPGRADES_BASE_DIR)
#
# Returns:
#   0 - Success
#   1 - Error (directory not found, etc.)
list_available_upgrades() {
    local upgrades_dir="${1:-$UPGRADES_BASE_DIR}"
    local current_version
    local found_upgrades=0

    # Check yq is installed
    if ! check_yq_installed; then
        return 1
    fi

    # Check upgrades directory exists
    if [[ ! -d "$upgrades_dir" ]]; then
        echo -e "${YELLOW}[upgrade-manifest]${NC} No upgrades directory found: $upgrades_dir"
        echo -e "${YELLOW}[upgrade-manifest]${NC} No upgrades available"
        return 0
    fi

    # Get current version
    current_version=$(get_current_version)

    # Find all version directories (matching v*)
    local version_dirs
    version_dirs=$(find "$upgrades_dir" -maxdepth 1 -type d -name "v*" | sort -V)

    if [[ -z "$version_dirs" ]]; then
        echo -e "${YELLOW}[upgrade-manifest]${NC} No upgrade versions found in: $upgrades_dir"
        return 0
    fi

    # Display header
    echo -e "${BLUE}Available Upgrades:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    printf "  %-12s %-14s %-12s %s\n" "VERSION" "FROM" "STATUS" "DESCRIPTION"
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"

    while IFS= read -r version_dir; do
        if [[ -z "$version_dir" ]]; then
            continue
        fi

        local manifest_path="$version_dir/manifest.yml"
        local version_name
        version_name=$(basename "$version_dir")

        if [[ ! -f "$manifest_path" ]]; then
            printf "  ${YELLOW}%-12s${NC} %-14s %-12s %s\n" "$version_name" "-" "NO MANIFEST" "manifest.yml not found"
            continue
        fi

        # Parse manifest (suppress output)
        set +e
        parse_manifest "$manifest_path" > /dev/null 2>&1
        local parse_status=$?
        set -e

        if [[ $parse_status -ne 0 ]]; then
            printf "  ${RED}%-12s${NC} %-14s %-12s %s\n" "$version_name" "-" "INVALID" "Failed to parse manifest"
            continue
        fi

        found_upgrades=$((found_upgrades + 1))

        # Determine compatibility status
        local status_text
        local status_color

        if [[ "$current_version" == "unknown" ]]; then
            status_text="UNKNOWN"
            status_color="$YELLOW"
        elif [[ "$current_version" == "$MANIFEST_FROM_VERSION" ]]; then
            status_text="COMPATIBLE"
            status_color="$GREEN"
        elif [[ "$current_version" == "$MANIFEST_VERSION" ]]; then
            status_text="INSTALLED"
            status_color="$BLUE"
        else
            status_text="SKIP"
            status_color="$YELLOW"
        fi

        # Truncate description if too long
        local desc="$MANIFEST_DESCRIPTION"
        if [[ ${#desc} -gt 35 ]]; then
            desc="${desc:0:32}..."
        fi

        printf "  ${status_color}%-12s${NC} %-14s ${status_color}%-12s${NC} %s\n" \
            "$MANIFEST_VERSION" \
            "$MANIFEST_FROM_VERSION" \
            "$status_text" \
            "$desc"

    done <<< "$version_dirs"

    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "${BLUE}Legend:${NC}"
    echo -e "  ${GREEN}COMPATIBLE${NC}  - Can upgrade from current version"
    echo -e "  ${BLUE}INSTALLED${NC}   - This version is currently installed"
    echo -e "  ${YELLOW}SKIP${NC}        - Requires different version (upgrade incrementally)"
    echo -e "  ${YELLOW}UNKNOWN${NC}     - Current version unknown"
    echo ""

    if [[ $found_upgrades -eq 0 ]]; then
        echo -e "${YELLOW}No valid upgrades found${NC}"
    else
        echo -e "Found ${GREEN}$found_upgrades${NC} upgrade(s)"
    fi

    return 0
}

# get_manifest_field - Get a specific field from a parsed manifest step or check
#
# Helper function to extract fields from JSON-encoded step/check data.
#
# Arguments:
#   $1 - JSON string (from MANIFEST_STEPS or MANIFEST_PRE_FLIGHT array)
#   $2 - Field name (e.g., "name", "script", "container")
#
# Returns:
#   Prints field value to stdout
get_manifest_field() {
    local json="$1"
    local field="$2"

    echo "$json" | yq ".$field" 2>/dev/null | tr -d '"'
}

# display_breaking_changes - Display breaking changes for user confirmation
#
# Formats and displays the breaking changes from a parsed manifest
# for user review before proceeding with upgrade.
#
# Returns:
#   0 - Always succeeds
display_breaking_changes() {
    if [[ ${#MANIFEST_BREAKING_CHANGES[@]} -eq 0 ]]; then
        echo -e "${GREEN}[upgrade-manifest]${NC} No breaking changes in this upgrade"
        return 0
    fi

    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║                    ⚠️  BREAKING CHANGES                       ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    for change in "${MANIFEST_BREAKING_CHANGES[@]}"; do
        echo -e "  ${RED}•${NC} $change"
    done

    echo ""
    return 0
}

# display_upgrade_summary - Display summary of an upgrade before execution
#
# Shows version info, breaking changes, steps count, and asks for confirmation.
#
# Arguments:
#   $1 - Path to manifest.yml file
#
# Returns:
#   0 - Always succeeds (informational only)
display_upgrade_summary() {
    local manifest_path="$1"

    # Ensure manifest is parsed
    if [[ -z "$MANIFEST_VERSION" ]]; then
        if ! parse_manifest "$manifest_path"; then
            return 1
        fi
    fi

    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              Upgrade Summary: $MANIFEST_FROM_VERSION → $MANIFEST_VERSION${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Description:${NC} $MANIFEST_DESCRIPTION"
    echo ""
    echo -e "${BLUE}Upgrade Steps:${NC} ${#MANIFEST_STEPS[@]}"
    echo -e "${BLUE}Pre-flight Checks:${NC} ${#MANIFEST_PRE_FLIGHT[@]}"
    echo -e "${BLUE}Validation Checks:${NC} ${#MANIFEST_VALIDATION[@]}"
    echo ""
    echo -e "${BLUE}Backup Configuration:${NC}"
    echo -e "  Database: ${MANIFEST_BACKUP_DATABASE:-true}"
    echo -e "  Redis: ${MANIFEST_BACKUP_REDIS:-false}"
    echo -e "  Code: ${MANIFEST_BACKUP_CODE:-true}"
    echo ""
    echo -e "${BLUE}Rollback:${NC} ${MANIFEST_ROLLBACK_AUTOMATIC:-true} (automatic on failure)"
    echo ""

    # Show breaking changes if any
    display_breaking_changes

    return 0
}
