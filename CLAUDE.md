# httpSimpleScreenSharing — CLAUDE.md

## Project Structure

| Path | Language | Role |
|------|----------|------|
| `WindowSharingServer/` | Swift (macOS) | Server app: ScreenCaptureKit → H264/JPEG → WebSocket |
| `WindowSharingClient/` | C# WPF (.NET 8) | Windows client: H264/JPEG decode, renders stream, injects input |

## Remote Build Target

- **Machine**: Administrator@192.168.31.37 (Windows, i5-4278U, 8 GB RAM, Intel Iris 5100)
- **SSH password**: 0000
- **Build method**: SCP sources → `dotnet publish` on remote → exe to Release_Intel64
- **Work path**: `C:\Users\Administrator\Desktop\Work_DIR` (source files extracted here)
- **Output path**: `C:\Users\Administrator\Desktop\Release_Intel64\` (Resources：exe + FFmpeg DLL)
- **⚠️ 桌面整潔規定**: 建置完成後桌面只能留必要的資料夾。所有暫存產物（zip、ps1、log、解壓資料夾 等）必須全部刪除，不得散落在桌面。

### Build Steps (run from Mac)

```bash
# 1. Package source (includes H264Decoder.cs + ffmpeg-dlls folder)
cd /Users/iambjlu/XCodeProjects/httpSimpleScreenSharing-macOS
zip -r /tmp/WSC_h264.zip WindowSharingClient/ -x "*/bin/*" -x "*/obj/*" -x "*.user"

# 2. Upload
sshpass -p "0000" scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
  /tmp/WindowSharingClient.zip Administrator@192.168.31.37:"C:/Users/Administrator/Desktop/WindowSharingClient.zip"

# 3. Extract on remote
sshpass -p "0000" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
  Administrator@192.168.31.37 "powershell -NonInteractive -command \"\
  Expand-Archive 'C:/Users/Administrator/Desktop/WindowSharingClient.zip' \
                 'C:/Users/Administrator/Desktop/Work_DIR' -Force; Write-Output done\""

# 4. Build (self-contained single exe, win-x64)
sshpass -p "0000" ssh ... "powershell -NonInteractive -command \"
  cd 'C:/Users/Administrator/Desktop/Work_DIR'
  & 'C:/Program Files/dotnet/dotnet.exe' publish -c Release -r win-x64 --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -o 'C:/Users/Administrator/Desktop/Release_Intel64'
\""
```

### Checking Build Status

```bash
sshpass -p "0000" ssh ... "powershell -NonInteractive -command \"\
  if(Test-Path 'C:/Users/Administrator/Desktop/build_exit.txt'){
    Get-Content 'C:/Users/Administrator/Desktop/build_exit.txt'
    Get-Content 'C:/Users/Administrator/Desktop/build_log.txt' | Select-Object -Last 20
  } else { 'still building...' }\""
```

## Architecture Overview

```
[macOS Server App]
  SCStream (ScreenCaptureKit)
    └── CaptureManager.stream()
          ├── H264Encoder (VideoToolbox, hardware) → onH264Frame → broadcastH264
          └── JPEG encode (CIContext) → onJpegFrame → broadcastJpeg (non-H264 clients)
  WebSocketServer (NWListener)
    ├── broadcastJpeg(jpeg) → connections without H264 negotiation (web browser)
    ├── broadcastH264(annexB) → H264-negotiated connections (WPF client)
    └── handleInput(json) → CGEvent injection + settings + codec negotiation

[Windows Client App]
  ClientWebSocket
    └── ReceiveLoopAsync()
          ├── text frame → HandleTextMessage → set _usingH264 flag
          └── binary frame → prefix 0x48='H' → H264Decoder.Decode → DisplayH264Frame
                           └── no prefix → DisplayJpeg (JPEG fallback)
  H264Decoder (FFmpeg.AutoGen)
    ├── DXVA2 hardware decode (Intel Iris 5100 supports H264 via DXVA2)
    └── software fallback if DXVA2 unavailable
  Win32 keyboard hook (SetWindowsHookEx WH_KEYBOARD_LL)
  Mouse events → normalized (x,y) → sendAsync
```

## Codec Negotiation Protocol

1. Client sends: `{"type":"hello","codecs":["h264","jpeg"]}`
2. Server responds: `{"type":"codec","codec":"h264"}` (or `"jpeg"` if H264 unavailable)
3. Server starts sending binary frames with 1-byte prefix:
   - `0x48` ('H') = H264 Annex B frame (only to negotiated connections)
   - No prefix = JPEG (browser/legacy)

## FFmpeg DLLs

Required next to exe in `ffmpeg-dlls/` subfolder:
- `avcodec-60.dll`, `avutil-58.dll`, `swscale-7.dll`, `avformat-60.dll`
- Download from: https://github.com/GyanD/codexffmpeg/releases/tag/6.1.1
- The build script (`build_h264.ps1`) downloads them automatically.

## Client-to-Server Control Messages

| Message JSON | Effect |
|---|---|
| `{"type":"hello","codecs":["h264","jpeg"]}` | Negotiate codec; server replies with chosen codec |
| `{"type":"setQuality","quality":75}` | JPEG compression factor = quality/100 |
| `{"type":"setFps","fps":30}` | Restart SCStream at new FPS (30 or 60) |
| `{"type":"setMaxResolution","limit1080p":true}` | Server scales capture to ≤1080p before JPEG encode |

## Performance Notes (Administrator@192.168.31.37)

- i5-4278U only has 2 physical cores — every CPU saving matters
- Intel Iris 5100 supports **H264 hardware decode via DXVA2** (Haswell-era iGPU)
- Intel Iris 5100 does NOT support HEVC hardware decode
- H264 hardware decode: ~5% GPU, <2% CPU vs JPEG: ~30-40% CPU
- VideoToolbox on Mac encodes H264 in hardware (minimal server-side CPU impact)
- For ~1 Mbps: H264 mode + 30 fps OR JPEG with 伺服器縮至1080p + quality ~20%
- The status bar shows live fps and kbps; status text shows [H264] when active

## UI Controls (Client)

- **畫質預設**: Low ~1Mbps (q=15) / Med ~3Mbps (q=40) / High ~8Mbps (q=75, default) / Max (q=95) / Custom
- **微調 slider**: fine-tune JPEG quality %
- **FPS combo**: 30 fps / 60 fps
- **伺服器縮至1080p**: checkbox — tells server to downscale >1080p content before encoding
- **Scroll Lock / click stream area**: toggle keyboard capture mode
- **F11**: toggle fullscreen
