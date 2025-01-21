#!/bin/bash

set -e

# Initialize LOG_FILE with a default value
LOG_FILE="/var/log/riverrun_setup.log"

# Load variables from the configuration file
CONFIG_FILE="/etc/riverrun_config.toml"
REPO_CONFIG_FILE="riverrun/riverrun_config.toml"

# Ensure the script runs as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

# Check if the configuration file exists in /etc, and copy it from the repo if not
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Configuration file not found at $CONFIG_FILE. Copying default configuration from the repository." | tee -a "$LOG_FILE"
  if [ -f "$REPO_CONFIG_FILE" ]; then
    cp "$REPO_CONFIG_FILE" "$CONFIG_FILE"
    echo "Default configuration copied to $CONFIG_FILE. Please edit it before proceeding." | tee -a "$LOG_FILE"
    exit 0
  else
    echo "Default configuration file not found in the repository at $REPO_CONFIG_FILE." | tee -a "$LOG_FILE"
    exit 1
  fi
fi

# Source the configuration file
source <(grep -v '^#' "$CONFIG_FILE" | sed 's/ = /=/g')

# Validate required variables
REQUIRED_VARS=("ICECAST_CONF" "SOURCE_PASSWORD_FILE" "RELAY_PASSWORD_FILE" "ADMIN_PASSWORD_FILE" "MUSIC_DIR" "UPLOAD_DIR" "M3U_FILE" "SUBMIT_USER" "SUPPORTED_FORMATS" "BITRATE" "SAMPLE_RATE" "AUDIO_CODEC" "CONVERTER_SCRIPT" "LOG_FILE")
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "Error: Required variable $var is not defined in the configuration file. Please update $CONFIG_FILE and try again." | tee -a "$LOG_FILE"
    exit 1
  fi
done

# Install necessary packages
echo "Installing necessary packages..." | tee -a "$LOG_FILE"
apt update && apt install -y icecast2 ffmpeg | tee -a "$LOG_FILE"

# Enable and start Icecast service
echo "Enabling and starting Icecast service..." | tee -a "$LOG_FILE"
systemctl enable icecast2 | tee -a "$LOG_FILE"
systemctl start icecast2 | tee -a "$LOG_FILE"

# Configure Icecast
echo "Configuring Icecast..." | tee -a "$LOG_FILE"
source_password=$(cat "$SOURCE_PASSWORD_FILE")
relay_password=$(cat "$RELAY_PASSWORD_FILE")
admin_password=$(cat "$ADMIN_PASSWORD_FILE")

sed -i "s/<source-password>hackme<\/source-password>/<source-password>$source_password<\/source-password>/g" "$ICECAST_CONF"
sed -i "s/<relay-password>hackme<\/relay-password>/<relay-password>$relay_password<\/relay-password>/g" "$ICECAST_CONF"
sed -i "s/<admin-password>hackme<\/admin-password>/<admin-password>$admin_password<\/admin-password>/g" "$ICECAST_CONF"
systemctl restart icecast2 | tee -a "$LOG_FILE"

# Create directories
echo "Creating directories..." | tee -a "$LOG_FILE"
mkdir -p "$MUSIC_DIR"
mkdir -p "$UPLOAD_DIR"

# Create the 'submit' user for uploads
echo "Creating submit user..." | tee -a "$LOG_FILE"
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
echo "Creating file converter script..." | tee -a "$LOG_FILE"
cat << EOF > "$CONVERTER_SCRIPT"
#!/bin/bash

UPLOAD_DIR="$UPLOAD_DIR"
MUSIC_DIR="$MUSIC_DIR"
SUPPORTED_FORMATS="$SUPPORTED_FORMATS"
BITRATE="$BITRATE"
SAMPLE_RATE="$SAMPLE_RATE"
AUDIO_CODEC="$AUDIO_CODEC"
LOG_FILE="$LOG_FILE"

echo "Starting conversion at \$(date)" >> "$LOG_FILE"
for file in "$UPLOAD_DIR"/*; do
  if [ -f "$file" ]; then
    extension=".${file##*.}"
    if echo "$SUPPORTED_FORMATS" | grep -q "$extension"; then
      uuid="\$(cat /proc/sys/kernel/random/uuid)"
      target_file="$MUSIC_DIR/\$uuid.ogg"
      if ffmpeg -y -i "$file" -acodec "$AUDIO_CODEC" -b:a "$BITRATE" -ar "$SAMPLE_RATE" "$target_file" >> "$LOG_FILE" 2>&1; then
        rm -f "$file"
        echo "$file converted and moved to \$target_file" >> "$LOG_FILE"
      else
        echo "Failed to convert $file" >> "$LOG_FILE"
      fi
    else
      echo "$file is not a supported format. Deleting..." >> "$LOG_FILE"
      rm -f "$file"
    fi
  fi

done
echo "Conversion process completed at \$(date)" >> "$LOG_FILE"
EOF
chmod +x "$CONVERTER_SCRIPT"

# Schedule the converter script in cron
echo "Scheduling converter script in cron..." | tee -a "$LOG_FILE"
(crontab -l 2>/dev/null; echo "* * * * * $CONVERTER_SCRIPT") | crontab -

# Generate an M3U playlist file
echo "Generating M3U file..." | tee -a "$LOG_FILE"
STREAM_URL="http://$(hostname -I | awk '{print $1}'):8000/stream"
mkdir -p "$(dirname "$M3U_FILE")"
echo "$STREAM_URL" > "$M3U_FILE"
chmod 644 "$M3U_FILE"

echo "An M3U file has been created at $M3U_FILE. Share this file to allow users to connect to the stream." | tee -a "$LOG_FILE"
echo "Setup complete. Icecast is running, and the upload and conversion system is ready." | tee -a "$LOG_FILE"
echo "Upload files to $UPLOAD_DIR via SSH as the $SUBMIT_USER user." | tee -a "$LOG_FILE"
echo "Converted files will be available in $MUSIC_DIR." | tee -a "$LOG_FILE"
