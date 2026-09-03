using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using TokenMihariban.Models;

namespace TokenMihariban.Ollama;

public enum OllamaProxyState { Stopped, Starting, Running, Failed }

/// <summary>
/// Loopback-only HTTP/1.1 proxy. Ollama exposes token metrics only in each response,
/// so an opt-in proxy is the only universal way to count CLI/editor/web-client usage
/// without storing prompt or response text.
/// </summary>
internal sealed class OllamaProxyService : IDisposable
{
    public const int LocalPort = 11435;
    public const int CloudPort = 11436;

    private readonly HttpClient _http = new(new SocketsHttpHandler { AutomaticDecompression = DecompressionMethods.None })
    {
        Timeout = Timeout.InfiniteTimeSpan
    };
    private CancellationTokenSource _stop = new();
    private readonly List<TcpListener> _listeners = new();
    private int _readyCount;

    public OllamaProxyState State { get; private set; } = OllamaProxyState.Stopped;
    public string? ErrorMessage { get; private set; }
    public event EventHandler<OllamaUsageEvent>? UsageCaptured;
    public event EventHandler? StateChanged;

    public void Start()
    {
        if (State is OllamaProxyState.Starting or OllamaProxyState.Running) return;
        if (_stop.IsCancellationRequested)
        {
            _stop.Dispose();
            _stop = new CancellationTokenSource();
        }
        State = OllamaProxyState.Starting;
        StateChanged?.Invoke(this, EventArgs.Empty);
        try
        {
            StartListener(LocalPort, new Uri("http://127.0.0.1:11434"), forceCloud: false);
            StartListener(CloudPort, new Uri("https://ollama.com"), forceCloud: true);
            State = OllamaProxyState.Running;
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            State = OllamaProxyState.Failed;
            foreach (var listener in _listeners) listener.Stop();
            _listeners.Clear();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Stop()
    {
        if (State == OllamaProxyState.Stopped) return;
        _stop.Cancel();
        foreach (var listener in _listeners) listener.Stop();
        _listeners.Clear();
        _readyCount = 0;
        State = OllamaProxyState.Stopped;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void StartListener(int port, Uri backend, bool forceCloud)
    {
        var listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        _listeners.Add(listener);
        _readyCount++;
        _ = AcceptLoopAsync(listener, backend, forceCloud, _stop.Token);
    }

    private async Task AcceptLoopAsync(TcpListener listener, Uri backend, bool forceCloud, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var client = await listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
                _ = HandleClientAsync(client, backend, forceCloud, cancellationToken);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch { if (!cancellationToken.IsCancellationRequested) await Task.Delay(250, cancellationToken).ConfigureAwait(false); }
        }
    }

    private async Task HandleClientAsync(TcpClient client, Uri backend, bool forceCloud, CancellationToken cancellationToken)
    {
        using (client)
        {
            var stream = client.GetStream();
            try
            {
                var request = await ReadRequestAsync(stream, cancellationToken).ConfigureAwait(false);
                if (request is null) return;
                if (request.IsChunked)
                {
                    await WriteErrorAsync(stream, 411, "Chunked request bodies are not supported", cancellationToken).ConfigureAwait(false);
                    return;
                }

                var target = new Uri(backend, request.Path);
                using var outgoing = new HttpRequestMessage(new HttpMethod(request.Method), target);
                if (request.Body.Length > 0) outgoing.Content = new ByteArrayContent(request.Body);
                foreach (var (name, value) in request.Headers)
                {
                    if (HopByHop.Contains(name) || name.Equals("Host", StringComparison.OrdinalIgnoreCase) || name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) continue;
                    if (!outgoing.Headers.TryAddWithoutValidation(name, value) && outgoing.Content is not null)
                        outgoing.Content.Headers.TryAddWithoutValidation(name, value);
                }
                outgoing.Headers.Remove("Accept-Encoding");
                outgoing.Headers.TryAddWithoutValidation("Accept-Encoding", "identity");

                string? requestedModel = null;
                try
                {
                    using var json = JsonDocument.Parse(request.Body);
                    if (json.RootElement.TryGetProperty("model", out var model)) requestedModel = model.GetString();
                }
                catch { }

                using var response = await _http.SendAsync(outgoing, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
                await WriteResponseHeadersAsync(stream, response, cancellationToken).ConfigureAwait(false);
                await using var responseStream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                using var captured = new MemoryStream();
                var buffer = new byte[64 * 1024];
                while (true)
                {
                    var count = await responseStream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                    if (count == 0) break;
                    if (captured.Length + count <= 128L * 1024 * 1024) captured.Write(buffer, 0, count);
                    await WriteChunkAsync(stream, buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                }
                await stream.WriteAsync(Encoding.ASCII.GetBytes("0\r\n\r\n"), cancellationToken).ConfigureAwait(false);

                var usage = OllamaUsageResponseParser.Parse(captured.ToArray(), requestedModel, forceCloud);
                if (usage is not null) UsageCaptured?.Invoke(this, usage);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                try { await WriteErrorAsync(stream, 502, ex.Message, cancellationToken).ConfigureAwait(false); }
                catch { }
            }
        }
    }

    private sealed record IncomingRequest(string Method, string Path, IReadOnlyList<(string Name, string Value)> Headers, byte[] Body, bool IsChunked);

    private static async Task<IncomingRequest?> ReadRequestAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        using var collected = new MemoryStream();
        var one = new byte[1];
        while (collected.Length < 64 * 1024)
        {
            var read = await stream.ReadAsync(one, cancellationToken).ConfigureAwait(false);
            if (read == 0) return null;
            collected.WriteByte(one[0]);
            if (collected.Length >= 4)
            {
                var bytes = collected.GetBuffer();
                var n = (int)collected.Length;
                if (bytes[n - 4] == 13 && bytes[n - 3] == 10 && bytes[n - 2] == 13 && bytes[n - 1] == 10) break;
            }
        }
        if (collected.Length >= 64 * 1024) throw new InvalidDataException("HTTP headers are too large");

        var headerText = Encoding.ASCII.GetString(collected.ToArray());
        var lines = headerText.Split("\r\n", StringSplitOptions.None);
        var requestLine = lines[0].Split(' ', 3);
        if (requestLine.Length != 3) throw new InvalidDataException("Invalid HTTP request line");
        var headers = new List<(string, string)>();
        var contentLength = 0;
        var chunked = false;
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon <= 0) continue;
            var name = line[..colon].Trim();
            var value = line[(colon + 1)..].Trim();
            headers.Add((name, value));
            if (name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) int.TryParse(value, out contentLength);
            if (name.Equals("Transfer-Encoding", StringComparison.OrdinalIgnoreCase) && value.Contains("chunked", StringComparison.OrdinalIgnoreCase)) chunked = true;
        }
        if (contentLength > 16 * 1024 * 1024) throw new InvalidDataException("Request body is too large");
        var body = new byte[Math.Max(0, contentLength)];
        var offset = 0;
        while (offset < body.Length)
        {
            var read = await stream.ReadAsync(body.AsMemory(offset), cancellationToken).ConfigureAwait(false);
            if (read == 0) throw new EndOfStreamException();
            offset += read;
        }
        return new IncomingRequest(requestLine[0], requestLine[1], headers, body, chunked);
    }

    private static async Task WriteResponseHeadersAsync(NetworkStream stream, HttpResponseMessage response, CancellationToken cancellationToken)
    {
        var builder = new StringBuilder($"HTTP/1.1 {(int)response.StatusCode} {response.ReasonPhrase}\r\n");
        foreach (var header in response.Headers.Concat(response.Content.Headers))
        {
            if (HopByHop.Contains(header.Key) || header.Key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) continue;
            foreach (var value in header.Value) builder.Append(header.Key).Append(": ").Append(value).Append("\r\n");
        }
        builder.Append("Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(Encoding.ASCII.GetBytes(builder.ToString()), cancellationToken).ConfigureAwait(false);
    }

    private static async Task WriteChunkAsync(NetworkStream stream, ReadOnlyMemory<byte> data, CancellationToken cancellationToken)
    {
        await stream.WriteAsync(Encoding.ASCII.GetBytes(data.Length.ToString("X") + "\r\n"), cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(data, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(Encoding.ASCII.GetBytes("\r\n"), cancellationToken).ConfigureAwait(false);
    }

    private static async Task WriteErrorAsync(NetworkStream stream, int status, string message, CancellationToken cancellationToken)
    {
        var safe = message.Replace('"', '\'');
        var body = Encoding.UTF8.GetBytes("{\"error\":\"" + safe + "\"}");
        var header = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Error\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(body, cancellationToken).ConfigureAwait(false);
    }

    private static readonly HashSet<string> HopByHop = new(StringComparer.OrdinalIgnoreCase)
    {
        "Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization", "TE", "Trailer", "Transfer-Encoding", "Upgrade"
    };

    public void Dispose()
    {
        Stop();
        _http.Dispose();
        _stop.Dispose();
    }
}
