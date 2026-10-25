@echo off
mode con cp select=437 >nul

rem Install staged virtio drivers (incl netkvm NIC) into the booted OS.
rem Idempotent: pnputil treats already-present drivers as no-op.
if exist "%SystemDrive%\drivers" (
    pnputil /add-driver "%SystemDrive%\drivers\*.inf" /subdirs /install
    rmdir /s /q "%SystemDrive%\drivers"
)

del "%~f0"
