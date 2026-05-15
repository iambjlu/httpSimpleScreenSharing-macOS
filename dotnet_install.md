===================================
.NET 8 SDK 全域安装脚本
===================================

在遠端 Windows 機器上執行此指令來安裝 .NET 8 SDK 到 C:\Program Files\dotnet

**重要：必須以 Administrator 身份執行 PowerShell**


全域安装（推薦 - 安装到 C:\Program Files\dotnet）
===================================

在 PowerShell (Administrator) 一次性貼上以下整個區塊：

```powershell
$ErrorActionPreference = "Stop"
Write-Host "Step 1: 允許執行腳本..." -ForegroundColor Cyan
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

Write-Host "Step 2: 設定網路安全..." -ForegroundColor Cyan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "Step 3: 下載安裝腳本..." -ForegroundColor Cyan
Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile 'dotnet-install.ps1'

Write-Host "Step 4: 安裝到全域位置 C:\Program Files\dotnet..." -ForegroundColor Cyan
& '.\dotnet-install.ps1' -Channel 8.0 -InstallDir "C:\Program Files\dotnet" -Architecture x64

Write-Host "Step 5: 清理安裝檔案..." -ForegroundColor Cyan
Remove-Item -Force 'dotnet-install.ps1'

Write-Host "安裝完成！" -ForegroundColor Green
Write-Host "請重啟 PowerShell 以更新環境變量" -ForegroundColor Yellow
```


驗證安装成功
===================================

安装完成後，**關閉並重新打開 PowerShell (Administrator)**，執行：

```powershell
dotnet --version
```

應該會顯示版本號 8.0.x 或更新


編譯準備
===================================

驗證成功後，回到 Mac 執行：

```bash
./build_windows.sh
```

脚本会自動完成以下步驟：
- 打包源代碼
- 上傳到遠端機器
- 編譯 Release 版本 (win-x64)
- 生成自包含可執行檔 (EXE)
- 清理暫存文件


常见问题
===================================

**Q: 安装很慢？**
A: 首次下載 .NET SDK 約 280MB，請耐心等待 5-15 分鐘

**Q: 找不到 dotnet 命令？**
A: 必須重啟 PowerShell！關閉視窗後重新開啟 Administrator PowerShell

**Q: 安装失敗？**
A: 確保有管理員權限，病毒軟體可能阻止下載，暫時關閉防護試試

**Q: 想要手動安装？**
A: 下載 MSI: https://dotnet.microsoft.com/download/dotnet/8.0 選擇 Windows x64 Installer


輸出位置
===================================

編譯完成的執行檔位置：
C:\Users\Administrator\Desktop\Release_Intel64\WindowSharingClient.exe
