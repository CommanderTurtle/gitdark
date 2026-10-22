#!/usr/bin/env pwsh
# Requires PowerShell 7 and Git. Each history has its own index and object store.
$ErrorActionPreference = 'Stop'
$script:GitExe = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:Reserved = @('.git', '.gitdark', '.archive', '.gittemp', '.gitinclude')

function Invoke-Git([string[]]$Arguments, [string]$Directory, [string]$InputText, [switch]$Quiet, [switch]$Live) {
    $info = [Diagnostics.ProcessStartInfo]::new($script:GitExe)
    $info.WorkingDirectory = $Directory
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = !$Live
    $info.RedirectStandardError = !$Live
    $info.RedirectStandardInput = !$Live
    if (!$Live) {
        $info.StandardOutputEncoding = $script:Utf8
        $info.StandardErrorEncoding = $script:Utf8
        $info.StandardInputEncoding = $script:Utf8
    }
    # Do not inherit another repository's index, worktree or object database.
    foreach ($key in @($info.Environment.Keys)) {
        if ($key -match '^GIT_(DIR|COMMON_DIR|WORK_TREE|INDEX_FILE|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|PREFIX|NAMESPACE|CEILING_DIRECTORIES|DISCOVERY_ACROSS_FILESYSTEM|CONFIG|CONFIG_COUNT|CONFIG_KEY_\d+|CONFIG_VALUE_\d+)$') {
            [void]$info.Environment.Remove($key)
        }
    }
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        if ($Live) { $process.WaitForExit(); return @{ Code = $process.ExitCode; Text = ''; Error = '' } }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        $process.WaitForExit()
        $result = @{ Code = $process.ExitCode; Text = $output.GetAwaiter().GetResult(); Error = $errors.GetAwaiter().GetResult() }
        if (!$Quiet) {
            [Console]::Out.Write($result.Text)
            [Console]::Error.Write($result.Error)
        }
        return $result
    } finally { $process.Dispose() }
}

function Require-Git($Result) {
    if ($Result.Code -ne 0) { throw ($Result.Error.Trim() + " (git exit $($Result.Code))") }
    return $Result.Text
}

function Is-Reserved([string]$Path) {
    $first = $Path.Split('/')[0]
    return $script:Reserved -icontains $first
}

function File-List([string[]]$Options) {
    $exclude = @($script:Reserved | ForEach-Object { ":(top,exclude,literal)$_" })
    $text = Require-Git (Invoke-Git (@('-C', $script:Root, 'ls-files', '-z') + $Options + @('--', '.') + $exclude) $script:Root -Quiet)
    return @($text.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries) | Sort-Object -Unique -CaseSensitive)
}

