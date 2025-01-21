#!/bin/bash

set -e

# Load variables from the configuration file
CONFIG_FILE="/etc/riverrun_config.toml"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Configuration file not found: $CONFIG_FILE"
  exit 1
fi

# Source the configuration file
source <(grep -v '^#' "$CONFIG_FILE" | sed 's/ = /=/g')

# Ensure the script runs as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

# Install necessary packages
echo "Installing necessary packages..."
apt update && apt install -y icecast2 ffmpeg

# Enable and start Icecast service
echo "Enabling and starting Icecast service..."
systemctl enable icecast2
systemctl start icecast2

# Configure Icecast
echo "Configuring Icecast..."
source_password=$(cat "$SOURCE_PASSWORD_FILE")
relay_password=$(cat "$RELAY_PASSWORD_FILE")
admin_password=$(cat "$ADMIN_PASSWORD_FILE")

sed -i "s/<source-password>hackme<\/source-password>/<source-password>$source_password<\/source-password>/g" "$ICECAST_CONF"
sed -i "s/<relay-password>hackme<\/relay-password>/<relay-password>$relay_password<\/relay-password>/g" "$ICECAST_CONF"
sed -i "s/<admin-password>hackme<\/admin-password>/<admin-password>$admin_password<\/admin-password>/g" "$ICECAST_CONF"
systemctl restart icecast2

# Create directories
echo "Creating directories..."
mkdir -p "$MUSIC_DIR"
mkdir -p "$UPLOAD_DIR"

# Create the 'submit' user for uploads
echo "Creating submit user..."
if ! id -u "$SUBMIT_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$SUBMIT_USER"
fi

chown -R "$SUBMIT_USER:$SUBMIT_USER" "$UPLOAD_DIR"
chmod -R 755 "$UPLOAD_DIR"
chmod -R 755 "$MUSIC_DIR"

mkdir -p "/home/$SUBMIT_USER/.ssh"
touch "/home/$SUBMIT_USER/.ssh/authorized_keys"
chown -R "$SUBMIT_USER:$SUBMIT_USER" "/home/$SUBMIT_USER/.ssh"
chmod 700 "/home/$SUBMIT_USER/.ssh"
chmod 600 "/home/$SUBMIT_USER/.ssh/authorized_keys"

# Create the converter script
echo "Creating file converter script..."
cat << EOF > "$CONVERTER_SCRIPT"
#!/bin/bash

UPLOAD_DIR="$UPLOAD_DIR"
MUSIC_DIR="$MUSIC_DIR"
SUPPORTED_FORMATS="$SUPPORTED_FORMATS"
BITRATE="$BITRATE"
SAMPLE_RATE="$SAMPLE_RATE"
AUDIO_CODEC="$AUDIO_CODEC"

for file in "$UPLOAD_DIR"/*; do
  if [ -f "$file" ]; then
    extension=".${file##*.}"
    if echo "$SUPPORTED_FORMATS" | grep -q "$extension"; then
      base_name="\$(basename "$file" "$extension")"
      ffmpeg -y -i "$file" -acodec "$AUDIO_CODEC" -b:a "$BITRATE" -ar "$SAMPLE_RATE" "$MUSIC_DIR/$base_name.ogg" && rm -f "$file"
      echo "$file converted and moved to $MUSIC_DIR"
    else
      echo "$file is not a supported format. Deleting..."
      rm -f "$file"
    fi
  fi
done
EOF
chmod +x "$CONVERTER_SCRIPT"

# Schedule the converter script in cron
echo "Scheduling converter script in cron..."
(crontab -l 2>/dev/null; echo "* * * * * $CONVERTER_SCRIPT") | crontab -

# Final output
echo "Setup complete. Icecast is running, and the upload and conversion system is ready."
echo "Upload files to $UPLOAD_DIR via SSH as the $SUBMIT_USER user."
echo "Converted files will be available in $MUSIC_DIR."
