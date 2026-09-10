@echo off
chcp 65001 >nul
echo =========================================
echo    CelechronCUFE Android APK Build Script
echo =========================================
echo.

set JAVA_HOME=D:\program x86\jdk-17.0.1

echo [1/2] Stopping gradle daemons to free memory...
cd android
call gradlew.bat --stop
cd ..

echo.
echo [2/2] Running flutter build apk...
call flutter build apk

echo.
echo =========================================
if %errorlevel% equ 0 (
    echo Build SUCCESS! 
    echo APK is at: build\app\outputs\flutter-apk\app-release.apk
) else (
    echo Build FAILED. Check the logs above.
)
echo =========================================
pause
