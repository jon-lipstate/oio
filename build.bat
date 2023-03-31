@echo off
echo Building Odin - OIO
setlocal
cd %~dp0

odin build . -o:none -debug -ignore-unknown-attributes

echo Build Done at %time%