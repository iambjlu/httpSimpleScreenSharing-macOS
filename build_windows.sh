#!/bin/bash

# Windows Client Build Script
# One-click build for httpSimpleScreenSharing Windows client

set -e

# Configuration
REMOTE_USER="Administrator"
REMOTE_HOST="192.168.31.37"
REMOTE_PASS="0000"
REMOTE_WORK_DIR="C:/Users/Administrator/Desktop/Work_DIR"
REMOTE_OUT_DIR="C:/Users/Administrator/Desktop/Release_Intel64"
REMOTE_DESKTOP="C:/Users/Administrator/Desktop"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_ZIP="/tmp/WindowSharingClient.zip"

# SSH options for password auth
SSH_OPTS="-o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no"
SCP_OPTS="-o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no"

echo "🔨 Windows Client Build Started"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check local dependencies
if ! command -v sshpass &> /dev/null; then
    echo "❌ sshpass not found. Install with: brew install sshpass"
    exit 1
fi

if ! command -v zip &> /dev/null; then
    echo "❌ zip not found"
    exit 1
fi

# Check remote dotnet installation (try both paths)
echo "🔍 Checking remote system for .NET SDK..."
DOTNET_PATH=$(sshpass -p "$REMOTE_PASS" ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" \
    "powershell -NoProfile -Command \"if(Test-Path 'C:/Program Files/dotnet/dotnet.exe') { 'C:/Program Files/dotnet/dotnet.exe' } elseif(Test-Path 'C:/Users/Administrator/AppData/Local/Microsoft/dotnet/dotnet.exe') { 'C:/Users/Administrator/AppData/Local/Microsoft/dotnet/dotnet.exe' } else { 'NOT_FOUND' }\"" 2>&1 | tail -1)

if [[ "$DOTNET_PATH" == "NOT_FOUND" ]]; then
    echo "❌ .NET SDK not found on remote machine"
    echo ""
    echo "📋 Required: .NET 8 SDK or later"
    echo "📖 See dotnet_install.md for installation instructions"
    exit 1
fi
echo "✅ .NET SDK found at: $DOTNET_PATH"

# Step 1: Package source
echo ""
echo "📦 Step 1: Packaging source code..."
cd "$PROJECT_DIR"
rm -f "$TEMP_ZIP"
zip -r "$TEMP_ZIP" WindowSharingClient/ \
    -x "*/bin/*" "*/obj/*" "*.user" ".idea/*" > /dev/null
echo "✅ Packaged to $TEMP_ZIP"

# Step 2: Upload to remote
echo ""
echo "📤 Step 2: Uploading to remote (${REMOTE_HOST})..."
sshpass -p "$REMOTE_PASS" scp $SCP_OPTS -r \
    "$TEMP_ZIP" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DESKTOP/WindowSharingClient.zip"
echo "✅ Upload complete"

# Step 3: Execute build on remote
echo ""
echo "🔧 Step 3: Building on remote..."

# Create build command as plain text
# Always force clean rebuild - no caching
BUILD_CMD='$ProgressPreference="SilentlyContinue";$w="C:\Users\Administrator\Desktop\Work_DIR";$o="C:\Users\Administrator\Desktop\Release_Intel64";$z="C:\Users\Administrator\Desktop\WindowSharingClient.zip";Write-Host "Cleaning..."-ForegroundColor Cyan;if(Test-Path $w){Remove-Item -Recurse -Force $w -EA SilentlyContinue};if(Test-Path $o){Remove-Item -Recurse -Force $o -EA SilentlyContinue};[System.IO.Directory]::CreateDirectory($w)|Out-Null;Write-Host "Extracting..."-ForegroundColor Cyan;Expand-Archive $z $w -Force;Write-Host "Building (2-5 min)..."-ForegroundColor Cyan;cd "$w\WindowSharingClient";$buildResult=&"C:\Program Files\dotnet\dotnet.exe" publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $o 2>&1;$buildExit=$LASTEXITCODE;if($buildExit -eq 0 -and (Test-Path "$o\WindowSharingClient.exe")){Write-Host "BUILD SUCCESS!"-ForegroundColor Green;$e=Get-Item "$o\WindowSharingClient.exe";Write-Host "Output: $($e.FullName) ($([math]::Round($e.Length/1MB,2)) MB)"-ForegroundColor Green;Remove-Item -Recurse -Force $w -EA SilentlyContinue}else{Write-Host "BUILD FAILED! Exit code: $buildExit"-ForegroundColor Red;Write-Host "Output: $buildResult"-ForegroundColor Red;exit 1}'

# Encode command to UTF-16LE + Base64
ENCODED=$(echo -n "$BUILD_CMD" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')

# Execute via SSH with encoded command
sshpass -p "$REMOTE_PASS" ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" \
  "powershell.exe -NoProfile -EncodedCommand $ENCODED" 2>&1 | grep -E "Cleaning|Extracting|Building|SUCCESS|FAILED|Output:" || true

echo ""
echo "✅ Build completed successfully!"

# Step 5: Cleanup local temp
echo ""
echo "🧹 Step 5: Cleaning up local temp files..."
rm -f "$TEMP_ZIP"
echo "✅ Cleanup complete"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ Build completed successfully!"
echo ""
echo "📂 Output location:"
echo "   Remote: \\\\$REMOTE_HOST\Users\Administrator\Desktop\Release_Intel64"
echo ""
echo "💡 To download the exe:"
echo "   sshpass -p '0000' scp -r Administrator@192.168.31.37:C:/Users/Administrator/Desktop/Release_Intel64 ./"
