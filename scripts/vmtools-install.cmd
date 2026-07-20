@echo off
if not exist "C:\Windows\Temp\vmtools-setup.exe" (
    echo missing installer> "C:\Windows\Temp\vmtools-failed.txt"
    exit /b 1
)
"C:\Windows\Temp\vmtools-setup.exe" /S /v/qn REBOOT=ReallySuppress
echo done> "C:\Windows\Temp\vmtools-done.txt"
