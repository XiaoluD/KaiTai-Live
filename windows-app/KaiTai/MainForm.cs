// 开台 Windows 版主窗体：WebView2 显示界面 + libmpv 盖在 #screen 区域播放（与 mac-app 同构）
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace KaiTai
{
    public class MainForm : Form
    {
        WebView2.WebView2 _web;
        Panel _mpvHost;
        string _mpvCurrentUrl;
        bool _mpvOn;
        string _webRoot;
        string _baseDir;

        public MainForm()
        {
            Text = "开台 · IPTV";
            Width = 1120;
            Height = 760;
            StartPosition = FormStartPosition.CenterScreen;
            Icon = null;

            _baseDir = AppDomain.CurrentDomain.BaseDirectory;
            _webRoot = Path.Combine(_baseDir, "web");

            _web = new WebView2.WebView2 { Dock = DockStyle.Fill };
            Controls.Add(_web);

            _mpvHost = new Panel { BackColor = Color.Black, Visible = false };
            _mpvHost.BringToFront();

            Load += async (_, _) =>
            {
                var server = new LocalServer();
                string url;
                try { url = server.Start(_webRoot); }
                catch (Exception e)
                {
                    MessageBox.Show(e.Message, "开台");
                    Close();
                    return;
                }
                Text = "开台 · IPTV";
                await _web.EnsureCoreWebView2Async();
                _web.CoreWebView2.WebMessageReceived += OnWebMessage;
                _web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
                _web.CoreWebView2.Settings.IsStatusBarEnabled = false;
                _web.CoreWebView2.Settings.IsZoomControlEnabled = false;
                _web.Source = new Uri(url);
                FormClosing += (_, _) => MpvControl.Shutdown();
            };

            Resize += (_, _) => RequestRectSync();
        }

        // mpv host 面板盖在 WebView2 上，位置由网页 #screen 的 rect 驱动
        void PlaceMpvHost(double x, double y, double w, double h)
        {
            _mpvHost.Bounds = new Rectangle((int)x, (int)y, (int)w, (int)h);
            if (!_mpvHost.Visible) _mpvHost.Visible = true;
            _mpvHost.BringToFront();
            if (!MpvControl.Ready)
                MpvControl.Init(_mpvHost.Handle.ToInt64());
        }

        void OnWebMessage(object sender, WebView2.CoreWebView2WebMessageReceivedEventArgs e)
        {
            try
            {
                var json = e.WebMessageAsJson;
                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;
                long id = root.GetProperty("__winId").GetInt64();
                var action = root.GetProperty("action").GetString();
                Task.Run(() =>
                {
                    var result = HandleAction(action, root);
                    // 回包给网页（resolve pending promise）
                    var payload = JsonSerializer.Serialize(new Dictionary<string, object>
                    {
                        ["__winId"] = id,
                        ["result"] = result ?? (object) new Dictionary<string, object>(),
                    });
                    BeginInvoke(() => _web.CoreWebView2.PostWebMessageAsJson(payload));
                });
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine("bridge error: " + ex.Message);
            }
        }

        Dictionary<string, object> HandleAction(string action, JsonElement body)
        {
            switch (action)
            {
                case "probe":
                    return new Dictionary<string, object>
                    {
                        ["embedded"] = true,
                        ["players"] = new string[0],
                        ["version"] = "1.0.0",
                    };

                case "open":
                    return new Dictionary<string, object> { ["player"] = null };

                case "mpv":
                {
                    var op = GetString(body, "op");
                    switch (op)
                    {
                        case "play":
                        {
                            _mpvCurrentUrl = GetString(body, "url");
                            _mpvOn = true;
                            Invoke(() =>
                            {
                                PlaceMpvHost(-1, -1, 1, 1);   // 先确保 host 存在，rect 由网页随后来
                                MpvControl.LoadFile(_mpvCurrentUrl);
                            });
                            return new Dictionary<string, object> { ["ok"] = true };
                        }
                        case "stop":
                            _mpvOn = false;
                            Invoke(() =>
                            {
                                MpvControl.Stop();
                                _mpvHost.Visible = false;
                            });
                            return new Dictionary<string, object> { ["ok"] = true };
                        case "pause":
                        {
                            var paused = body.TryGetProperty("paused", out var pv) && pv.GetBoolean();
                            MpvControl.SetProperty("pause", paused ? "yes" : "no");
                            return new Dictionary<string, object> { ["ok"] = true };
                        }
                        case "volume":
                        {
                            var v = body.TryGetProperty("value", out var vv) ? vv.GetDouble() : 100;
                            MpvControl.SetProperty("volume", Math.Max(0, Math.Min(100, v)).ToString());
                            return new Dictionary<string, object> { ["ok"] = true };
                        }
                        case "setopt":
                        {
                            var key = GetString(body, "key");
                            var value = GetString(body, "value");
                            // Windows 上没有 videotoolbox；硬解交给 mpv auto
                            if (key == "hwdec")
                                MpvControl.SetProperty("hwdec", value != "no" ? "auto-safe" : "no");
                            return new Dictionary<string, object> { ["ok"] = true };
                        }
                        case "rect":
                        {
                            double x = GetNum(body, "x"), y = GetNum(body, "y");
                            double w = GetNum(body, "w"), h = GetNum(body, "h");
                            Invoke(() => PlaceMpvHost(x, y, w, h));
                            return new Dictionary<string, object> { ["ok"] = true };
                        }
                        case "overlay":
                        {
                            var hidden = body.TryGetProperty("hidden", out var hv) && hv.GetBoolean();
                            Invoke(() => { _mpvHost.Visible = !hidden; if (!hidden) _mpvHost.BringToFront(); });
                            return new Dictionary<string, object> { ["ok"] = true };
                        }
                        case "fullscreen":
                            Invoke(() =>
                            {
                                if (FormBorderStyle == FormBorderStyle.Sizable)
                                {
                                    FormBorderStyle = FormBorderStyle.None;
                                    WindowState = FormWindowState.Maximized;
                                }
                                else
                                {
                                    FormBorderStyle = FormBorderStyle.Sizable;
                                    WindowState = FormWindowState.Normal;
                                }
                            });
                            return new Dictionary<string, object> { ["ok"] = true };
                    }
                    return new Dictionary<string, object> { ["ok"] = false };
                }

                case "appupdate":
                    // Windows 版 Phase 1 不做应用内自更新
                    return new Dictionary<string, object> { ["hasUpdate"] = false };

                case "download":
                {
                    var urls = body.TryGetProperty("urls", out var uv)
                        ? JsonSerializer.Deserialize<string[]>(uv.GetRawText()) : Array.Empty<string>();
                    var texts = new Dictionary<string, object>();
                    var errors = new Dictionary<string, object>();
                    using var http = new System.Net.Http.HttpClient();
                    http.Timeout = TimeSpan.FromSeconds(20);
                    http.DefaultRequestHeaders.UserAgent.ParseAdd("KaiTai/1.0");
                    foreach (var u in urls ?? Array.Empty<string>())
                    {
                        try
                        {
                            texts[u] = http.GetStringAsync(u).Result;
                        }
                        catch (Exception ex)
                        {
                            errors[u] = ex.Message;
                        }
                    }
                    return new Dictionary<string, object> { ["texts"] = texts, ["errors"] = errors };
                }

                case "save":
                {
                    var file = GetString(body, "file");
                    var content = GetString(body, "content");
                    // 保存到 exe 旁 playlists/（本地服务同源 serve）
                    var dir = Path.Combine(_baseDir, Path.Combine("web", "playlists"));
                    Directory.CreateDirectory(dir);
                    var safe = Path.GetFileName(file);
                    File.WriteAllText(Path.Combine(dir, safe), content, System.Text.Encoding.UTF8);
                    return new Dictionary<string, object> { ["ok"] = true };
                }
            }
            return new Dictionary<string, object> { };
        }

        static string GetString(JsonElement body, string name)
        {
            return body.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        }

        static double GetNum(JsonElement body, string name)
        {
            return body.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : 0;
        }

        void RequestRectSync() { /* 网页层 500ms 轮询 rect + ResizeObserver，无需原生侧额外驱动 */ }
    }
}
