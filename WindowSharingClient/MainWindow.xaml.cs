using System.Buffers;
using System.IO;
using System.Threading.Channels;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace WindowSharingClient;

public partial class MainWindow : Window
{
    // ── WebSocket ──────────────────────────────────────────────────
    private ClientWebSocket? _ws;
    private CancellationTokenSource? _cts;
    private readonly SemaphoreSlim _sendLock = new(1, 1);

    // Latest-only mouse-move channel: drops older positions when send is in flight
    // so dragging never builds up a backlog of stale events.
    private Channel<(double x, double y)> _mouseMoveChannel =
        Channel.CreateBounded<(double, double)>(
            new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest });

    // ── Rendering (WriteableBitmap avoids per-frame DX texture reallocation) ──
    private WriteableBitmap? _bitmap;
    private int _bitmapW, _bitmapH;

    // ── H.264 decoder ─────────────────────────────────────────────
    private H264Decoder? _h264Decoder;
    private bool         _usingH264;
    // Latest-frame-only dispatch: avoid Dispatcher queue buildup at high fps
    private volatile byte[]? _latestH264Pixels;
    private volatile int     _latestH264W, _latestH264H;
    private int              _h264DispatchPending;

    // ── FPS / bandwidth counters ───────────────────────────────────
    private int      _frameCount;
    private DateTime _lastFpsTime = DateTime.UtcNow;
    private long     _bytesReceived;
    private DateTime _lastBwTime  = DateTime.UtcNow;

    // ── Keyboard capture mode ──────────────────────────────────────
    private bool _captureMode;
    private bool _shift, _ctrl, _alt, _meta;

    // ── Fullscreen ────────────────────────────────────────────────
    private bool        _isFullscreen;
    private WindowStyle _savedStyle;
    private WindowState _savedState;

    // ── Win32 keyboard hook ────────────────────────────────────────
    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
    private LowLevelKeyboardProc? _hookProc;
    private IntPtr _hookId = IntPtr.Zero;

    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] static extern bool   UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string? name);

    private const int  WH_KEYBOARD_LL = 13;
    private const int  WM_KEYDOWN     = 0x0100;
    private const int  WM_KEYUP       = 0x0101;
    private const int  WM_SYSKEYDOWN  = 0x0104;
    private const int  WM_SYSKEYUP    = 0x0105;
    private const uint VK_SCROLL_LOCK = 0x91;
    private const uint VK_F11         = 0x7A;

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr dwExtraInfo; }

    private static readonly Dictionary<uint, string> VkMap = BuildVkMap();

    // ──────────────────────────────────────────────────────────────

    private AppSettings? _settings;

    public MainWindow()
    {
        InitializeComponent();
        InstallHook();
        Deactivated += (_, _) => SetCaptureMode(false);
        Loaded += (_, _) => LoadSettings();

        // For self-contained single-file exe, AppContext.BaseDirectory is the temp extraction
        // folder. Use the actual exe's directory instead.
        var exeDir = Path.GetDirectoryName(Environment.ProcessPath) ?? AppContext.BaseDirectory;
        var ffDir  = Path.Combine(exeDir, "ffmpeg-dlls");
        H264Decoder.RegisterBinaries(Directory.Exists(ffDir) ? ffDir : exeDir);
    }

    // ── Settings ──────────────────────────────────────────────────

    private void LoadSettings()
    {
        _settings = AppSettings.Load();
        if (HostBox != null) HostBox.Text = _settings.ServerHost;
        if (PortBox != null) PortBox.Text = _settings.ServerPort;
        if (QualitySlider != null) QualitySlider.Value = _settings.Quality;
        if (FpsCombo != null) FpsCombo.SelectedIndex = _settings.Fps == 30 ? 0 : 1;
        if (Max1080pCheck != null) Max1080pCheck.IsChecked = _settings.Limit1080p;
    }

    private void SaveSettings()
    {
        if (_settings == null) return;
        _settings.ServerHost = HostBox?.Text?.Trim() ?? "127.0.0.1";
        _settings.ServerPort = PortBox?.Text?.Trim() ?? "9001";
        _settings.Quality = (int)(QualitySlider?.Value ?? 75);
        _settings.Fps = FpsCombo?.SelectedIndex == 0 ? 30 : 60;
        _settings.Limit1080p = Max1080pCheck?.IsChecked ?? false;
        _settings.Save();
    }

    // ── Keyboard hook ─────────────────────────────────────────────

    private void InstallHook()
    {
        _hookProc = HookCallback;
        using var proc = System.Diagnostics.Process.GetCurrentProcess();
        using var mod  = proc.MainModule!;
        _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _hookProc, GetModuleHandle(mod.ModuleName), 0);
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return CallNextHookEx(_hookId, nCode, wParam, lParam);

        var ks   = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        bool down = wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN;
        bool up   = wParam == WM_KEYUP   || wParam == WM_SYSKEYUP;

        if (ks.vkCode == VK_SCROLL_LOCK && down)
        {
            Dispatcher.BeginInvoke(() => SetCaptureMode(!_captureMode));
            return (IntPtr)1;
        }
        if (ks.vkCode == VK_F11 && down)
        {
            Dispatcher.BeginInvoke(ToggleFullscreen);
            return (IntPtr)1;
        }

        if (!_captureMode) return CallNextHookEx(_hookId, nCode, wParam, lParam);

        if (down || up)
        {
            switch (ks.vkCode)
            {
                case 0xA0: case 0xA1: _shift = down; break;
                case 0xA2: case 0xA3: _ctrl  = down; break;
                case 0xA4: case 0xA5: _alt   = down; break;
                case 0x5B: case 0x5C: _meta  = down; break;
            }
            if (VkMap.TryGetValue(ks.vkCode, out var code))
            {
                if (ks.vkCode == 0x0D && (ks.flags & 0x01) != 0) code = "NumpadEnter";
                _ = SendAsync(new { type = down ? "keydown" : "keyup", code, key = code,
                                    shift = _shift, ctrl = _ctrl, alt = _alt, meta = _meta });
            }
        }
        return (IntPtr)1;
    }

    // ── Capture mode ──────────────────────────────────────────────

    private void SetCaptureMode(bool on)
    {
        _captureMode = on;
        if (!on) { _shift = _ctrl = _alt = _meta = false; }
        StreamBorder.BorderBrush = on ? Brushes.DodgerBlue : Brushes.Transparent;
        CaptureLabel.Text        = on ? "⌨ 擷取中" : "⌨ 未擷取";
        CaptureLabel.Foreground  = on
            ? Brushes.DodgerBlue
            : new SolidColorBrush(Color.FromRgb(0x88, 0x88, 0x88));
    }

    // ── Fullscreen ────────────────────────────────────────────────

    private void ToggleFullscreen()
    {
        if (!_isFullscreen)
        {
            _savedStyle = WindowStyle; _savedState = WindowState;
            TopBar.Visibility       = Visibility.Collapsed;
            StatusBarRow.Visibility = Visibility.Collapsed;
            WindowStyle = WindowStyle.None;
            WindowState = WindowState.Maximized;
            ExitFsBtn.Visibility = Visibility.Visible;
            _isFullscreen = true;
        }
        else
        {
            WindowStyle = _savedStyle; WindowState = _savedState;
            TopBar.Visibility       = Visibility.Visible;
            StatusBarRow.Visibility = Visibility.Visible;
            ExitFsBtn.Visibility = Visibility.Collapsed;
            _isFullscreen = false;
        }
    }

    private void FullscreenBtn_Click(object sender, RoutedEventArgs e) => ToggleFullscreen();

    // ── Quality preset combo ──────────────────────────────────────

    private bool _suppressSliderEvent;

    private void QualityPresetCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (QualitySlider == null) return;
        if (QualityPresetCombo.SelectedItem is not ComboBoxItem item) return;
        if (item.Tag is string tagStr && int.TryParse(tagStr, out int q) && q > 0)
        {
            _suppressSliderEvent = true;
            QualitySlider.Value  = q;
            _suppressSliderEvent = false;
            _ = SendAsync(new { type = "setQuality", quality = q });
        }
    }

    // ── Quality slider ────────────────────────────────────────────

    private void QualitySlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (QualityLabel == null) return;
        var q = (int)e.NewValue;
        QualityLabel.Text = $"{q}%";

        if (!_suppressSliderEvent)
        {
            // User dragged slider manually — switch preset display to "自訂"
            if (QualityPresetCombo != null)
                QualityPresetCombo.SelectedItem = CustomQualityItem;
            _ = SendAsync(new { type = "setQuality", quality = q });
            SaveSettings();
        }
    }

    // ── FPS combo ────────────────────────────────────────────────

    private void FpsCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        int fps = FpsCombo.SelectedIndex == 0 ? 30 : 60;
        _ = SendAsync(new { type = "setFps", fps });
        SaveSettings();
    }

    // ── Max 1080p checkbox ────────────────────────────────────────

    private void Max1080pCheck_Changed(object sender, RoutedEventArgs e)
    {
        bool limit = Max1080pCheck.IsChecked == true;
        _ = SendAsync(new { type = "setMaxResolution", limit1080p = limit });
        SaveSettings();
    }

    // ── Connect / Disconnect ───────────────────────────────────────

    private async void ConnectBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_ws?.State == WebSocketState.Open) { await DisconnectAsync(); return; }
        await ConnectAsync();
    }

    private async Task ConnectAsync()
    {
        var host = HostBox.Text.Trim();
        var port = PortBox.Text.Trim();
        var uri = new Uri($"ws://{host}:{port}");

        // Save connection settings
        if (_settings != null)
        {
            _settings.ServerHost = host;
            _settings.ServerPort = port;
            _settings.Save();
        }

        _cts = new CancellationTokenSource();
        _ws  = new ClientWebSocket();

        ConnectBtn.Content    = "連線中…";
        StatusText.Foreground = Brushes.Gray;
        StatusText.Text       = "連線中…";

        try
        {
            await _ws.ConnectAsync(uri, _cts.Token);
            ConnectBtn.Content    = "斷線";
            StatusText.Foreground = Brushes.LimeGreen;
            StatusText.Text       = $"已連線 {uri.Host}:{uri.Port}";

            // Try to initialise H264 decoder; fall back to JPEG if FFmpeg unavailable
            _usingH264   = false;
            _h264Decoder?.Dispose();
            _h264Decoder = new H264Decoder();
            bool canH264 = false;
            try { canH264 = _h264Decoder.Initialize(); } catch { }
            if (!canH264) { _h264Decoder.Dispose(); _h264Decoder = null; }

            // Recreate mouse-move channel so it's fresh for this connection
            _mouseMoveChannel = Channel.CreateBounded<(double, double)>(
                new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest });

            _ = ReceiveLoopAsync();
            _ = MouseMoveSenderAsync();

            // Codec negotiation — server will respond with {"type":"codec","codec":"h264"|"jpeg"}
            if (canH264)
                _ = SendAsync(new { type = "hello", codecs = new[] { "h264", "jpeg" } });
            else
                _ = SendAsync(new { type = "hello", codecs = new[] { "jpeg" } });

            // Push current settings to server immediately after connecting
            _ = SendAsync(new { type = "setQuality", quality = (int)QualitySlider.Value });
            int fps = FpsCombo.SelectedIndex == 0 ? 30 : 60;
            _ = SendAsync(new { type = "setFps", fps });
            _ = SendAsync(new { type = "setMaxResolution", limit1080p = Max1080pCheck.IsChecked == true });
        }
        catch (Exception ex)
        {
            ConnectBtn.Content    = "連線";
            StatusText.Foreground = Brushes.OrangeRed;
            StatusText.Text       = $"失敗：{ex.Message}";
        }
    }

    private async Task DisconnectAsync()
    {
        SetCaptureMode(false);
        _cts?.Cancel();
        if (_ws?.State == WebSocketState.Open)
            await _ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None);
        _ws?.Dispose(); _ws = null;
        _h264Decoder?.Dispose(); _h264Decoder = null;
        _usingH264 = false;
        ConnectBtn.Content    = "連線";
        StatusText.Foreground = new SolidColorBrush(Color.FromRgb(0x88, 0x88, 0x88));
        StatusText.Text       = "已斷線";
        StreamImage.Source    = null;
        _bitmap = null;
        FpsText.Text = "0 fps";
        BwText.Text  = "0 kbps";
        SizeText.Text = "";
    }

    // ── Receive loop ──────────────────────────────────────────────
    // Uses ArrayPool to avoid per-frame heap allocations; passes offset+length
    // to H264Decoder so no extra copy is made for the Annex B payload.

    private async Task ReceiveLoopAsync()
    {
        var pool    = ArrayPool<byte>.Shared;
        var recvBuf = pool.Rent(1 * 1024 * 1024);
        var msgBuf  = pool.Rent(8 * 1024 * 1024);
        int msgLen  = 0;

        try
        {
            while (_ws?.State == WebSocketState.Open)
            {
                msgLen = 0;
                WebSocketReceiveResult result;
                do
                {
                    result = await _ws.ReceiveAsync(recvBuf, _cts!.Token);
                    if (result.MessageType == WebSocketMessageType.Close) return;
                    int needed = msgLen + result.Count;
                    if (needed > msgBuf.Length)
                    {
                        var bigger = pool.Rent(needed * 2);
                        Buffer.BlockCopy(msgBuf, 0, bigger, 0, msgLen);
                        pool.Return(msgBuf);
                        msgBuf = bigger;
                    }
                    Buffer.BlockCopy(recvBuf, 0, msgBuf, msgLen, result.Count);
                    msgLen += result.Count;
                } while (!result.EndOfMessage);

                if (result.MessageType == WebSocketMessageType.Text)
                {
                    HandleTextMessage(Encoding.UTF8.GetString(msgBuf, 0, msgLen));
                }
                else if (result.MessageType == WebSocketMessageType.Binary && msgLen > 1)
                {
                    if (msgBuf[0] == 0x48 && _usingH264)
                    {
                        // H264 Annex B — drop old frames if display is busy (no backlog)
                        if (_h264DispatchPending == 0)
                        {
                            TrackFrameStats(msgLen - 1);
                            _h264Decoder?.Decode(msgBuf, 1, msgLen - 1);
                        }
                    }
                    else
                    {
                        // Plain JPEG — MemoryStream wraps the buffer slice without copying
                        DisplayJpeg(msgBuf, msgLen);
                    }
                }
            }
        }
        catch { }
        finally
        {
            pool.Return(recvBuf);
            pool.Return(msgBuf);
        }

        await Dispatcher.InvokeAsync(async () => await DisconnectAsync());
    }

    // ── Text message (codec negotiation) ──────────────────────────

    private void HandleTextMessage(string text)
    {
        try
        {
            var doc = JsonSerializer.Deserialize<JsonElement>(text);
            if (doc.GetProperty("type").GetString() == "codec")
            {
                var codec = doc.GetProperty("codec").GetString();
                _usingH264 = codec == "h264" && _h264Decoder != null;
                if (_usingH264)
                {
                    _h264Decoder!.OnFrame = DisplayH264Frame;
                    var hwLabel = _h264Decoder.IsHardwareAccelerated ? "H264/HW" : "H264/SW";
                    Dispatcher.BeginInvoke(() =>
                        StatusText.Text = StatusText.Text + $" [{hwLabel}]");
                }
            }
        }
        catch { }
    }

    // ── Stats tracking (shared between JPEG and H264 paths) ────────

    private void TrackFrameStats(int byteCount)
    {
        _bytesReceived += byteCount;
        var now = DateTime.UtcNow;
        if ((now - _lastBwTime).TotalSeconds >= 1)
        {
            var kbps = _bytesReceived * 8.0 / (now - _lastBwTime).TotalSeconds / 1000.0;
            _bytesReceived = 0; _lastBwTime = now;
            Dispatcher.BeginInvoke(() => BwText.Text = $"{kbps:F0} kbps");
        }
        _frameCount++;
        if ((now - _lastFpsTime).TotalSeconds >= 1)
        {
            var fps = _frameCount; _frameCount = 0; _lastFpsTime = now;
            Dispatcher.BeginInvoke(() => FpsText.Text = $"{fps} fps");
        }
    }

    // ── H264 display — called on background thread with decoded BGR0 pixels ──
    // Only one dispatch pending at a time; intermediate frames are dropped so the
    // Dispatcher queue never builds up, keeping display latency at one vsync.

    private void DisplayH264Frame(byte[] pixels, int w, int h)
    {
        _latestH264Pixels = pixels;
        _latestH264W      = w;
        _latestH264H      = h;
        if (Interlocked.CompareExchange(ref _h264DispatchPending, 1, 0) == 0)
            Dispatcher.BeginInvoke(CommitH264Frame, System.Windows.Threading.DispatcherPriority.Render);
    }

    private void CommitH264Frame()
    {
        Interlocked.Exchange(ref _h264DispatchPending, 0);
        var pixels = _latestH264Pixels;
        var w      = _latestH264W;
        var h      = _latestH264H;
        if (pixels == null || w <= 0 || h <= 0) return;
        try
        {
            if (_bitmap == null || _bitmapW != w || _bitmapH != h)
            {
                _bitmap  = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgr32, null);
                _bitmapW = w; _bitmapH = h;
                StreamImage.Source = _bitmap;
                SizeText.Text = $"{w}×{h}";
            }
            _bitmap.Lock();
            _bitmap.WritePixels(new Int32Rect(0, 0, w, h), pixels, w * 4, 0);
            _bitmap.Unlock();
        }
        catch { }
    }

    // ── JPEG display — decode on background thread, blit via WriteableBitmap ──

    private void DisplayJpeg(byte[] data, int length)
    {
        TrackFrameStats(length);

        // Decode JPEG on current background thread (not UI thread).
        // MemoryStream wraps the pooled buffer slice — no copy.
        try
        {
            using var ms  = new MemoryStream(data, 0, length, writable: false);
            var decoder   = new JpegBitmapDecoder(ms, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            var converted = new FormatConvertedBitmap(decoder.Frames[0], PixelFormats.Bgr32, null, 0);
            converted.Freeze();

            int w      = converted.PixelWidth;
            int h      = converted.PixelHeight;
            int stride = w * 4;
            var pixels = new byte[stride * h];
            converted.CopyPixels(pixels, stride, 0);

            Dispatcher.BeginInvoke(() =>
            {
                try
                {
                    // Reuse WriteableBitmap unless resolution changed — avoids GPU texture reallocation
                    if (_bitmap == null || _bitmapW != w || _bitmapH != h)
                    {
                        _bitmap  = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgr32, null);
                        _bitmapW = w; _bitmapH = h;
                        StreamImage.Source = _bitmap;
                        SizeText.Text = $"{w}×{h}";
                    }
                    _bitmap.Lock();
                    _bitmap.WritePixels(new Int32Rect(0, 0, w, h), pixels, stride, 0);
                    _bitmap.Unlock();
                }
                catch { }
            });
        }
        catch { }
    }

    // ── Send ──────────────────────────────────────────────────────

    private async Task SendAsync(object obj)
    {
        if (_ws?.State != WebSocketState.Open) return;
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(obj));
        await _sendLock.WaitAsync();
        try   { await _ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None); }
        catch { }
        finally { _sendLock.Release(); }
    }

    // ── Mouse events ──────────────────────────────────────────────

    private (double x, double y)? NormPos(System.Windows.Input.MouseEventArgs e)
    {
        if (StreamImage.Source is not BitmapSource src) return null;
        var pos   = e.GetPosition(StreamBorder);
        var bw    = StreamBorder.ActualWidth;
        var bh    = StreamBorder.ActualHeight;
        var scale = Math.Min(bw / src.PixelWidth, bh / src.PixelHeight);
        var imgW  = src.PixelWidth  * scale;
        var imgH  = src.PixelHeight * scale;
        var ox    = (bw - imgW) / 2;
        var oy    = (bh - imgH) / 2;
        var nx    = (pos.X - ox) / imgW;
        var ny    = (pos.Y - oy) / imgH;
        return (nx < 0 || nx > 1 || ny < 0 || ny > 1) ? null : (nx, ny);
    }

    private void StreamImage_MouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (NormPos(e) is not var (x, y)) return;
        _mouseMoveChannel.Writer.TryWrite((x, y));
    }

    // Drains the mouse-move channel one event at a time, so rapid movement
    // never queues more than one pending send — the latest position wins.
    private async Task MouseMoveSenderAsync()
    {
        try
        {
            await foreach (var (x, y) in _mouseMoveChannel.Reader.ReadAllAsync(_cts!.Token))
                await SendAsync(new { type = "mousemove", x, y });
        }
        catch (OperationCanceledException) { }
    }

    private DateTime _lastClickTime = DateTime.MinValue;
    private System.Windows.Point _lastClickPos;

    private void StreamImage_MouseDown(object sender, MouseButtonEventArgs e)
    {
        SetCaptureMode(true);
        StreamBorder.CaptureMouse();
        if (NormPos(e) is not var (x, y)) return;
        int btn = e.ChangedButton switch { MouseButton.Middle => 1, MouseButton.Right => 2, _ => 0 };

        var now = DateTime.UtcNow;
        var pos = e.GetPosition(StreamBorder);
        if (btn == 0
            && (now - _lastClickTime).TotalMilliseconds < 500
            && Math.Abs(pos.X - _lastClickPos.X) < 6
            && Math.Abs(pos.Y - _lastClickPos.Y) < 6)
        {
            _ = SendAsync(new { type = "dblclick", x, y });
        }
        _lastClickTime = now;
        _lastClickPos  = pos;
        _ = SendAsync(new { type = "mousedown", x, y, button = btn });
    }

    private void StreamImage_MouseUp(object sender, MouseButtonEventArgs e)
    {
        StreamBorder.ReleaseMouseCapture();
        if (NormPos(e) is not var (x, y)) return;
        int btn = e.ChangedButton switch { MouseButton.Middle => 1, MouseButton.Right => 2, _ => 0 };
        _ = SendAsync(new { type = "mouseup", x, y, button = btn });
    }

    private void StreamImage_MouseWheel(object sender, MouseWheelEventArgs e)
        => _ = SendAsync(new { type = "wheel", dx = 0, dy = -e.Delta });

    // ── Cleanup ───────────────────────────────────────────────────

    private void Window_Closing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_hookId != IntPtr.Zero) UnhookWindowsHookEx(_hookId);
        _cts?.Cancel();
        _ws?.Dispose();
        _h264Decoder?.Dispose();
    }

    // ── VK → JS code map ─────────────────────────────────────────

    private static Dictionary<uint, string> BuildVkMap()
    {
        var m = new Dictionary<uint, string>();
        for (uint i = 0; i < 26; i++) m[0x41 + i] = "Key" + (char)('A' + i);
        for (uint i = 0; i < 10; i++) m[0x30 + i] = "Digit" + i;
        string[] fk = ["F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12","F13","F14","F15","F16","F17"];
        for (uint i = 0; i < (uint)fk.Length; i++) m[0x70 + i] = fk[i];
        for (uint i = 0; i < 10; i++) m[0x60 + i] = "Numpad" + i;
        m[0x6A] = "NumpadMultiply"; m[0x6B] = "NumpadAdd";
        m[0x6D] = "NumpadSubtract"; m[0x6E] = "NumpadDecimal"; m[0x6F] = "NumpadDivide";
        m[0x5B] = "MetaLeft";    m[0x5C] = "MetaRight";
        m[0xA0] = "ShiftLeft";   m[0xA1] = "ShiftRight";
        m[0xA2] = "ControlLeft"; m[0xA3] = "ControlRight";
        m[0xA4] = "AltLeft";     m[0xA5] = "AltRight";
        m[0x0D] = "Enter";  m[0x1B] = "Escape"; m[0x20] = "Space";
        m[0x09] = "Tab";    m[0x08] = "Backspace"; m[0x14] = "CapsLock";
        m[0x25] = "ArrowLeft"; m[0x26] = "ArrowUp";
        m[0x27] = "ArrowRight"; m[0x28] = "ArrowDown";
        m[0x24] = "Home"; m[0x23] = "End";
        m[0x21] = "PageUp"; m[0x22] = "PageDown";
        m[0x2D] = "Insert"; m[0x2E] = "Delete";
        m[0xBA] = "Semicolon"; m[0xBB] = "Equal";   m[0xBC] = "Comma";
        m[0xBD] = "Minus";     m[0xBE] = "Period";   m[0xBF] = "Slash";
        m[0xC0] = "Backquote"; m[0xDB] = "BracketLeft";
        m[0xDC] = "Backslash"; m[0xDD] = "BracketRight"; m[0xDE] = "Quote";
        return m;
    }
}
