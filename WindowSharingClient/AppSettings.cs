using System.IO;
using System.Text.Json;

namespace WindowSharingClient;

internal class AppSettings
{
    public string ServerHost { get; set; } = "127.0.0.1";
    public string ServerPort { get; set; } = "9001";
    public int Quality { get; set; } = 75;
    public int Fps { get; set; } = 60;
    public bool Limit1080p { get; set; } = false;

    private static readonly string _configPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "WindowSharingClient",
        "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(_configPath))
            {
                var json = File.ReadAllText(_configPath);
                return JsonSerializer.Deserialize<AppSettings>(json) ?? new AppSettings();
            }
        }
        catch { }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_configPath)!);
            var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(_configPath, json);
        }
        catch { }
    }
}
