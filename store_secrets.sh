#!/bin/bash

set -e

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

# Variables
SECRETS_DIR="/etc/secrets"
PASSWORDS=("source_password" "relay_password" "admin_password")
SALT_LENGTH=16

# Ensure secrets directory exists
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Generate a random salt
generate_salt() {
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$SALT_LENGTH"
}

# Hash a password with salt
hash_password() {
  local password="$1"
  local salt="$2"
  echo -n "$salt$password" | sha256sum | awk '{print $1}'
}

# Prompt for passwords, salt, hash, and save
for password_name in "${PASSWORDS[@]}"; do
  echo "Enter $password_name:"
  read -s password
  echo
  salt=$(generate_salt)
  hashed_password=$(hash_password "$password" "$salt")
  echo "$salt:$hashed_password" > "$SECRETS_DIR/$password_name"
  chmod 600 "$SECRETS_DIR/$password_name"
  echo "$password_name stored securely in $SECRETS_DIR/$password_name."
done

echo "All passwords have been salted, hashed, and securely stored."
