using System.IO;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows;
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

    // ── FPS counter ────────────────────────────────────────────────
    private int _frameCount;
    private DateTime _lastFpsTime = DateTime.UtcNow;

    // ── Keyboard capture mode ──────────────────────────────────────
    private bool _captureMode;
    private bool _shift, _ctrl, _alt, _meta;

    // ── Fullscreen ────────────────────────────────────────────────
    private bool _isFullscreen;
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

    public MainWindow()
    {
        InitializeComponent();
        InstallHook();
        Deactivated += (_, _) => SetCaptureMode(false);
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
            _isFullscreen = true;
        }
        else
        {
            WindowStyle = _savedStyle; WindowState = _savedState;
            TopBar.Visibility       = Visibility.Visible;
            StatusBarRow.Visibility = Visibility.Visible;
            _isFullscreen = false;
        }
    }

    private void FullscreenBtn_Click(object sender, RoutedEventArgs e) => ToggleFullscreen();

    // ── Quality slider ────────────────────────────────────────────

    private void QualitySlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (QualityLabel == null) return;
        var q = (int)e.NewValue;
        QualityLabel.Text = $"{q}%";
        _ = SendAsync(new { type = "setQuality", quality = q });
    }

    // ── Connect / Disconnect ───────────────────────────────────────

    private async void ConnectBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_ws?.State == WebSocketState.Open) { await DisconnectAsync(); return; }
        await ConnectAsync();
    }

    private async Task ConnectAsync()
    {
        var uri = new Uri($"ws://{HostBox.Text.Trim()}:{PortBox.Text.Trim()}");
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
            _ = ReceiveLoopAsync();
            _ = SendAsync(new { type = "setQuality", quality = (int)QualitySlider.Value });
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
        ConnectBtn.Content    = "連線";
        StatusText.Foreground = new SolidColorBrush(Color.FromRgb(0x88, 0x88, 0x88));
        StatusText.Text       = "已斷線";
        StreamImage.Source    = null;
        FpsText.Text          = "0 fps";
        SizeText.Text         = "";
    }

    // ── Receive loop ──────────────────────────────────────────────

    private async Task ReceiveLoopAsync()
    {
        var buf = new byte[2 * 1024 * 1024];
        var ms  = new MemoryStream();

        try
        {
            while (_ws?.State == WebSocketState.Open)
            {
                ms.SetLength(0);
                WebSocketReceiveResult result;
                do
                {
                    result = await _ws.ReceiveAsync(buf, _cts!.Token);
                    if (result.MessageType == WebSocketMessageType.Close) return;
                    ms.Write(buf, 0, result.Count);
                } while (!result.EndOfMessage);

                if (result.MessageType == WebSocketMessageType.Binary)
                    DisplayJpeg(ms.ToArray());
            }
        }
        catch { }

        await Dispatcher.InvokeAsync(async () => await DisconnectAsync());
    }

    // ── JPEG display ──────────────────────────────────────────────

    private void DisplayJpeg(byte[] jpeg)
    {
        _frameCount++;
        var now = DateTime.UtcNow;
        if ((now - _lastFpsTime).TotalSeconds >= 1)
        {
            var fps = _frameCount; _frameCount = 0; _lastFpsTime = now;
            Dispatcher.Invoke(() => FpsText.Text = $"{fps} fps");
        }

        Dispatcher.BeginInvoke(() =>
        {
            try
            {
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption  = BitmapCacheOption.OnLoad;
                bmp.StreamSource = new MemoryStream(jpeg);
                bmp.EndInit();
                bmp.Freeze();
                StreamImage.Source = bmp;
                SizeText.Text = $"{bmp.PixelWidth}×{bmp.PixelHeight}";
            }
            catch { }
        });
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
        _ = SendAsync(new { type = "mousemove", x, y });
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
