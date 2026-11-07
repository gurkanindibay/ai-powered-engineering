using DevFactory.Core.Models;
using DevFactory.Harness;
using Xunit;

namespace DevFactory.Tests;

public class WorkspaceSandboxTests
{
    private static ProjectSourceFile File(string path, string content = "class A {}") =>
        new() { ProjectName = "App", RelativePath = path, Content = content };

    [Theory]
    [InlineData("../escape.cs")]
    [InlineData("src/../../escape.cs")]
    [InlineData("/etc/passwd")]
    [InlineData("")]
    public async Task WriteFilesAsync_RejectsPathsOutsideTheSandbox(string path)
    {
        var baseDir = Path.Combine(Path.GetTempPath(), "devfactory_sandbox_tests_" + Guid.NewGuid().ToString("N"));
        using var sandbox = new WorkspaceSandbox(baseDir);
        await sandbox.InitializeAsync();

        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => sandbox.WriteFilesAsync(new[] { File(path) }));
        Assert.False(System.IO.File.Exists(Path.Combine(baseDir, "escape.cs")));
    }

    [Fact]
    public async Task WriteFilesAsync_RejectsSiblingDirectoryWithSharedPrefix()
    {
        using var sandbox = new WorkspaceSandbox();
        await sandbox.InitializeAsync();
        var sibling = "../" + Path.GetFileName(sandbox.WorkingDirectory) + "_evil/x.cs";
        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => sandbox.WriteFilesAsync(new[] { File(sibling) }));
    }

    [Theory]
    [InlineData("Directory.Build.props", "<Project />")]
    [InlineData("src/evil.targets", "<Project />")]
    [InlineData("src/App/App.csproj", "<Project Sdk=\"Microsoft.NET.Sdk\"><Target Name=\"X\" BeforeTargets=\"Build\"><Exec Command=\"rm -rf ~\" /></Target></Project>")]
    public async Task WriteFilesAsync_RejectsBuildExtensionPoints(string path, string content)
    {
        using var sandbox = new WorkspaceSandbox();
        await sandbox.InitializeAsync();
        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => sandbox.WriteFilesAsync(new[] { File(path, content) }));
    }

    [Fact]
    public async Task WriteFilesAsync_WritesNormalSourcesInsideTheSandbox()
    {
        using var sandbox = new WorkspaceSandbox();
        await sandbox.InitializeAsync();
        await sandbox.WriteFilesAsync(new[]
        {
            File("src/App/App.csproj", "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>"),
            File("src/App/Program.cs"),
        });
        Assert.Equal("class A {}", await sandbox.ReadFileAsync("src/App/Program.cs"));
        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => sandbox.ReadFileAsync("../../etc/hosts"));
    }
}
