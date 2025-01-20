#!/bin/sh

# Define directories (space-separated list instead of array)
SRC_DIRS="uploader converter streamer"
BUILD_DIR="build"
INSTALL_DIR="/usr/local/bin"

# Function to install curl and sudo
install_essential_tools() {
    echo "Checking for essential tools: curl and sudo..."
    if ! command -v curl >/dev/null 2>&1; then
        echo "curl is not installed. Attempting to install it..."
        if command -v apt >/dev/null 2>&1; then
            sudo apt update && sudo apt install -y curl
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y curl
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y curl
        elif command -v pkg_add >/dev/null 2>&1; then
            echo "Using pkg_add to install curl (OpenBSD)..."
            sudo pkg_add curl
        else
            echo "No supported package manager found. Please install curl manually."
            exit 1
        fi
    else
        echo "curl is already installed."
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        echo "sudo is not installed. Attempting to install it..."
        if command -v apt >/dev/null 2>&1; then
            apt update && apt install -y sudo
        elif command -v yum >/dev/null 2>&1; then
            yum install -y sudo
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y sudo
        elif command -v pkg_add >/dev/null 2>&1; then
            echo "Using pkg_add to install sudo (OpenBSD)..."
            pkg_add sudo
        else
            echo "No supported package manager found. Please install sudo manually."
            exit 1
        fi
    else
        echo "sudo is already installed."
    fi
}

# Function to install the latest Go version
install_latest_go() {
    echo "Checking for Go installation..."
    if command -v go >/dev/null 2>&1; then
        CURRENT_GO_VERSION=$(go version | awk '{print $3}')
        echo "Current Go version detected: $CURRENT_GO_VERSION"
    else
        CURRENT_GO_VERSION=""
        echo "Go is not installed."
    fi

    echo "Fetching the latest Go version..."
    LATEST_GO_VERSION=$(curl -s https://go.dev/VERSION?m=text)
    if [ "$LATEST_GO_VERSION" = "$CURRENT_GO_VERSION" ]; then
        echo "The latest Go version ($LATEST_GO_VERSION) is already installed."
        return
    fi

    echo "Installing Go $LATEST_GO_VERSION..."
    OS=$(uname | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
    GO_TARBALL="${LATEST_GO_VERSION}.${OS}-${ARCH}.tar.gz"

    # Download and install Go
    curl -O "https://go.dev/dl/${GO_TARBALL}"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$GO_TARBALL"
    rm "$GO_TARBALL"

    # Add Go to PATH
    if ! echo "$PATH" | grep -q "/usr/local/go/bin"; then
        echo "export PATH=\$PATH:/usr/local/go/bin" >> ~/.profile
        export PATH=$PATH:/usr/local/go/bin
    fi

    echo "Go $LATEST_GO_VERSION installed successfully."
}

# Function to check and install ffmpeg
check_and_install_ffmpeg() {
    if ! command -v ffmpeg >/dev/null 2>&1; then
        echo "ffmpeg is not installed. Attempting to install it..."
        if command -v apt >/dev/null 2>&1; then
            sudo apt update && sudo apt install -y ffmpeg
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y epel-release && sudo yum install -y ffmpeg
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y ffmpeg
        elif command -v pkg_add >/dev/null 2>&1; then
            echo "Using pkg_add to install ffmpeg (OpenBSD)..."
            sudo pkg_add ffmpeg
        else
            echo "No supported package manager found. Please install ffmpeg manually."
            exit 1
        fi
    else
        echo "ffmpeg is already installed."
    fi
}

# Install essential tools
install_essential_tools

# Install the latest Go version
install_latest_go

# Check and install ffmpeg
check_and_install_ffmpeg

# Create build directory if it doesn't exist
mkdir -p "$BUILD_DIR"

# Process each application
for DIR in $SRC_DIRS; do
    echo "Processing $DIR..."
    cd "$DIR" || exit

    # Initialize go.mod if it doesn't exist
    if [ ! -f "go.mod" ]; then
        echo "Initializing Go module for $DIR..."
        go mod init "$DIR"
    fi

    # Tidy up dependencies
    echo "Tidying up dependencies for $DIR..."
    go mod tidy

    # Build the application
    echo "Building $DIR..."
    go build -o "../$BUILD_DIR/$DIR"
    if [ $? -ne 0 ]; then
        echo "Failed to build $DIR. Exiting."
        exit 1
    fi

    # Return to parent directory
    cd ..
done

# Copy executables to the install directory
echo "Installing executables to $INSTALL_DIR..."
for EXEC in "$BUILD_DIR"/*; do
    sudo cp "$EXEC" "$INSTALL_DIR/"
    if [ $? -ne 0 ]; then
        echo "Failed to install $EXEC. Exiting."
        exit 1
    fi
done

echo "Installation complete."