function Write-Include {
    $paths = @(File-List @('--others', '--ignored', '--exclude-standard'))
    $file = Join-Path $script:Root '.gitinclude'
    if ((Test-Path -LiteralPath $file) -and ((Get-Item -LiteralPath $file -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '.gitinclude must not be a symlink.' }
    # JSON keeps literal spaces, Unicode, newlines and pathspec metacharacters safe.
    $text = ConvertTo-Json -InputObject ([string[]]$paths)
    [IO.File]::WriteAllText($file, $text + "`n", $script:Utf8)
    [Console]::Out.WriteLine(".gitinclude: $($paths.Count) ignored files. Edit the list before committing secrets.")
}

function Read-Include {
    $file = Join-Path $script:Root '.gitinclude'
    if (!(Test-Path -LiteralPath $file)) { Write-Include }
    $raw = [IO.File]::ReadAllText($file, $script:Utf8).Trim()
    if (!$raw.StartsWith('[')) { throw '.gitinclude must be a JSON array of literal repository-relative file paths.' }
    $paths = @($raw | ConvertFrom-Json -NoEnumerate)
    # -NoEnumerate returns the array as one object; retain its entries explicitly.
    $paths = @($paths[0])
    foreach ($path in $paths) {
        if ($path -isnot [string] -or !$path -or [IO.Path]::IsPathRooted($path) -or $path.Contains([char]0) -or
            @($path.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -or (Is-Reserved $path)) {
            throw "Invalid or reserved .gitinclude path: $path"
        }
        if ($IsWindows -and $path.Contains('\')) { throw '.gitinclude paths use forward slashes, including on Windows.' }
        $resolved = [IO.Path]::GetFullPath((Join-Path $script:Root $path))
        $relative = [IO.Path]::GetRelativePath($script:Root, $resolved)
        if ($relative -eq '..' -or $relative.StartsWith('../') -or $relative.StartsWith('..\')) { throw "Path escapes the repository: $path" }
    }
    return @($paths | Sort-Object -Unique -CaseSensitive)
}

function Alt-Git([string[]]$Arguments, [string]$InputText, [switch]$Quiet, [switch]$Live) {
    $where = if ($Live) { $script:CommandDirectory } else { $script:Root }
    return Invoke-Git (@(('--git-dir=' + $script:Store), ('--work-tree=' + $script:Root)) + $Arguments) $where $InputText -Quiet:$Quiet -Live:$Live
}

function Stage-Snapshot([string[]]$Selection, [string[]]$Filters) {
    $trackedText = Require-Git (Alt-Git @('ls-files', '--cached', '-z') -Quiet)
    $tracked = @($trackedText.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Selection) { [void]$allowed.Add($path) }
    foreach ($filter in $Filters) {
        if ($filter -ne '.' -and !@($Selection | Where-Object { $_ -ceq $filter -or $_.StartsWith($filter.TrimEnd('/') + '/', [StringComparison]::Ordinal) }).Count) {
            throw "Path is not in the selected snapshot: $filter"
        }
    }
    $wanted = [Collections.Generic.List[string]]::new()
    foreach ($path in $Selection) {
        if (Is-Reserved $path) { continue }
        $full = Join-Path $script:Root $path
        if (![IO.File]::Exists($full) -and !(Test-Path -LiteralPath $full)) { continue }
        $item = Get-Item -LiteralPath $full -Force
        if ($item.PSIsContainer -and !$item.LinkType) { throw "Nested repository/directory is not a file: $path. Run gitdark separately inside it." }
        if ($Filters.Count) {
            $matched = $false
            foreach ($filter in $Filters) {
                if ($filter -eq '.' -or $path -ceq $filter -or $path.StartsWith($filter.TrimEnd('/') + '/', [StringComparison]::Ordinal)) { $matched = $true; break }
            }
            if (!$matched) { continue }
        }
        $wanted.Add($path)
    }
    $remove = @($tracked | Where-Object { !$allowed.Contains($_) -or !(Test-Path -LiteralPath (Join-Path $script:Root $_)) -or (Is-Reserved $_) })
    if ($remove.Count) { [void](Require-Git (Alt-Git @('update-index', '--force-remove', '-z', '--stdin') (($remove -join "`0") + "`0") -Quiet)) }
    if ($wanted.Count) {
        [void](Require-Git (Alt-Git @('--literal-pathspecs', 'add', '--force', '--all', '--pathspec-from-file=-', '--pathspec-file-nul') (($wanted -join "`0") + "`0") -Quiet))
    }
}

function Show-Help {
    @'
gitdark include                 Generate .gitinclude from currently ignored files
gitdark commit -m "private"     Snapshot the explicit allowlist into .gitdark
gitdark add [literal paths...]  Stage selected allowlisted files (optional)
gitdark log / status / diff     Normal Git commands in .gitdark
gitdark gitdarkive <command>    Same as gitdarkive; history lives in .archive
gitdarkive commit -m "backup"   Snapshot all worktree files, including ignored files
gitdarkive --no commit -m "pub" Respect ordinary Git ignores for this snapshot

Use -C PATH before the command to select a repository. Git and PowerShell 7 are
required. No directories are renamed, no primary index/config is changed, and
no remotes are inherited. Separate history is not encryption. See README.md.
'@ | Write-Output
}

try {
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($arg in $args) { $arguments.Add([string]$arg) }
    $directory = (Get-Location).ProviderPath
    $archive = $false
    $no = $false
    while ($arguments.Count) {
        if ($arguments[0] -eq '-C') {
            if ($arguments.Count -lt 2) { throw '-C requires a directory.' }
            $directory = [IO.Path]::GetFullPath($arguments[1], $directory)
            $arguments.RemoveRange(0, 2)
        } elseif (!$archive -and $arguments[0] -eq 'gitdarkive') {
            $archive = $true; $arguments.RemoveAt(0)
        } elseif ($archive -and $arguments[0] -eq '--no') {
            $no = $true; $arguments.RemoveAt(0)
        } else { break }
    }
    if (!$arguments.Count -or $arguments[0] -in @('--help', '-h') -or ($arguments[0] -eq 'help' -and $arguments.Count -eq 1)) { Show-Help; exit 0 }
    $script:Root = (Require-Git (Invoke-Git @('rev-parse', '--show-toplevel') $directory -Quiet)).TrimEnd("`r", "`n")
    $script:CommandDirectory = $directory
    $script:Store = Join-Path $script:Root $(if ($archive) { '.archive' } else { '.gitdark' })
    if ((Test-Path -LiteralPath $script:Store) -and ((Get-Item -LiteralPath $script:Store -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Alternate Git directories must not be symlinks or junctions.' }
    if (Test-Path -LiteralPath (Join-Path $script:Store 'commondir')) { throw 'Alternate histories must not share a Git common directory.' }
    $command = $arguments[0]
    if ($command -eq 'include') {
        if ($archive -or $arguments.Count -ne 1) { throw 'Usage: gitdark include' }
        Write-Include
        exit 0
    }
    if (!(Test-Path -LiteralPath (Join-Path $script:Store 'HEAD'))) {
        if ($command -notin @('init', 'commit', 'add')) { throw "No $([IO.Path]::GetFileName($script:Store)) history yet. Run commit or init first." }
        if (Test-Path -LiteralPath $script:Store) { throw "Refusing to initialize an existing non-repository: $script:Store" }
        $init = if ($command -eq 'init') { $arguments.ToArray() } else { @('init') }
        [void](Require-Git (Alt-Git $init -Quiet))
        [void](Require-Git (Alt-Git @('config', 'status.showUntrackedFiles', 'no') -Quiet))
        foreach ($key in @('user.name', 'user.email')) {
            $identity = Invoke-Git @('config', '--get', $key) $script:Root -Quiet
            if ($identity.Code -eq 0) { [void](Require-Git (Alt-Git @('config', $key, $identity.Text.TrimEnd("`r", "`n")) -Quiet)) }
        }
        if ($command -eq 'init') { [Console]::Out.WriteLine("Initialized $script:Store"); exit 0 }
    }
    if ($command -in @('add', 'commit')) {
        # An OS-held lock is automatically released even when the process is killed.
        $lock = [IO.File]::Open((Join-Path $script:Store 'gitdark.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $selection = if (!$archive) { @(Read-Include) } elseif ($no) { @(File-List @('--cached', '--others', '--exclude-standard')) } else { @(File-List @('--cached', '--others')) }
            $filters = @()
            if ($command -eq 'add') {
                foreach ($path in @($arguments.ToArray() | Select-Object -Skip 1)) {
                    if ($path -in @('--', '-A', '--all', '-f', '--force')) { continue }
                    if ($path.StartsWith('-')) { throw 'add supports literal paths, -A and -f; interactive staging is not supported.' }
                    $full = [IO.Path]::GetFullPath($path, $directory)
                    $filters += [IO.Path]::GetRelativePath($script:Root, $full).Replace([IO.Path]::DirectorySeparatorChar, '/')
                }
            }
            Stage-Snapshot $selection $filters
            if ($command -eq 'add') { exit 0 }
            $result = Alt-Git $arguments.ToArray() -Live
            exit $result.Code
        } finally { $lock.Dispose() }
    }
    $result = Alt-Git $arguments.ToArray() -Live
    exit $result.Code
} catch {
    [Console]::Error.WriteLine('gitdark: ' + $_.Exception.Message)
    exit 1
}
