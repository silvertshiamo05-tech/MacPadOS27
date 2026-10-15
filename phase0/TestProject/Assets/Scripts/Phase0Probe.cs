using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using UnityEngine;

// On-screen and on-disk report for the Phase 0 experiments.
// The log is written to <persistentDataPath>/phase0.log (the app's Documents
// folder on iOS) so it can be read from the Files app after a run.
public class Phase0Probe : MonoBehaviour
{
    public Transform spinner;
    public Renderer texturedQuad;

    string buildInfo = "(phase0_buildinfo missing)";
    string report = "";
    string logPath;
    readonly List<string> recent = new List<string>();
    float fps, fpsTimer;
    int fpsFrames;

    void Awake()
    {
        try
        {
            logPath = Path.Combine(Application.persistentDataPath, "phase0.log");
            File.WriteAllText(logPath, "");
        }
        catch (Exception e)
        {
            logPath = null;
            recent.Add("log file unavailable: " + e.Message);
        }
        Application.logMessageReceived += OnLog;

        var info = Resources.Load<TextAsset>("phase0_buildinfo");
        if (info != null) buildInfo = info.text.Trim();
        report = BuildReport();
        Debug.Log("PHASE0 REPORT\n" + report);
    }

    void OnDestroy()
    {
        Application.logMessageReceived -= OnLog;
    }

    void OnLog(string message, string stack, LogType type)
    {
        string line = "[" + type + "] " + message;
        if (type == LogType.Error || type == LogType.Exception || type == LogType.Assert)
            line += "\n" + stack;
        if (logPath != null)
        {
            try { File.AppendAllText(logPath, line + "\n"); } catch (Exception) { logPath = null; }
        }
        recent.Add(type + ": " + message.Split('\n')[0]);
        if (recent.Count > 8) recent.RemoveAt(0);
    }

    string BuildReport()
    {
        var sb = new StringBuilder();
        sb.AppendLine("MacPadOS27 Phase 0");
        sb.AppendLine(buildInfo);
        sb.AppendLine("runtime platform: " + Application.platform + "  unity " + Application.unityVersion);
        sb.AppendLine("os: " + SystemInfo.operatingSystem + "  device: " + SystemInfo.deviceModel);
        sb.AppendLine("gpu: " + SystemInfo.graphicsDeviceName + " (" + SystemInfo.graphicsDeviceType + ")");
        sb.AppendLine("BC1/DXT1: " + SystemInfo.SupportsTextureFormat(TextureFormat.DXT1)
                      + "  BC3/DXT5: " + SystemInfo.SupportsTextureFormat(TextureFormat.DXT5)
                      + "  BC7: " + SystemInfo.SupportsTextureFormat(TextureFormat.BC7)
                      + "  ASTC6x6: " + SystemInfo.SupportsTextureFormat(TextureFormat.ASTC_6x6));
        if (texturedQuad != null && texturedQuad.sharedMaterial != null && texturedQuad.sharedMaterial.mainTexture is Texture2D t)
            sb.AppendLine("checker texture: " + t.format + " " + t.width + "x" + t.height);
        sb.AppendLine("dataPath: " + Application.dataPath);
        sb.AppendLine("persistentDataPath: " + Application.persistentDataPath);
        sb.AppendLine("streamingAssetsPath: " + Application.streamingAssetsPath);
        return sb.ToString();
    }

    void Update()
    {
        if (spinner != null) spinner.Rotate(20f * Time.deltaTime, 45f * Time.deltaTime, 0f);
        fpsFrames++;
        fpsTimer += Time.unscaledDeltaTime;
        if (fpsTimer >= 0.5f) { fps = fpsFrames / fpsTimer; fpsFrames = 0; fpsTimer = 0f; }
    }

    void OnGUI()
    {
        float scale = Mathf.Max(1f, Screen.height / 720f);
        GUI.matrix = Matrix4x4.Scale(new Vector3(scale, scale, 1f));
        var sb = new StringBuilder(report);
        sb.AppendLine("fps: " + fps.ToString("0") + "  frame " + Time.frameCount);
        sb.Append("touches: " + Input.touchCount);
        for (int i = 0; i < Input.touchCount; i++) sb.Append("  " + Input.GetTouch(i).position);
        sb.AppendLine();
        sb.AppendLine("any key: " + Input.anyKey + "  joysticks: " + string.Join(", ", Input.GetJoystickNames()));
        sb.AppendLine("log file: " + (logPath ?? "none"));
        foreach (var r in recent) sb.AppendLine(r);
        GUI.Label(new Rect(12, 12, Screen.width / scale - 24, Screen.height / scale - 24), sb.ToString());
    }
}
