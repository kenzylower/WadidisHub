#!/bin/bash
echo "Installing Lua..."
apt-get update && apt-get install -y lua5.3
echo "Installing Node dependencies..."
npm install