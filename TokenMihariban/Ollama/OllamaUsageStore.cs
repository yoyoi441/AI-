using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using TokenMihariban.Models;

namespace TokenMihariban.Ollama;

internal sealed class OllamaUsageStore
{
    private readonly string _path;
    private readonly object _gate = new();

    public OllamaUsageStore()
    {
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TokenMihariban");
        Directory.CreateDirectory(directory);
        _path = Path.Combine(directory, "ollama-usage.jsonl");
    }

    public IReadOnlyList<OllamaUsageEvent> Load()
    {
        lock (_gate)
        {
            try
            {
                if (!File.Exists(_path)) return Array.Empty<OllamaUsageEvent>();
                return File.ReadLines(_path)
                    .Select(line => { try { return JsonSerializer.Deserialize<OllamaUsageEvent>(line); } catch { return null; } })
                    .Where(x => x is not null).Select(x => x!).ToArray();
            }
            catch { return Array.Empty<OllamaUsageEvent>(); }
        }
    }

    public void Append(OllamaUsageEvent usage)
    {
        lock (_gate)
        {
            try { File.AppendAllText(_path, JsonSerializer.Serialize(usage) + Environment.NewLine); }
            catch { }
        }
    }
}
