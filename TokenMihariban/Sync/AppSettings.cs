using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace TokenMihariban.Sync;

/// <summary>
/// Plain key-value settings store, backed by a JSON file in
/// <c>%AppData%\TokenMihariban\settings.json</c> — the Windows analogue of UserDefaults
/// (Mac/iOS) and SharedPreferences (Android). Key names intentionally match the other
/// platforms' UserDefaults/SharedPreferences keys purely so anyone cross-referencing
/// the codebases can match a setting by name; storage itself is never shared.
/// </summary>
public sealed class AppSettings
{
    public static readonly AppSettings Shared = new();

    private readonly string _filePath;
    private readonly Dictionary<string, JsonElement> _values;
    private readonly object _lock = new();

    private AppSettings()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var dir = Path.Combine(appData, "TokenMihariban");
        Directory.CreateDirectory(dir);
        _filePath = Path.Combine(dir, "settings.json");
        var legacyFilePath = Path.Combine(appData, "ClaudeUsage", "settings.json");
        if (!File.Exists(_filePath) && File.Exists(legacyFilePath))
        {
            File.Copy(legacyFilePath, _filePath);
        }
        _values = Load();
    }

    private Dictionary<string, JsonElement> Load()
    {
        try
        {
            if (!File.Exists(_filePath)) return new Dictionary<string, JsonElement>();
            var json = File.ReadAllText(_filePath);
            var doc = JsonDocument.Parse(json);
            var result = new Dictionary<string, JsonElement>();
            foreach (var prop in doc.RootElement.EnumerateObject())
            {
                result[prop.Name] = prop.Value.Clone();
            }
            return result;
        }
        catch
        {
            return new Dictionary<string, JsonElement>();
        }
    }

    private void Save()
    {
        lock (_lock)
        {
            using var stream = new FileStream(_filePath, FileMode.Create, FileAccess.Write);
            using var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true });
            writer.WriteStartObject();
            foreach (var (key, value) in _values)
            {
                writer.WritePropertyName(key);
                value.WriteTo(writer);
            }
            writer.WriteEndObject();
        }
    }

    private void SetRaw(string key, JsonElement value)
    {
        lock (_lock)
        {
            _values[key] = value;
        }
        Save();
    }

    public string? GetString(string key, string? defaultValue = null)
    {
        lock (_lock)
        {
            if (_values.TryGetValue(key, out var el) && el.ValueKind == JsonValueKind.String) return el.GetString();
            return defaultValue;
        }
    }

    public void SetString(string key, string value)
    {
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(value));
        SetRaw(key, doc.RootElement.Clone());
    }

    public bool GetBool(string key, bool defaultValue)
    {
        lock (_lock)
        {
            if (_values.TryGetValue(key, out var el) && (el.ValueKind == JsonValueKind.True || el.ValueKind == JsonValueKind.False)) return el.GetBoolean();
            return defaultValue;
        }
    }

    public void SetBool(string key, bool value)
    {
        using var doc = JsonDocument.Parse(value ? "true" : "false");
        SetRaw(key, doc.RootElement.Clone());
    }

    public double GetDouble(string key, double defaultValue = 0)
    {
        lock (_lock)
        {
            if (_values.TryGetValue(key, out var el) && el.ValueKind == JsonValueKind.Number) return el.GetDouble();
            return defaultValue;
        }
    }

    public void SetDouble(string key, double value)
    {
        using var doc = JsonDocument.Parse(value.ToString(System.Globalization.CultureInfo.InvariantCulture));
        SetRaw(key, doc.RootElement.Clone());
    }

    public int GetInt(string key, int defaultValue)
    {
        lock (_lock)
        {
            if (_values.TryGetValue(key, out var el) && el.ValueKind == JsonValueKind.Number) return el.GetInt32();
            return defaultValue;
        }
    }

    public void SetInt(string key, int value)
    {
        using var doc = JsonDocument.Parse(value.ToString(System.Globalization.CultureInfo.InvariantCulture));
        SetRaw(key, doc.RootElement.Clone());
    }

    public HashSet<string> GetStringSet(string key)
    {
        lock (_lock)
        {
            if (_values.TryGetValue(key, out var el) && el.ValueKind == JsonValueKind.Array)
            {
                var set = new HashSet<string>();
                foreach (var item in el.EnumerateArray())
                {
                    if (item.ValueKind == JsonValueKind.String) set.Add(item.GetString()!);
                }
                return set;
            }
            return new HashSet<string>();
        }
    }

    public void SetStringSet(string key, IEnumerable<string> values)
    {
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(values));
        SetRaw(key, doc.RootElement.Clone());
    }

    public bool HasKey(string key)
    {
        lock (_lock)
        {
            return _values.ContainsKey(key);
        }
    }

    public void Remove(string key)
    {
        lock (_lock)
        {
            _values.Remove(key);
        }
        Save();
    }
}
