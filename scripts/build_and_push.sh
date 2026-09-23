#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Usage function
usage() {
    local exit_code="${1:-1}"
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Build and push the causa-mcp container image with multi-architecture support."
    echo ""
    echo "Options:"
    echo "  -i IMAGE_NAME    Full image name (registry/repository:tag)"
    echo "  -r REGISTRY      Container registry (default: quay.io)"
    echo "  -n REPO_NAME     Repository name (default: causa-ai-hub/causa-mcp)"
    echo "  -t TAG           Image tag (default: version from pom.xml)"
    echo "  -p PUSH          Push image true/false (default: true)"
    echo "  -l PLATFORMS     Target platforms (default: linux/amd64,linux/arm64)"
    echo "  -c CLEAN         Run clean build true/false (default: true)"
    echo "  -s SKIP_TESTS    Skip tests during Maven build true/false (default: true)"
    echo "  -h               Show this help message"
    echo ""
    echo "Environment Variables (alternative to flags):"
    echo "  IMAGE_NAME       Full image name"
    echo "  REGISTRY         Container registry"
    echo "  REPO_NAME        Repository name"
    echo "  IMAGE_TAG        Image tag"
    echo "  PUSH_IMAGE       Push image (true/false)"
    echo "  PLATFORMS        Target platforms"
    echo "  CLEAN_BUILD      Clean build (true/false)"
    echo "  SKIP_TESTS       Skip tests (true/false)"
    echo ""
    echo "Examples:"
    echo "  # Build and push with a full image name"
    echo "  $0 -i quay.io/causa-ai-hub/causa-mcp:0.0.2"
    echo ""
    echo "  # Build without pushing (single platform required)"
    echo "  $0 -t 0.0.2 -p false -l linux/amd64"
    echo ""
    echo "  # Build for amd64 only and push"
    echo "  $0 -t 0.0.2 -l linux/amd64"
    echo ""
    echo "Note: Command-line flags take precedence over environment variables"
    exit "${exit_code}"
}

# Validate boolean values
validate_boolean() {
    local value="$1"
    local flag="$2"
    if [[ ! "$value" =~ ^(true|false)$ ]]; then
        echo -e "${RED}Error: $flag must be 'true' or 'false', got: '$value'${NC}" >&2
        usage 1
    fi
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Resolve the project root relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Resolve application version from pom.xml
resolve_app_version() {
    local pom="${PROJECT_ROOT}/pom.xml"
    local ver="latest"
    if [ -f "${pom}" ]; then
        local mvnw="${PROJECT_ROOT}/mvnw"
        local mvn_cmd="mvn"
        [ -f "${mvnw}" ] && mvn_cmd="${mvnw}"
        ver=$(cd "${PROJECT_ROOT}" && \
              ${mvn_cmd} help:evaluate -Dexpression=project.version -q -DforceStdout 2>/dev/null)
        ver="${ver:-latest}"
    fi
    if [[ "$ver" == *SNAPSHOT* ]]; then
        local ts
        ts=$(date -u +"%Y%m%d%H%M%S")
        ver="${ver}-${ts}"
    fi
    echo "$ver"
}

# Default values
REGISTRY="${REGISTRY:-quay.io}"
REPO_NAME="${REPO_NAME:-causa-ai-hub/causa-mcp}"
IMAGE_TAG="${IMAGE_TAG:-$(resolve_app_version)}"
PUSH_IMAGE="${PUSH_IMAGE:-true}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
CLEAN_BUILD="${CLEAN_BUILD:-true}"
SKIP_TESTS="${SKIP_TESTS:-true}"
IMAGE_NAME="${IMAGE_NAME:-}"

# Parse command-line arguments (override env vars)
while getopts "i:r:n:t:p:l:c:s:h" opt; do
    case ${opt} in
        i ) IMAGE_NAME="$OPTARG" ;;
        r ) REGISTRY="$OPTARG" ;;
        n ) REPO_NAME="$OPTARG" ;;
        t ) IMAGE_TAG="$OPTARG" ;;
        p ) PUSH_IMAGE="$OPTARG" ;;
        l ) PLATFORMS="$OPTARG" ;;
        c ) CLEAN_BUILD="$OPTARG" ;;
        s ) SKIP_TESTS="$OPTARG" ;;
        h ) usage 0 ;;
        \? )
            print_error "Invalid option: -$OPTARG"
            usage 1
            ;;
    esac
done

# Validate booleans
validate_boolean "$PUSH_IMAGE"  "PUSH_IMAGE (-p)"
validate_boolean "$CLEAN_BUILD" "CLEAN_BUILD (-c)"
validate_boolean "$SKIP_TESTS"  "SKIP_TESTS (-s)"

# Validate each platform value against the set supported by Quarkus Jib
VALID_PLATFORMS="linux/amd64 linux/arm64 linux/s390x linux/ppc64le"
IFS=',' read -ra plat_arr <<< "$PLATFORMS"
for p in "${plat_arr[@]}"; do
    if [[ ! " ${VALID_PLATFORMS} " =~ " ${p} " ]]; then
        print_error "Unsupported platform: '${p}'. Supported: ${VALID_PLATFORMS}"
        exit 1
    fi
done

