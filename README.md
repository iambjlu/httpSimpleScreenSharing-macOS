# httpSimpleScreenSharing-macOS

透過 HTTP + WebSocket 在區域網路內進行螢幕共享的 macOS 應用程式。

## 架構

```
macOS App (Server)
  ├── HTTP Server  (:8080)  → 提供網頁客戶端 (HTML/JS)
  └── WebSocket Server (:8081) → 推送 JPEG 幀 / 接收輸入事件
```

客戶端只需要瀏覽器，連 `http://<Mac的IP>:8080` 即可。

## 功能

- 擷取整個螢幕或單一視窗，最高 60 fps
- 透過瀏覽器觀看，支援全螢幕模式
- 支援遠端滑鼠（移動、點擊、雙擊、右鍵、滾輪）
- 支援遠端鍵盤輸入（含修飾鍵 Shift/Ctrl/Alt/Meta）

## 環境需求

- macOS（需 ScreenCaptureKit，macOS 12.3+）
- 需授權「**螢幕錄製**」與「**輔助使用**」權限

## 使用方式

1. 啟動 App
2. 在「HTTP Port」欄位設定埠號（預設 8080，WS 自動為 8081）
3. 點「啟動伺服器」
4. 選擇擷取來源（全螢幕模式 or 特定視窗）
5. 點「▶ 開始擷取 (60 fps)」
6. 用任何裝置的瀏覽器開啟 `http://<Mac的IP>:8080`

## 注意事項

- 這是練手的早期專案，偶爾有 bug，重開 App 通常可解決
- 僅支援區域網路使用（無加密、無認證）