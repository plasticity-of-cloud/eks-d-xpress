#!/bin/bash
set -e

echo "Installing containerd..."
sudo dnf install -y containerd

echo "Enabling containerd service..."
sudo systemctl enable containerd
sudo systemctl start containerd

echo "✓ containerd installed"
