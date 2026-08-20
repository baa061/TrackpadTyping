@echo off
rem TrackpadTyping build — tries MSVC, then MinGW. Run once; then use TrackpadTyping.exe.
where cl >nul 2>nul
if %errorlevel%==0 (
    echo Building with MSVC...
    cl /nologo /std:c++17 /O2 /EHsc src\main_win32.cpp /Fe:TrackpadTyping.exe user32.lib gdi32.lib shell32.lib
    goto done
)
where g++ >nul 2>nul
if %errorlevel%==0 (
    echo Building with MinGW...
    g++ -std=c++17 -O2 -mwindows -o TrackpadTyping.exe src/main_win32.cpp -lgdi32 -lshell32
    goto done
)
echo No C++ compiler found.
echo Install "Build Tools for Visual Studio" (free) and run this from its
echo "x64 Native Tools Command Prompt", or install MinGW-w64 from winlibs.com.
pause
exit /b 1
:done
if exist TrackpadTyping.exe (
    copy /Y resources\lexicon-en.txt . >nul
    echo.
    echo Built. Run TrackpadTyping.exe, then press Ctrl+Alt+Space to type.
)
pause
