using System;
using System.IO;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;

// Batch-mode entry points used by .github/workflows/phase0.yml:
//   Unity -batchmode -buildTarget StandaloneOSX -executeMethod Phase0Build.BuildMac
//   Unity -batchmode -buildTarget iOS          -executeMethod Phase0Build.BuildIOS
// Both builds share one scene and one set of assets, so the macOS data can be
// swapped into the iOS app for the data-compatibility experiment.
public static class Phase0Build
{
    const string ScenePath = "Assets/Scenes/Main.unity";
    const string TexturePath = "Assets/Gen/checker.png";
    const string MaterialPath = "Assets/Gen/Checker.mat";
    const string BuildInfoPath = "Assets/Resources/phase0_buildinfo.txt";

    public static void BuildMac()
    {
        Run(() =>
        {
            Common(BuildTargetGroup.Standalone);
            // "ARM64" = Apple silicon only, like the arm64 slice of a universal game.
            EditorUserBuildSettings.SetPlatformSettings("Standalone", "OSXUniversal", "Architecture", "ARM64");
            Build(BuildTarget.StandaloneOSX, "Build/Mac/Phase0Test.app", "StandaloneOSX");
        });
    }

    public static void BuildIOS()
    {
        Run(() =>
        {
            Common(BuildTargetGroup.iOS);
            PlayerSettings.SetApplicationIdentifier(BuildTargetGroup.iOS, "com.macpados27.phase0");
            PlayerSettings.iOS.targetOSVersionString = "15.0";
            PlayerSettings.iOS.sdkVersion = iOSSdkVersion.DeviceSDK;
            PlayerSettings.iOS.appleEnableAutomaticSigning = false;
            Build(BuildTarget.iOS, "Build/iOS", "iOS");
        });
    }

    static void Run(Action body)
    {
        try
        {
            body();
        }
        catch (Exception e)
        {
            Debug.LogError("PHASE0 BUILD FAILED: " + e);
            EditorApplication.Exit(1);
        }
    }

    static void Common(BuildTargetGroup group)
    {
        PlayerSettings.companyName = "MacPadOS27";
        PlayerSettings.productName = "Phase0Test";
        PlayerSettings.SetScriptingBackend(group, ScriptingImplementation.IL2CPP);
        PlayerSettings.SetManagedStrippingLevel(group, ManagedStrippingLevel.Minimal);
        // Keep every engine module/class in the player: the eventual loader shell
        // must be able to run games that use modules the shell itself does not.
        PlayerSettings.stripEngineCode = false;
        PlayerSettings.defaultInterfaceOrientation = UIOrientation.LandscapeLeft;
        EnsureScene();
    }

    static void Build(BuildTarget target, string path, string label)
    {
        Directory.CreateDirectory("Assets/Resources");
        File.WriteAllText(BuildInfoPath,
            "data built for " + label + " with Unity " + Application.unityVersion + " at " + DateTime.UtcNow.ToString("u"));
        AssetDatabase.ImportAsset(BuildInfoPath, ImportAssetOptions.ForceUpdate);

        var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions
        {
            scenes = new[] { ScenePath },
            locationPathName = path,
            target = target,
            options = BuildOptions.None,
        });
        Debug.Log("PHASE0 BUILD " + label + ": " + report.summary.result + ", " + report.summary.totalSize + " bytes, "
                  + report.summary.totalErrors + " errors");
        if (report.summary.result != BuildResult.Succeeded)
            throw new Exception("BuildPlayer " + label + " returned " + report.summary.result);
    }

    // Created once, then reused, so both platform builds serialize the same objects.
    static void EnsureScene()
    {
        if (File.Exists(ScenePath))
        {
            EditorBuildSettings.scenes = new[] { new EditorBuildSettingsScene(ScenePath, true) };
            return;
        }
        Directory.CreateDirectory("Assets/Scenes");
        Directory.CreateDirectory("Assets/Gen");

        var scene = EditorSceneManager.NewScene(NewSceneSetup.DefaultGameObjects, NewSceneMode.Single);
        var cam = Camera.main;
        cam.clearFlags = CameraClearFlags.SolidColor;
        cam.backgroundColor = new Color(0.08f, 0.10f, 0.14f);
        cam.transform.position = new Vector3(0f, 0f, -5f);
        cam.transform.rotation = Quaternion.identity;

        var cube = GameObject.CreatePrimitive(PrimitiveType.Cube);
        cube.name = "Spinner (Standard shader)";
        cube.transform.position = new Vector3(-1.4f, -0.6f, 0f);

        var quad = GameObject.CreatePrimitive(PrimitiveType.Quad);
        quad.name = "Checker (compressed texture)";
        quad.transform.position = new Vector3(1.4f, -0.6f, 0f);
        quad.transform.localScale = new Vector3(1.6f, 1.6f, 1f);
        var mat = new Material(Shader.Find("Unlit/Texture")) { mainTexture = MakeCheckerTexture() };
        AssetDatabase.CreateAsset(mat, MaterialPath);
        quad.GetComponent<Renderer>().sharedMaterial = mat;

        var probe = new GameObject("Phase0Probe").AddComponent<Phase0Probe>();
        probe.spinner = cube.transform;
        probe.texturedQuad = quad.GetComponent<Renderer>();

        EditorSceneManager.SaveScene(scene, ScenePath);
        AssetDatabase.SaveAssets();
        EditorBuildSettings.scenes = new[] { new EditorBuildSettingsScene(ScenePath, true) };
    }

    // A compressed texture: BC/DXT in the macOS build, ASTC in the iOS build.
    static Texture2D MakeCheckerTexture()
    {
        var tex = new Texture2D(256, 256, TextureFormat.RGBA32, false);
        for (int y = 0; y < 256; y++)
            for (int x = 0; x < 256; x++)
            {
                bool on = ((x / 32) + (y / 32)) % 2 == 0;
                tex.SetPixel(x, y, on ? new Color(0.95f, 0.65f, 0.15f) : new Color(0.15f, 0.35f, 0.85f));
            }
        File.WriteAllBytes(TexturePath, tex.EncodeToPNG());
        AssetDatabase.ImportAsset(TexturePath, ImportAssetOptions.ForceUpdate);
        var importer = (TextureImporter)AssetImporter.GetAtPath(TexturePath);
        importer.textureCompression = TextureImporterCompression.Compressed;
        importer.mipmapEnabled = false;
        importer.filterMode = FilterMode.Point;
        importer.SaveAndReimport();
        return AssetDatabase.LoadAssetAtPath<Texture2D>(TexturePath);
    }
}
