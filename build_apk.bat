@echo off
echo =========================================
echo    CelechronCUFE Android APK Build Script
echo =========================================
echo.

set "JAVA_HOME=D:\program x86\jdk-17.0.1"

echo [1/3] Checking version bump...
call dart bump_version.dart
echo.

echo [2/3] Stopping gradle daemons to free memory...
cd android
call gradlew.bat --stop
cd ..

echo.
echo [3/3] Running flutter build apk...
call flutter build apk

echo.
echo =========================================
if %errorlevel% equ 0 (
    echo Build SUCCESS! 
    echo APK is at: build\app\outputs\flutter-apk\app-release.apk
    
    echo.
    echo [4/4] Uploading to OSS...
    python upload_oss.py
    
) else (
    echo Build FAILED. Check the logs above.
)
echo =========================================
pause
