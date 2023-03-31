@echo off
echo Building Odin - OIO
setlocal
cd %~dp0

odin run . -o:none -debug -ignore-unknown-attributes

echo Build Done at %time%