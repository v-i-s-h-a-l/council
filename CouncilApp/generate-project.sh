#!/bin/bash
set -e

cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Error: xcodegen is required to generate the Xcode project."
    echo "Install it with: brew install xcodegen"
    exit 1
fi

xcodegen generate --spec project.yml --project .

echo "Generated CouncilApp.xcodeproj"
echo "Open it in Xcode and build for macOS 14+ or iOS 17+."
echo "To build for iOS, change the target platform in project.yml to 'iOS' and re-run this script."
