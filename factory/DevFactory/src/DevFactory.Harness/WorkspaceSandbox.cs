using DevFactory.Core.Interfaces;
using DevFactory.Core.Models;

namespace DevFactory.Harness;

public class WorkspaceSandbox : IWorkspaceSandbox
{
    public string WorkingDirectory { get; }
    private readonly bool _preserveOnDispose;

    public WorkspaceSandbox(string? customBaseDir = null, bool preserveOnDispose = false)
    {
        _preserveOnDispose = preserveOnDispose;
        var root = customBaseDir ?? Path.Combine(Path.GetTempPath(), "devfactory_sandboxes");
        Directory.CreateDirectory(root);
        WorkingDirectory = Path.Combine(root, $"build_{Guid.NewGuid():N}");
    }

    public Task InitializeAsync(CancellationToken ct = default)
    {
        if (!Directory.Exists(WorkingDirectory))
        {
            Directory.CreateDirectory(WorkingDirectory);
        }
        return Task.CompletedTask;
    }

    /// <summary>
    /// File names that let a generated project hook arbitrary MSBuild logic into
    /// <c>dotnet build</c>/<c>dotnet test</c>, which run with the host user's privileges.
    /// </summary>
    private static readonly string[] ForbiddenFileNames =
    {
        "Directory.Build.props", "Directory.Build.targets", "Directory.Build.rsp",
        "Directory.Packages.props", "NuGet.config", "nuget.config", "global.json",
    };

    private static readonly string[] ForbiddenExtensions = { ".targets", ".props", ".tasks" };

    /// <summary>MSBuild elements that execute code or extend the build (whole element names only).</summary>
    private static readonly System.Text.RegularExpressions.Regex ForbiddenProjectElements =
        new(@"<\s*(Exec|UsingTask|Target|Import)\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    /// <summary>
    /// Resolves an agent-supplied relative path inside the sandbox, rejecting
    /// absolute paths and any path that escapes the sandbox root (e.g. <c>../</c>).
    /// </summary>
    public string ResolveInside(string relativePath)
    {
        if (string.IsNullOrWhiteSpace(relativePath) || Path.IsPathRooted(relativePath))
        {
            throw new UnauthorizedAccessException($"Path '{relativePath}' must be relative to the sandbox.");
        }

        var root = Path.GetFullPath(WorkingDirectory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var fullPath = Path.GetFullPath(Path.Combine(root, relativePath));
        if (!fullPath.StartsWith(root, StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException($"Path '{relativePath}' escapes the sandbox.");
        }

        return fullPath;
    }

    /// <summary>Rejects files that could run code during the build outside the generated sources.</summary>
    public static void EnsureBuildSafe(ProjectSourceFile file)
    {
        var name = Path.GetFileName(file.RelativePath);
        if (ForbiddenFileNames.Contains(name, StringComparer.OrdinalIgnoreCase) ||
            ForbiddenExtensions.Contains(Path.GetExtension(name), StringComparer.OrdinalIgnoreCase))
        {
            throw new UnauthorizedAccessException($"Generated file '{file.RelativePath}' is not allowed: it can extend the MSBuild pipeline.");
        }

        if (name.EndsWith("proj", StringComparison.OrdinalIgnoreCase) &&
            ForbiddenProjectElements.IsMatch(file.Content))
        {
            throw new UnauthorizedAccessException($"Project '{file.RelativePath}' declares custom MSBuild targets, tasks or imports.");
        }
    }

    public async Task WriteFilesAsync(IEnumerable<ProjectSourceFile> files, CancellationToken ct = default)
    {
        // Validate the whole batch first so a rejected file leaves nothing half-written.
        var resolved = files.Select(f =>
        {
            EnsureBuildSafe(f);
            return (File: f, FullPath: ResolveInside(f.RelativePath));
        }).ToList();

        foreach (var (file, fullPath) in resolved)
        {
            var dir = Path.GetDirectoryName(fullPath);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
            {
                Directory.CreateDirectory(dir);
            }

            await File.WriteAllTextAsync(fullPath, file.Content, ct);
        }
    }

    public async Task<string> ReadFileAsync(string relativePath, CancellationToken ct = default)
    {
        var fullPath = ResolveInside(relativePath);
        if (!File.Exists(fullPath))
        {
            throw new FileNotFoundException($"File '{relativePath}' not found in sandbox.");
        }

        return await File.ReadAllTextAsync(fullPath, ct);
    }

    public Task ExportToAsync(string destinationDirectory, CancellationToken ct = default)
    {
        if (!Directory.Exists(destinationDirectory))
        {
            Directory.CreateDirectory(destinationDirectory);
        }

        CopyDirectory(WorkingDirectory, destinationDirectory);
        return Task.CompletedTask;
    }

    private static void CopyDirectory(string sourceDir, string targetDir)
    {
        foreach (var dirPath in Directory.GetDirectories(sourceDir, "*", SearchOption.AllDirectories))
        {
            // Skip bin, obj, and git caches
            if (dirPath.Contains(Path.DirectorySeparatorChar + "bin") || dirPath.Contains(Path.DirectorySeparatorChar + "obj"))
            {
                continue;
            }

            var subDir = Path.Combine(targetDir, Path.GetRelativePath(sourceDir, dirPath));
            Directory.CreateDirectory(subDir);
        }

        foreach (var filePath in Directory.GetFiles(sourceDir, "*.*", SearchOption.AllDirectories))
        {
            if (filePath.Contains(Path.DirectorySeparatorChar + "bin" + Path.DirectorySeparatorChar) ||
                filePath.Contains(Path.DirectorySeparatorChar + "obj" + Path.DirectorySeparatorChar))
            {
                continue;
            }

            var destFile = Path.Combine(targetDir, Path.GetRelativePath(sourceDir, filePath));
            var destDir = Path.GetDirectoryName(destFile);
            if (!string.IsNullOrEmpty(destDir) && !Directory.Exists(destDir))
            {
                Directory.CreateDirectory(destDir);
            }

            File.Copy(filePath, destFile, overwrite: true);
        }
    }

    public void Dispose()
    {
        if (!_preserveOnDispose && Directory.Exists(WorkingDirectory))
        {
            try
            {
                Directory.Delete(WorkingDirectory, recursive: true);
            }
            catch
            {
                // Ignore transient file lock cleanup errors on OS temp
            }
        }
    }
}
