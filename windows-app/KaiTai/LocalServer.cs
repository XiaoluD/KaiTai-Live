// 本地静态服务：serve web/ 与 playlists/（与 mac-app 的 loopback 同构）
using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading.Tasks;

namespace KaiTai
{
    public class LocalServer
    {
        HttpListener _listener;
        public int Port { get; private set; }
        public string WebRoot { get; private set; }

        static readonly string[] TextExt = { ".m3u", ".json", ".txt", ".tsv" };

        public string Start(string webRoot)
        {
            WebRoot = Path.GetFullPath(webRoot);
            if (!Directory.Exists(WebRoot))
                throw new DirectoryNotFoundException("web 目录不存在: " + WebRoot);

            // 随机端口，冲突重试 10 次
            Exception last = null;
            for (int i = 0; i < 10; i++)
            {
                Port = 50000 + new Random().Next(20000);
                try
                {
                    _listener = new HttpListener();
                    _listener.Prefixes.Add("http://127.0.0.1:" + Port + "/");
                    _listener.Start();
                    _ = Task.Run(Loop);
                    return "http://127.0.0.1:" + Port + "/index.html";
                }
                catch (Exception e) { last = e; }
            }
            throw new Exception("本地服务启动失败（端口冲突）", last);
        }

        async void Loop()
        {
            while (_listener.IsListening)
            {
                try
                {
                    var ctx = await _listener.GetContextAsync();
                    _ = Task.Run(() => Serve(ctx));
                }
                catch { break; }
            }
        }

        void Serve(HttpListenerContext ctx)
        {
            try
            {
                var raw = Uri.UnescapeDataString(ctx.Request.Url.AbsolutePath);
                if (raw == "/") raw = "/index.html";
                var path = Path.Combine(WebRoot, raw.TrimStart('/').Replace('/', Path.DirectorySeparatorChar));
                // 防目录穿越
                if (!path.StartsWith(WebRoot, StringComparison.OrdinalIgnoreCase) || !File.Exists(path))
                {
                    ctx.Response.StatusCode = 404;
                    ctx.Response.Close();
                    return;
                }
                var ext = Path.GetExtension(path).ToLowerInvariant();
                var mime =
                    ext == ".html" || ext == ".htm" ? "text/html" :
                    ext == ".css" ? "text/css" :
                    ext == ".js" ? "text/javascript" :
                    ext == ".json" ? "application/json" :
                    ext == ".png" ? "image/png" :
                    ext == ".jpg" || ext == ".jpeg" ? "image/jpeg" :
                    ext == ".svg" ? "image/svg+xml" :
                    ext == ".m3u" ? "audio/x-mpegurl" :
                    ext == ".tsv" ? "text/tab-separated-values" :
                    "application/octet-stream";
                ctx.Response.ContentType = mime;
                ctx.Response.Headers["Cache-Control"] = "no-cache";
                using var fs = File.OpenRead(path);
                fs.CopyTo(ctx.Response.OutputStream);
                ctx.Response.Close();
            }
            catch { try { ctx.Response.Close(); } catch { } }
        }
    }
}
