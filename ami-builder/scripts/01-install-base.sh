#!/bin/bash
set -e

echo "Updating system packages..."
sudo dnf update -y

# Disable update-motd — runs dnf updateinfo on every boot (~18s wasted)
echo "Disabling update-motd.service..."
sudo systemctl disable update-motd.service
sudo systemctl disable update-motd.timer 2>/dev/null || true

echo "✓ Base system updated"
