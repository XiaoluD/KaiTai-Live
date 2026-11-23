// libmpv 最小 P/Invoke（Windows）：wid 模式渲染到给定 HWND，mpv 自己处理子窗口与缩放
using System;
using System.Runtime.InteropServices;

namespace KaiTai
{
    public static class MpvControl
    {
        const string Lib = "libmpv-2.dll";
        const int MPV_ERROR_SUCCESS = 0;

        public static IntPtr Handle { get; private set; } = IntPtr.Zero;
        public static bool Ready => Handle != IntPtr.Zero;

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr mpv_create();

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern int mpv_initialize(IntPtr h);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern void mpv_terminate_destroy(IntPtr h);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern int mpv_set_option_string(IntPtr h, string name, string value);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern int mpv_set_property_string(IntPtr h, string name, string value);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern int mpv_command_string(IntPtr h, string cmd);

        public static bool Init(long widHandle)
        {
            if (Ready) return true;
            Handle = mpv_create();
            if (Handle == IntPtr.Zero) return false;
            // wid 模式：直接渲染到指定 HWND（内嵌子窗口），由 mpv 自管缩放
            mpv_set_option_string(Handle, "wid", widHandle.ToString());
            mpv_set_option_string(Handle, "force-window", "yes");
            mpv_set_option_string(Handle, "input-default-bindings", "no");
            mpv_set_option_string(Handle, "osc", "no");
            mpv_set_option_string(Handle, "volume", "100");
            if (mpv_initialize(Handle) != MPV_ERROR_SUCCESS)
            {
                Handle = IntPtr.Zero;
                return false;
            }
            return true;
        }

        public static void Shutdown()
        {
            if (Handle != IntPtr.Zero)
            {
                mpv_terminate_destroy(Handle);
                Handle = IntPtr.Zero;
            }
        }

        public static void LoadFile(string url)
        {
            if (!Ready) return;
            // loadfile <url> replace —— 引号转义防注入（URL 一般不含引号，兜一手）
            var safe = url.Replace("\"", "");
            mpv_command_string(Handle, "loadfile \"" + safe + "\" replace");
        }

        public static void Stop() { if (Ready) mpv_command_string(Handle, "stop"); }

        public static void SetProperty(string name, string value)
        {
            if (Ready) mpv_set_property_string(Handle, name, value);
        }
    }
}
