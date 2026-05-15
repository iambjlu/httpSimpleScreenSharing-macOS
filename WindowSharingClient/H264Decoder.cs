using FFmpeg.AutoGen;

namespace WindowSharingClient;

internal sealed unsafe class H264Decoder : IDisposable
{
    private AVCodecContext* _ctx;
    private AVFrame*        _frame;
    private AVFrame*        _swFrame;  // hw→sw pixel transfer target
    private AVPacket*       _pkt;
    private SwsContext*     _sws;
    private int             _swsW, _swsH;
    private AVPixelFormat   _swsFmt;
    private byte[][]        _bufs = [Array.Empty<byte>(), Array.Empty<byte>()];
    private int             _bufIdx;
    private bool            _useHardware;
    private bool            _disposed;

    public Action<byte[], int, int>? OnFrame;
    public bool IsHardwareAccelerated => _useHardware;

    public static void RegisterBinaries(string folder) => ffmpeg.RootPath = folder;

    public bool Initialize()
    {
        // Try hardware first (D3D11VA preferred, then DXVA2), fall back to software
        if (TryInitialize(hardware: true))  return true;
        if (TryInitialize(hardware: false)) return true;
        return false;
    }

    private bool TryInitialize(bool hardware)
    {
        var codec = ffmpeg.avcodec_find_decoder(AVCodecID.AV_CODEC_ID_H264);
        if (codec == null) return false;

        var ctx = ffmpeg.avcodec_alloc_context3(codec);
        if (ctx == null) return false;

        ctx->flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY;

        bool hwAttached = false;
        if (hardware)
        {
            hwAttached = TryAttachHw(ctx, AVHWDeviceType.AV_HWDEVICE_TYPE_D3D11VA)
                      || TryAttachHw(ctx, AVHWDeviceType.AV_HWDEVICE_TYPE_DXVA2);
            if (!hwAttached)
            {
                ffmpeg.avcodec_free_context(&ctx);
                return false;
            }
        }
        else
        {
            // Use all available logical cores for software decode
            ctx->thread_count = Math.Min(Environment.ProcessorCount, 4);
        }

        if (ffmpeg.avcodec_open2(ctx, codec, null) < 0)
        {
            ffmpeg.avcodec_free_context(&ctx);
            return false;
        }

        _ctx         = ctx;
        _useHardware = hwAttached;
        _frame       = ffmpeg.av_frame_alloc();
        _swFrame     = ffmpeg.av_frame_alloc();
        _pkt         = ffmpeg.av_packet_alloc();
        return _frame != null && _swFrame != null && _pkt != null;
    }

    private static bool TryAttachHw(AVCodecContext* ctx, AVHWDeviceType type)
    {
        AVBufferRef* hwCtx = null;
        if (ffmpeg.av_hwdevice_ctx_create(&hwCtx, type, null, null, 0) < 0) return false;
        ctx->hw_device_ctx = ffmpeg.av_buffer_ref(hwCtx);
        ffmpeg.av_buffer_unref(&hwCtx);
        return true;
    }

    // Offset+length overload avoids a copy in the receive loop
    public void Decode(byte[] data, int offset, int length)
    {
        if (_ctx == null || _frame == null || _pkt == null) return;

        fixed (byte* p = data)
        {
            _pkt->data = p + offset;
            _pkt->size = length;
            if (ffmpeg.avcodec_send_packet(_ctx, _pkt) < 0) return;
        }

        while (ffmpeg.avcodec_receive_frame(_ctx, _frame) == 0)
        {
            AVFrame* src = _frame;

            if (_useHardware)
            {
                // Transfer decoded surface from GPU to system memory (→ NV12)
                if (ffmpeg.av_hwframe_transfer_data(_swFrame, _frame, 0) >= 0)
                {
                    src = _swFrame;
                }
                else
                {
                    ffmpeg.av_frame_unref(_swFrame);
                    continue; // skip frame rather than crash sws with an opaque HW format
                }
            }

            int w = src->width, h = src->height;
            if (w <= 0 || h <= 0)
            {
                if (_useHardware) ffmpeg.av_frame_unref(_swFrame);
                continue;
            }

            EnsureSws(w, h, (AVPixelFormat)src->format);

            int stride  = w * 4;
            int bufSize = stride * h;
            if (_bufs[_bufIdx].Length != bufSize)
                _bufs[_bufIdx] = new byte[bufSize];

            fixed (byte* dst = _bufs[_bufIdx])
            {
                var dstData    = new byte_ptrArray4(); dstData[0]    = dst;
                var dstStrides = new int_array4();     dstStrides[0] = stride;
                ffmpeg.sws_scale(_sws, src->data, src->linesize, 0, h, dstData, dstStrides);
            }

            if (_useHardware) ffmpeg.av_frame_unref(_swFrame);

            OnFrame?.Invoke(_bufs[_bufIdx], w, h);
            _bufIdx ^= 1;
        }
    }

    public void Decode(byte[] annexB) => Decode(annexB, 0, annexB.Length);

    private void EnsureSws(int w, int h, AVPixelFormat fmt)
    {
        if (_sws != null && _swsW == w && _swsH == h && _swsFmt == fmt) return;
        if (_sws != null) { ffmpeg.sws_freeContext(_sws); _sws = null; }
        _sws   = ffmpeg.sws_getContext(w, h, fmt, w, h, AVPixelFormat.AV_PIX_FMT_BGR0,
                                       ffmpeg.SWS_FAST_BILINEAR, null, null, null);
        _swsW  = w; _swsH = h; _swsFmt = fmt;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_sws    != null) { ffmpeg.sws_freeContext(_sws); _sws = null; }
        if (_pkt    != null) { fixed (AVPacket**      p = &_pkt)    ffmpeg.av_packet_free(p);      }
        if (_frame  != null) { fixed (AVFrame**       p = &_frame)  ffmpeg.av_frame_free(p);       }
        if (_swFrame!= null) { fixed (AVFrame**       p = &_swFrame)ffmpeg.av_frame_free(p);       }
        if (_ctx    != null) { fixed (AVCodecContext**p = &_ctx)    ffmpeg.avcodec_free_context(p); }
    }
}
