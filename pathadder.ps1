$ErrorActionPreference = 'Stop'
$entry = [IO.Path]::GetFullPath($PSScriptRoot)
if ($IsWindows) {
    $saved = [string][Environment]::GetEnvironmentVariable('Path', 'User')
    if ($entry -notin @($saved -split ';')) {
        [Environment]::SetEnvironmentVariable('Path', (($saved.TrimEnd(';') + ';' + $entry).TrimStart(';')), 'User')
    }
    if ($entry -notin @($env:PATH -split ';')) { $env:PATH += ';' + $entry }
    Write-Output 'Added gitdark to your user PATH. Reopen other terminals to use it there.'
} else {
    $bin = if ($env:XDG_BIN_HOME) { $env:XDG_BIN_HOME } else { Join-Path $env:HOME '.local/bin' }
    [void][IO.Directory]::CreateDirectory($bin)
    foreach ($name in @('gitdark','gitdarkive')) {
        $target = Join-Path $bin $name
        $source = Join-Path $entry $name
        $existing = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.LinkTarget -eq $source) { continue }
            throw "Refusing to replace $target"
        }
        [void][IO.File]::CreateSymbolicLink($target, $source)
    }
    if ($bin -notin @($env:PATH -split ':')) { $env:PATH = $bin + ':' + $env:PATH }
    Write-Output "Linked gitdark and gitdarkive in $bin. Keep this checkout in place; add that directory to your shell PATH if needed."
}
