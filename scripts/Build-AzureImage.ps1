#requires -Version 7.2
[CmdletBinding()]
param([string]$Tag = ('poc-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')))
. "$PSScriptRoot\Azure-Common.ps1"
Assert-AzureContext
if ($Tag -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,100}$') { throw 'Invalid image tag.' }
$outputs = Get-BootstrapOutputs
$context = Join-Path $script:RepositoryRoot ('.azure-build-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $context
try {
    # ACR CLI packaging does not necessarily honor Dockerfile-specific ignore files.
    # Stage an explicit allowlist, never upload .git, .azure, storage, or config.toml.
    foreach ($file in @('Dockerfile.azure', 'Dockerfile.azure.dockerignore', 'pyproject.toml',
            'uv.lock', 'LICENSE', 'config.example.toml')) {
        Copy-Item (Join-Path $script:RepositoryRoot $file) $context
    }
    Copy-Item (Join-Path $script:RepositoryRoot 'Dockerfile.azure.dockerignore') (Join-Path $context '.dockerignore')
    foreach ($directory in @('app', 'webui', 'resource\public')) {
        $source = Join-Path $script:RepositoryRoot $directory
        foreach ($file in Get-ChildItem $source -File -Recurse) {
            $relative = [IO.Path]::GetRelativePath($script:RepositoryRoot, $file.FullName)
            if ($relative -match '(^|[\\/])(__pycache__|\.venv|\.git)([\\/]|$)' -or
                $file.Name -match '^\.env' -or $file.Extension -in @('.pyc', '.pem', '.key', '.log')) { continue }
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Build context cannot contain symlinks.' }
            $destination = Join-Path $context $relative
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            Copy-Item $file.FullName $destination
        }
    }
    Invoke-Az @('acr', 'build', '--registry', $outputs.AZURE_CONTAINER_REGISTRY_NAME,
        '--image', "moneyprinterturbo:$Tag", '--file', 'Dockerfile.azure',
        '--platform', 'linux/amd64', '--timeout', '7200', $context, '--output', 'none') | Out-Host
    $digest = Invoke-Az @('acr', 'repository', 'show', '--name', $outputs.AZURE_CONTAINER_REGISTRY_NAME,
        '--image', "moneyprinterturbo:$Tag", '--query', 'digest', '--output', 'tsv')
    if ($digest -notmatch '^sha256:[a-f0-9]{64}$') { throw 'ACR did not return an immutable image digest.' }
    $env:MPT_CONTAINER_IMAGE = "$($outputs.AZURE_CONTAINER_REGISTRY_ENDPOINT)/moneyprinterturbo@$digest"
    Write-Host "MPT_CONTAINER_IMAGE=$env:MPT_CONTAINER_IMAGE"
}
finally {
    if (Test-Path $context) { Remove-Item -LiteralPath $context -Recurse -Force }
}
