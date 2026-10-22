$ErrorActionPreference = 'Stop'
$program = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../gitdark.ps1'))
$archiveProgram = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../gitdarkive.ps1'))
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gitdark-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$utf8 = [Text.UTF8Encoding]::new($false)
$gitBinary = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$script:Checks = 0
function Assert($Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
    $script:Checks++
}
function Write-File([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Git([string[]]$Arguments) {
    $output = & $gitBinary -C $temp @Arguments 2>&1
    if ($LASTEXITCODE) { throw ($output -join "`n") }
    return ($output -join "`n")
}
function Dark([string[]]$Arguments, [int]$Expected = 0, [switch]$Archive) {
    $file = if ($Archive) { $archiveProgram } else { $program }
    $output = & pwsh -NoLogo -NoProfile -File $file -C $temp @Arguments 2>&1
    if ($LASTEXITCODE -ne $Expected) { throw "gitdark $Arguments returned $LASTEXITCODE (expected $Expected): $($output -join "`n")" }
    return ($output -join "`n")
}
function Tree([string]$Store) {
    return @((Git @("--git-dir=$temp/$Store", 'ls-tree', '-r', '--name-only', 'HEAD', '-z')).Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))
}
try {
    [void](Git @('init', '-b', 'main'))
    foreach ($setting in @(@('user.name','Gitdark Test'),@('user.email','gitdark@example.invalid'),@('commit.gpgSign','false'),@('core.autocrlf','false'))) {
        [void](Git @('config',$setting[0],$setting[1]))
    }
    Write-File "$temp/.gitignore" "private/`n.env`n*.secret`n"
    Write-File "$temp/public.txt" 'public'
    Write-File "$temp/.env" 'secret key'
    Write-File "$temp/private/keep.txt" 'private'
    Write-File "$temp/private/remove.txt" 'drop from later snapshot'
    Write-File "$temp/private/not allowed.txt" 'excluded manually'
    Write-File "$temp/a[1].secret" 'pathspec metacharacters'
    Write-File "$temp/文 件.secret" 'Unicode'
    Write-File "$temp/pkg/.gitignore" "inside.cache`n"
    Write-File "$temp/pkg/inside.cache" 'nested ignore'
    Write-File "$temp/ignored.global" 'global ignore'
    Write-File "$temp/local-only.txt" 'info exclude'
    Write-File "$temp/.git/info/exclude" "local-only.txt`n"
    Write-File "$temp/.git/test-excludes" "*.global`n"
    [void](Git @('config','core.excludesFile',"$temp/.git/test-excludes"))
    [void](Git @('add','.'))
    [void](Git @('commit','-m','primary'))
    $head = Git @('rev-parse','HEAD')
    $index = (Get-FileHash "$temp/.git/index").Hash
    $config = (Get-FileHash "$temp/.git/config").Hash
    # Real staging/working-tree divergence must survive the alternate histories.
    Write-File "$temp/public.txt" 'staged public update'
    [void](Git @('add','public.txt'))
    Write-File "$temp/public.txt" 'unstaged public update'
    $index = (Get-FileHash "$temp/.git/index").Hash
    [void](Dark @('include'))
    $list = @(Get-Content "$temp/.gitinclude" -Raw | ConvertFrom-Json)
    foreach ($path in @('.env','private/keep.txt','a[1].secret','文 件.secret','pkg/inside.cache','ignored.global','local-only.txt')) {
        Assert ($list -ccontains $path) "Ignore rule missing from include: $path"
    }
    Assert (!(Test-Path "$temp/.gitdark")) 'include must not create a history'
    $list = @($list | Where-Object { $_ -ne 'private/not allowed.txt' })
    Write-File "$temp/.gitinclude" (ConvertTo-Json -InputObject ([string[]]$list))
    [void](Dark @('commit','-m','dark'))
    $tree = Tree '.gitdark'
    Assert ($tree.Count -eq $list.Count) 'Dark tree must match the literal allowlist'
    Assert ($tree -ccontains 'a[1].secret') 'Pathspec characters must remain literal'
    Assert ($tree -cnotcontains 'public.txt') 'Public files leaked into dark history'
    Assert ($tree -cnotcontains 'private/not allowed.txt') 'Excluded file leaked into dark history'
    Assert ((Dark @('-C','pkg','ls-files')) -eq 'inside.cache') 'Subdirectory Git paths must remain relative'
    $darkHead = Git @("--git-dir=$temp/.gitdark",'rev-parse','HEAD')
    Assert (!(Git @("--git-dir=$temp/.gitdark",'remote'))) 'No remotes should be inherited'
    [void](Dark @('commit','-m','archive') -Archive)
    $tree = Tree '.archive'
    foreach ($path in @('public.txt','.env','private/not allowed.txt')) { Assert ($tree -ccontains $path) "Archive missing $path" }
    Assert (!@($tree | Where-Object { $_ -match '^(\.git|\.gitdark|\.archive|\.gittemp)(/|$)|^\.gitinclude$' }).Count) 'Metadata recursion in archive'
    Assert ((Git @("--git-dir=$temp/.gitdark",'rev-parse','HEAD')) -eq $darkHead) 'Archive changed dark HEAD'
    [void](Dark @('add','public.txt') 1)
    [void](Dark @('add','private/keep.txt'))
    Write-File "$temp/private/keep.txt" 'updated'
    Remove-Item -LiteralPath "$temp/private/remove.txt"
    Write-File "$temp/private/new.txt" 'not automatically allowlisted'
    [void](Dark @('commit','-m','update'))
    $tree = Tree '.gitdark'
    Assert ($tree -cnotcontains 'private/remove.txt') 'Deletion not recorded'
    Assert ($tree -cnotcontains 'private/new.txt') 'New file silently allowlisted'
    Assert ((Git @("--git-dir=$temp/.gitdark",'show','HEAD:private/keep.txt')) -eq 'updated') 'File update missing'
    $list = @($list | Where-Object { $_ -ne 'private/keep.txt' })
    Write-File "$temp/.gitinclude" (ConvertTo-Json -InputObject ([string[]]$list))
    [void](Dark @('commit','-m','prune allowlist'))
    Assert ((Tree '.gitdark') -cnotcontains 'private/keep.txt') 'Removed allowlist entry remains tracked'
    Assert (Test-Path "$temp/private/keep.txt") 'Pruning index must not delete worktree data'
    [void](Dark @('--no','commit','-m','respect ignores') -Archive)
    $tree = Tree '.archive'
    Assert ($tree -ccontains 'public.txt') 'Archive --no lost public file'
    Assert ($tree -cnotcontains '.env') 'Archive --no retained ignored file'
    Assert ($tree -cnotcontains 'ignored.global') 'Archive --no ignored global rules'
    Assert ($tree -cnotcontains 'local-only.txt') 'Archive --no ignored info/exclude'
    Assert ((Git @('rev-parse','HEAD')) -eq $head) 'Normal HEAD changed'
    Assert ((Get-FileHash "$temp/.git/index").Hash -eq $index) 'Normal index changed'
    Assert ((Get-FileHash "$temp/.git/config").Hash -eq $config) 'Normal config changed'
    Assert ((Git @('show',':public.txt')) -eq 'staged public update') 'Normal staged content changed'
    Assert ([IO.File]::ReadAllText("$temp/public.txt") -eq 'unstaged public update') 'Normal working file changed'
    Assert (!(Test-Path "$temp/.gittemp")) 'Temporary metadata should never be needed'
    Write-File "$temp/.gitinclude" '[]'
    [void](Dark @('commit','-m','empty allowlist'))
    Assert ((Tree '.gitdark').Count -eq 0) 'An empty allowlist must produce an empty tree'
    foreach ($bad in @('../outside', '.git/config', '.archive/config')) {
        Write-File "$temp/.gitinclude" (ConvertTo-Json -InputObject ([string[]]@($bad)))
        [void](Dark @('commit','-m','invalid') 1)
    }
    Write-File "$temp/.gitinclude" '[]'
    [void](Dark @('log','--oneline'))
    [void](Dark @('archive','--format=tar','--output',"$temp/native.tar",'HEAD'))
    Assert (Test-Path "$temp/native.tar") 'Native git archive must not be shadowed'
    Assert ((Get-FileHash "$temp/.git/index").Hash -eq $index) 'Error path changed normal index'
    $oldDir = $env:GIT_DIR; $oldIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_DIR = "$temp/.archive"
        $env:GIT_INDEX_FILE = "$temp/.git/index"
        [void](Dark @('commit','--allow-empty','-m','isolated environment'))
    } finally { $env:GIT_DIR = $oldDir; $env:GIT_INDEX_FILE = $oldIndex }
    Assert ((Get-FileHash "$temp/.git/index").Hash -eq $index) 'Ambient Git variables redirected the private index'
    Assert ((Git @('rev-parse','HEAD')) -eq $head) 'Ambient Git variables redirected the private HEAD'
    # First commit can generate its include file without the explicit include step.
    [void][IO.Directory]::CreateDirectory("$temp/auto")
    [void](Git @('-C','auto','init','-b','main'))
    foreach ($setting in @(@('user.name','Gitdark Test'),@('user.email','gitdark@example.invalid'),@('commit.gpgSign','false'))) { [void](Git @('-C','auto','config',$setting[0],$setting[1])) }
    Write-File "$temp/auto/.gitignore" "private.txt`n"
    Write-File "$temp/auto/private.txt" 'first commit'
    [void](Dark @('-C','auto','commit','-m','auto include'))
    Assert (Test-Path "$temp/auto/.gitinclude") 'First commit must generate the missing include file'
    Assert ((Git @('-C','auto',"--git-dir=$temp/auto/.gitdark",'show','HEAD:private.txt')) -eq 'first commit') 'First automatic commit lost its private file'
    Write-Output "PASS: $script:Checks checks; three independent histories, ignore sources, literal names, changes/deletions, allowlist pruning, --no, and primary-history isolation."
} finally {
    # Only the exact disposable directory created above is eligible for removal.
    $resolved = [IO.Path]::GetFullPath($temp)
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd([IO.Path]::DirectorySeparatorChar) -eq $base.TrimEnd([IO.Path]::DirectorySeparatorChar) -and [IO.Path]::GetFileName($resolved) -like 'gitdark-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
