#!/bin/bash

# Define directories
SRC_DIRS=("converter" "streamer" "uploader")  # Replace with your actual directories
BUILD_DIR="build"  # Directory to store the compiled executables
INSTALL_DIR="/usr/local/bin"  # Adjust the install directory as needed

# Function to check and install ffmpeg
check_and_install_ffmpeg() {
    if ! command -v ffmpeg &>/dev/null; then
        echo "ffmpeg is not installed. Attempting to install it..."
        if command -v apt &>/dev/null; then
            echo "Using apt to install ffmpeg..."
            sudo apt update && sudo apt install -y ffmpeg
        elif command -v yum &>/dev/null; then
            echo "Using yum to install ffmpeg..."
            sudo yum install -y epel-release && sudo yum install -y ffmpeg
        elif command -v dnf &>/dev/null; then
            echo "Using dnf to install ffmpeg..."
            sudo dnf install -y ffmpeg
        elif command -v pkg_add &>/dev/null; then
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

# Check and install ffmpeg
check_and_install_ffmpeg

# Create build directory if it doesn't exist
mkdir -p "$BUILD_DIR"

# Process each application
for DIR in "${SRC_DIRS[@]}"; do
    echo "Processing $DIR..."
    cd "$DIR"

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
