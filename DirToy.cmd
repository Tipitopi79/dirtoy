@echo off
rem Startet DirToy ohne dauerhaftes Konsolenfenster (Aufruf: Doppelklick).
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0DirToy.ps1"
