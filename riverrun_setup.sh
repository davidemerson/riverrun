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
REQUIRED_VARS=("ICECAST_CONF" "SOURCE_PASSWORD_FILE" "RELAY_PASSWORD_FILE" "ADMIN_PASSWORD_FILE" "MUSIC_DIR" "UPLOAD_DIR" "M3U_FILE" "SUBMIT_USER" "SUPPORTED_FORMATS" "BITRATE" "SAMPLE_RATE" "AUDIO_CODEC" "CONVERTER_SCRIPT" "LOG_FILE" "ICECAST_LOCATION" "ICECAST_ADMIN_EMAIL" "ICECAST_MAX_CLIENTS" "ICECAST_MAX_SOURCES" "ICECAST_HOSTNAME")
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

sed -i "s|<location>.*</location>|<location>$ICECAST_LOCATION</location>|g" "$ICECAST_CONF"
sed -i "s|<admin>.*</admin>|<admin>$ICECAST_ADMIN_EMAIL</admin>|g" "$ICECAST_CONF"
sed -i "s|<clients>.*</clients>|<clients>$ICECAST_MAX_CLIENTS</clients>|g" "$ICECAST_CONF"
sed -i "s|<sources>.*</sources>|<sources>$ICECAST_MAX_SOURCES</sources>|g" "$ICECAST_CONF"
sed -i "s|<source-password>.*</source-password>|<source-password>$source_password</source-password>|g" "$ICECAST_CONF"
sed -i "s|<relay-password>.*</relay-password>|<relay-password>$relay_password</relay-password>|g" "$ICECAST_CONF"
sed -i "s|<admin-password>.*</admin-password>|<admin-password>$admin_password</admin-password>|g" "$ICECAST_CONF"
sed -i "s|<hostname>.*</hostname>|<hostname>$ICECAST_HOSTNAME</hostname>|g" "$ICECAST_CONF"

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

# Ensure /var/music has the correct permissions
if [ ! -w "$MUSIC_DIR" ]; then
  echo "Error: Cannot write to target directory $MUSIC_DIR. Attempting to fix permissions..." | tee -a "$LOG_FILE"
  sudo chown -R "$SUBMIT_USER:$SUBMIT_USER" "$MUSIC_DIR"
  sudo chmod -R 755 "$MUSIC_DIR"
  if [ ! -w "$MUSIC_DIR" ]; then
    echo "Error: Still cannot write to $MUSIC_DIR after attempting to fix permissions." | tee -a "$LOG_FILE"
    exit 1
  fi
fi

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
LOCK_FILE="/tmp/riverrun_converter.lock"

if [ -f "\$LOCK_FILE" ]; then
  echo "Script already running. Exiting." >> "\$LOG_FILE"
  exit 1
fi

trap 'rm -f "\$LOCK_FILE"' EXIT
touch "\$LOCK_FILE"

echo "Starting file detection in \$UPLOAD_DIR at \$(date)" >> "\$LOG_FILE"
if [ ! -w "\$MUSIC_DIR" ]; then
  echo "Error: Cannot write to target directory \$MUSIC_DIR. Check permissions." >> "\$LOG_FILE"
  exit 1
fi

files_found=0
for file in "\$UPLOAD_DIR"/*; do
  echo "Checking file: \$file" >> "\$LOG_FILE"
  if [ -f "\$file" ]; then
    files_found=1
    echo "Processing file: \$file" >> "\$LOG_FILE"
    if [ ! -r "\$file" ]; then
      echo "Error: Cannot read file \$file. Check permissions." >> "\$LOG_FILE"
      continue
    fi

    extension=".\${file##*.}"
    echo "Detected extension: \$extension for \$file" >> "\$LOG_FILE"
    if echo "\$SUPPORTED_FORMATS" | grep -q "\$extension"; then
      uuid="\$(cat /proc/sys/kernel/random/uuid)"
      target_file="\$MUSIC_DIR/\$uuid.ogg"
      echo "Converting \$file to \$target_file with ffmpeg..." >> "\$LOG_FILE"
      if ffmpeg -y -i "\$file" -acodec "\$AUDIO_CODEC" -b:a "\$BITRATE" -ar "\$SAMPLE_RATE" "\$target_file" >> "\$LOG_FILE" 2>&1; then
        rm -f "\$file"
        echo "Successfully converted \$file to \$target_file" >> "\$LOG_FILE"
      else
        echo "Error: Failed to convert \$file" >> "\$LOG_FILE"
      fi
    else
      echo "Unsupported file format for \$file. Deleting..." >> "\$LOG_FILE"
      rm -f "\$file"
    fi
  else
    echo "Skipping non-file or missing file: \$file" >> "\$LOG_FILE"
  fi

done

if [ \$files_found -eq 0 ]; then
  echo "No files found in \$UPLOAD_DIR to process." >> "\$LOG_FILE"
fi

echo "File detection completed at \$(date)" >> "\$LOG_FILE"
EOF
chmod +x "$CONVERTER_SCRIPT"

# Clean existing crontab for the submit user and set up the new cron job
echo "Scheduling converter script in cron..." | tee -a "$LOG_FILE"
sudo crontab -u "$SUBMIT_USER" -r 2>/dev/null || true
{
  echo "* * * * * $CONVERTER_SCRIPT"
} | sudo crontab -u "$SUBMIT_USER" -

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