# Jib cannot load a multi-platform manifest into the local Docker daemon;
# a registry push is required to store the manifest list.
if [[ "${#plat_arr[@]}" -gt 1 ]] && [ "$PUSH_IMAGE" = "false" ]; then
    print_error "Multi-platform builds (PLATFORMS='${PLATFORMS}') require PUSH_IMAGE=true."
    print_error "Jib cannot load a multi-platform manifest into the local Docker daemon."
    print_error "Either set -p true to push, or specify a single platform with -l."
    exit 1
fi

# Quarkus uses three separate properties to assemble the final image reference:
#   quarkus.container-image.registry  → quay.io
#   quarkus.container-image.group     → yourusername
#   quarkus.container-image.name      → test-img-name
#   quarkus.container-image.tag       → v1
# Using .image overrides all of the above and causes .tag to be ignored, so we
# always derive the three parts from IMAGE_NAME (or REGISTRY + REPO_NAME).
if [ -n "$IMAGE_NAME" ]; then
    # Strip optional embedded tag first
    if [[ "$IMAGE_NAME" == *:* ]]; then
        IMAGE_TAG="${IMAGE_NAME##*:}"
        IMAGE_NAME="${IMAGE_NAME%:*}"
    fi
    # IMAGE_NAME is now registry/group/name or registry/name — split it
    IMAGE_REGISTRY="${IMAGE_NAME%%/*}"
    IMAGE_REST="${IMAGE_NAME#*/}"          # everything after the first /
    # Handle both registry/name (2-segment) and registry/group/name (3-segment)
    if [[ "$IMAGE_REST" == */* ]]; then
        IMAGE_GROUP="${IMAGE_REST%/*}"     # middle segment(s)
        IMAGE_REPO_NAME="${IMAGE_REST##*/}" # final segment
    else
        IMAGE_GROUP=""
        IMAGE_REPO_NAME="${IMAGE_REST}"
    fi
else
    IMAGE_REGISTRY="${REGISTRY}"
    IMAGE_GROUP="${REPO_NAME%/*}"
    IMAGE_REPO_NAME="${REPO_NAME##*/}"
    IMAGE_NAME="${REGISTRY}/${REPO_NAME}"
fi

# Validate project structure
if [ ! -f "${PROJECT_ROOT}/pom.xml" ]; then
    print_error "pom.xml not found at ${PROJECT_ROOT}."
    exit 1
fi

if [ ! -f "${PROJECT_ROOT}/mvnw" ]; then
    print_error "Maven wrapper (mvnw) not found at ${PROJECT_ROOT}."
    exit 1
fi

cd "${PROJECT_ROOT}"
chmod +x ./mvnw

# Display configuration
echo ""
print_info "=== Build Configuration ==="
print_info "Image Name:  ${IMAGE_NAME}:${IMAGE_TAG}"
print_info "Platforms:   ${PLATFORMS}"
print_info "Push:        ${PUSH_IMAGE}"
print_info "Clean Build: ${CLEAN_BUILD}"
print_info "Skip Tests:  ${SKIP_TESTS}"
echo ""

if [ "$PUSH_IMAGE" = "true" ]; then
    print_warn "Push is enabled. Image will be pushed to registry."
    print_warn "Make sure you are authenticated to ${REGISTRY}"
    echo ""
fi

# Build Maven command as an array to avoid eval and shell-injection via user-supplied values.
MAVEN_CMD=(./mvnw)

if [ "$CLEAN_BUILD" = "true" ]; then
    MAVEN_CMD+=(clean)
fi

MAVEN_CMD+=(package)

if [ "$SKIP_TESTS" = "true" ]; then
    MAVEN_CMD+=(-DskipTests)
fi

# Pass container image properties to Quarkus Jib.
# We pass registry/group/name/tag as separate properties so Quarkus correctly
# applies the tag — using .image would cause .tag to be silently ignored.
MAVEN_CMD+=("-Dquarkus.container-image.build=true")
MAVEN_CMD+=("-Dquarkus.container-image.registry=${IMAGE_REGISTRY}")
MAVEN_CMD+=("-Dquarkus.container-image.group=${IMAGE_GROUP}")
MAVEN_CMD+=("-Dquarkus.container-image.name=${IMAGE_REPO_NAME}")
MAVEN_CMD+=("-Dquarkus.container-image.tag=${IMAGE_TAG}")
MAVEN_CMD+=("-Dquarkus.container-image.push=${PUSH_IMAGE}")
MAVEN_CMD+=("-Dquarkus.jib.platforms=${PLATFORMS}")

print_info "Executing Maven command:"
echo "${MAVEN_CMD[*]}"
echo ""

print_info "Starting build process..."
if "${MAVEN_CMD[@]}"; then
    echo ""
    print_info "=== Build Summary ==="
    print_info "✓ Container image built successfully"
    print_info "Image:     ${IMAGE_NAME}:${IMAGE_TAG}"
    print_info "Platforms: ${PLATFORMS}"
    if [ "$PUSH_IMAGE" = "true" ]; then
        print_info "✓ Image pushed to registry"
    else
        print_warn "Image was built but not pushed (PUSH_IMAGE=false)"
    fi
    echo ""
    exit 0
else
    echo ""
    print_error "=== Build Failed ==="
    print_error "Build process failed. Check the logs above for details."
    echo ""
    exit 1
fi
