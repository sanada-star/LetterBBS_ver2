@echo off
chcp 65001 >nul
echo ======================================
echo  LetterBBS lib/ フォルダ構造修正
echo ======================================
echo.

cd /d "%~dp0"

echo [1/3] LetterBBS フォルダを作成中...
if not exist "LetterBBS" mkdir "LetterBBS"
if not exist "LetterBBS\Controller" mkdir "LetterBBS\Controller"
if not exist "LetterBBS\Model" mkdir "LetterBBS\Model"

echo [2/3] モジュールファイルを移動中...

REM ルート直下のモジュール
for %%F in (Archive.pm Auth.pm Captcha.pm Config.pm Database.pm Router.pm Sanitize.pm Session.pm Template.pm Upload.pm) do (
    if exist "%%F" (
        move /Y "%%F" "LetterBBS\%%F" >nul
        echo   移動: %%F → LetterBBS\%%F
    )
)

REM Controller フォルダの中身
if exist "Controller" (
    for %%F in (Controller\*.pm) do (
        move /Y "%%F" "LetterBBS\Controller\" >nul
        echo   移動: %%F → LetterBBS\Controller\
    )
    rmdir "Controller" 2>nul
)

REM Model フォルダの中身
if exist "Model" (
    for %%F in (Model\*.pm) do (
        move /Y "%%F" "LetterBBS\Model\" >nul
        echo   移動: %%F → LetterBBS\Model\
    )
    rmdir "Model" 2>nul
)

echo.
echo [3/3] 完了確認...
echo.
echo === LetterBBS/ の中身 ===
dir /b "LetterBBS\*.pm" 2>nul
echo.
echo === LetterBBS/Controller/ の中身 ===
dir /b "LetterBBS\Controller\*.pm" 2>nul
echo.
echo === LetterBBS/Model/ の中身 ===
dir /b "LetterBBS\Model\*.pm" 2>nul
echo.
echo ======================================
echo  完了！この後、patio/lib/ フォルダを
echo  まるごとFTPでサーバーにアップロード
echo  してください。
echo ======================================
pause
