#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY_NAME="picoclaw"
BUILD_DIR="$SCRIPT_DIR/build"
CMD_DIR="$SCRIPT_DIR/cmd/$BINARY_NAME"

# Detect platform
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
esac

BINARY="$BUILD_DIR/${BINARY_NAME}-${OS}-${ARCH}"
BINARY_LINK="$BUILD_DIR/$BINARY_NAME"

# Load .env if present
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

build() {
    echo "Building $BINARY_NAME for $OS/$ARCH..."
    mkdir -p "$BUILD_DIR"

    VERSION="$(git -C "$SCRIPT_DIR" describe --tags --always --dirty 2>/dev/null || echo "dev")"
    BUILD_TIME="$(date +%FT%T%z)"
    GO_VER="$(go version | awk '{print $3}')"
    LDFLAGS="-X main.version=$VERSION -X main.buildTime=$BUILD_TIME -X main.goVersion=$GO_VER"

    (cd "$SCRIPT_DIR" && go build -v -ldflags "$LDFLAGS" -o "$BINARY" "./cmd/$BINARY_NAME")
    ln -sf "${BINARY_NAME}-${OS}-${ARCH}" "$BINARY_LINK"
    echo "Build complete: $BINARY"
}

ensure_built() {
    if [ ! -x "$BINARY" ]; then
        echo "$BINARY_NAME not built yet. Building..."
        build
    fi
}

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  gateway           Start the gateway server
  agent             Start interactive agent
  chat "message"    Send a single message to the agent
  setup             Initialize config and workspace (onboard)
  status            Show picoclaw status
  build             Build the binary
  rebuild           Clean and rebuild
  help              Show this help

Options:
  -d, --debug       Enable debug mode

Examples:
  $0 gateway                    # Start gateway server
  $0 gateway -d                 # Start gateway with debug
  $0 agent                      # Interactive agent
  $0 chat "What is the weather?"  # One-shot message
  $0 setup                      # First-time setup
EOF
}

case "${1:-help}" in
    gateway)
        ensure_built
        shift
        exec "$BINARY_LINK" gateway "$@"
        ;;
    agent)
        ensure_built
        shift
        exec "$BINARY_LINK" agent "$@"
        ;;
    chat)
        ensure_built
        shift
        if [ $# -eq 0 ]; then
            echo "Error: message required"
            echo "Usage: $0 chat \"your message\""
            exit 1
        fi
        exec "$BINARY_LINK" agent -m "$*"
        ;;
    setup|onboard)
        ensure_built
        exec "$BINARY_LINK" onboard
        ;;
    status)
        ensure_built
        exec "$BINARY_LINK" status
        ;;
    build)
        build
        ;;
    rebuild)
        rm -rf "$BUILD_DIR"
        build
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Unknown command: $1"
        usage
        exit 1
        ;;
esac
