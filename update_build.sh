#!/bin/bash
# 自动更新版本号脚本
# 使用方法: ./update_build.sh

# 获取git提交次数
BUILD_NUMBER=$(git rev-list --count HEAD)

# 更新 version_service.dart 中的 build 号
sed -i "s/static const int _currentBuild = [0-9]*;/static const int _currentBuild = $BUILD_NUMBER;/" lib/services/version_service.dart

# 更新 pubspec.yaml 中的版本号
VERSION="1.0.5+$BUILD_NUMBER"
sed -i "s/^version: .*/version: $VERSION/" pubspec.yaml

# 更新 version.json 中的 build_number
sed -i "s/\"build_number\": [0-9]*/\"build_number\": $BUILD_NUMBER/" version.json

echo "已更新版本号: v1.0.5 build$BUILD_NUMBER"
