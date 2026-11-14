<#
.SYNOPSIS
  Agent Memory Kit: a shared, reviewable, "dreaming" memory for any coding agent.

.DESCRIPTION
  Run with no arguments (or double-click Setup.cmd) for a menu.
  Or run one action directly:
    .\setup.ps1 -Action install
    .\setup.ps1 -Action init -Project D:\code\myapp
    .\setup.ps1 -Action backfill -Project D:\code\myapp -Tool antigravity
    .\setup.ps1 -Action dream    -Project D:\code\myapp -Tool codex
    .\setup.ps1 -Action review   -Project D:\code\myapp
    .\setup.ps1 -Action status   -Project D:\code\myapp
    .\setup.ps1 -Action uninstall
  Settings live in config.json next to this file.
#>
[CmdletBinding()]
param(
    [ValidateSet('menu', 'install', 'init', 'backfill', 'dream', 'review', 'status', 'uninstall')]
    [string]$Action = 'menu',
    [string]$Project,
    [string]$Tool,
    [string]$Profile,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$script:Kit = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:StartMark = '<!-- agent-memory:start -->'
$script:EndMark = '<!-- agent-memory:end -->'
$script:ProjectFromArgs = $PSBoundParameters.ContainsKey('Project')

# ---------------------------------------------------------------- helpers

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Ok([string]$text) { Write-Host ('  [ok] ' + $text) -ForegroundColor Green }
function Warn([string]$text) { Write-Host ('  [!!] ' + $text) -ForegroundColor Yellow }
function Head([string]$text) { Write-Host ''; Write-Host $text -ForegroundColor Cyan }

function Read-Text([string]$path) {
    return [System.IO.File]::ReadAllText($path, $script:Utf8)
}

function Write-Text([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($path, $text, $script:Utf8)
}

function Expand-Path([string]$p) {
    if ($p -like '~*') { $p = $HOME + $p.Substring(1) }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    return $p.Replace('/', [string][System.IO.Path]::DirectorySeparatorChar)
}

function Get-Config {
    $p = Join-Path $script:Kit 'config.json'
    if (-not (Test-Path -LiteralPath $p)) { throw 'config.json was not found next to setup.ps1' }
    return (Read-Text $p | ConvertFrom-Json)
}

function Get-Template([string]$name) {
    $p = Join-Path (Join-Path $script:Kit 'templates') $name
    if (-not (Test-Path -LiteralPath $p)) { throw ("Template missing: " + $name) }
    return (Read-Text $p)
}

function Fill([string]$text, [hashtable]$map) {
    foreach ($k in $map.Keys) { $text = $text.Replace('{{' + $k + '}}', [string]$map[$k]) }
    return $text
}

function Get-MemoryHome($cfg) { return (Expand-Path $cfg.memoryHome) }

function Has-Git { return [bool](Get-Command git -ErrorAction SilentlyContinue) }

function Run-Git([string]$dir, [string[]]$gitArgs) {
    # Windows PowerShell 5.1 turns native stderr into errors when ErrorActionPreference is Stop
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & git -C $dir @gitArgs 2>&1 | Out-Null; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
}

function Set-Block([string]$file, [string]$body, [string]$where = 'end') {
    $block = $script:StartMark + "`r`n" + $body.Trim() + "`r`n" + $script:EndMark
    $existing = ''
    if (Test-Path -LiteralPath $file) {
        $existing = Read-Text $file
        $bak = $file + '.agent-memory.bak'
        if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $file -Destination $bak }
    }
    $pattern = '(?s)' + [regex]::Escape($script:StartMark) + '.*?' + [regex]::Escape($script:EndMark)
    if ([regex]::IsMatch($existing, $pattern)) {
        $new = [regex]::Replace($existing, $pattern, $block.Replace('$', '$$'))
    }
    elseif ($existing.Trim().Length -eq 0) {
        $new = $block + "`r`n"
    }
    elseif ($where -eq 'start') {
        $new = $block + "`r`n`r`n" + $existing
    }
    else {
        $new = $existing.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
    }
    Write-Text $file $new
}

function Remove-Block([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    $existing = Read-Text $file
    $pattern = '(?s)\r?\n*' + [regex]::Escape($script:StartMark) + '.*?' + [regex]::Escape($script:EndMark) + '\r?\n*'
    if (-not [regex]::IsMatch($existing, $pattern)) { return $false }
    $new = [regex]::Replace($existing, $pattern, "`r`n")
    Write-Text $file ($new.TrimEnd() + "`r`n")
    return $true
}

function Has-Block([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    return (Read-Text $file).Contains($script:StartMark)
}

function Pick-Folder([string]$prompt, [string]$default) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = $prompt
        $d.SelectedPath = $default
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
        return $null
    }
    catch {
        $p = Read-Host ($prompt + ' [' + $default + ']')
        if ([string]::IsNullOrWhiteSpace($p)) { return $default }
        return $p
    }
}

function Resolve-Project {
    $p = $script:Project
    if ([string]::IsNullOrWhiteSpace($p)) {
        Say 'Choose your project folder in the window that opens (or type its path).'
        $p = Pick-Folder 'Choose the project folder' (Get-Location).Path
    }
    if ([string]::IsNullOrWhiteSpace($p)) { throw 'No project chosen.' }
    $p = (Expand-Path $p)
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw ('Folder not found: ' + $p) }
    return (Resolve-Path -LiteralPath $p).Path
}

function Get-EnabledAgents($cfg) {
    return @($cfg.agents | Where-Object { $_.enabled })
}

function Select-Tool($cfg, [string]$prompt, [string]$suggest) {
    if (-not [string]::IsNullOrWhiteSpace($script:Tool)) { return $script:Tool }
    $names = @(Get-EnabledAgents $cfg | ForEach-Object { $_.name })
    $names += 'other'
    Say $prompt
    for ($i = 0; $i -lt $names.Count; $i++) {
        $mark = ''
        if ($names[$i] -eq $suggest) { $mark = '   <- suggested' }
        Say ('  ' + ($i + 1) + ') ' + $names[$i] + $mark)
    }
    $c = Read-Host 'Number'
    $n = 0
    if (-not [int]::TryParse($c, [ref]$n) -or $n -lt 1 -or $n -gt $names.Count) { throw 'Not a valid choice.' }
    if ($names[$n - 1] -eq 'other') {
        $o = Read-Host 'Name of the agent (lowercase, no spaces)'
        if ([string]::IsNullOrWhiteSpace($o)) { throw 'No name given.' }
        return $o.Trim().ToLower()
    }
    return $names[$n - 1]
}

function Get-Notes([string]$proj) {
    $inbox = Join-Path $proj '.agent-memory/inbox'
    $result = @()
    if (-not (Test-Path -LiteralPath $inbox)) { return $result }
    foreach ($f in (Get-ChildItem -LiteralPath $inbox -Filter '*.md' -File)) {
        $status = 'unknown'
        $tool = 'unknown'
        foreach ($l in (Get-Content -LiteralPath $f.FullName -TotalCount 8 -Encoding UTF8)) {
            if ($l -match '^\s*status:\s*(\S+)') { $status = $Matches[1] }
            elseif ($l -match '^\s*tool:\s*(\S+)') { $tool = $Matches[1] }
        }
        $result += [pscustomobject]@{ Name = $f.Name; Status = $status; Tool = $tool; Path = $f.FullName }
    }
    return $result
}

function Send-Prompt([string]$text, [string]$kind, [string]$tool, [string]$proj, $cfg) {
    $dir = Join-Path (Get-MemoryHome $cfg) 'dream'
    $file = Join-Path $dir ('last-' + $kind + '-' + $tool + '.md')
    Write-Text $file $text
    $copied = $false
    try { Set-Clipboard -Value $text; $copied = $true } catch { }
    Head 'Prompt ready'
    if ($copied) { Ok 'Copied to your clipboard.' } else { Warn ('Clipboard unavailable. Open this file and copy it: ' + $file) }
    Say ('  1. Open this folder in ' + $tool + ':  ' + $proj) 'White'
    Say '  2. Start a NEW thread/chat (check the workspace name at the top).' 'White'
    Say '  3. Paste (Ctrl+V) and send.' 'White'
    Say ('  A copy is saved at: ' + $file)
}

# ---------------------------------------------------------------- actions

function Invoke-Install {
    $cfg = Get-Config
    $mem = Get-MemoryHome $cfg
    Head ('Installing shared memory at ' + $mem)

    foreach ($d in @('global', 'dream')) { New-Item -ItemType Directory -Force -Path (Join-Path $mem $d) | Out-Null }

    $map = @{ MEMORY_HOME = $mem; GLOBAL_FILE = (Join-Path $mem 'AGENTS.global.md'); GLOBAL_INDEX = (Join-Path $mem 'global/INDEX.md') }
    Write-Text (Join-Path $mem 'AGENTS.global.md') (Fill (Get-Template 'AGENTS.global.md') $map)
    Ok 'Wrote AGENTS.global.md (the shared rules every agent reads)'

    $idx = Join-Path $mem 'global/INDEX.md'
    if (-not (Test-Path -LiteralPath $idx)) {
        Write-Text $idx "# Global memory index`r`n(Empty for now. Lessons confirmed in two projects or by two agents get added here.)`r`n"
        Ok 'Created global\INDEX.md'
    }

    if (Has-Git) {
        if (-not (Test-Path -LiteralPath (Join-Path $mem '.git'))) {
            Run-Git $mem @('init') | Out-Null
            Run-Git $mem @('config', 'core.autocrlf', 'false') | Out-Null
            Ok 'Started a git repo for the shared memory (history = rollback)'
        }
        Run-Git $mem @('add', '-A') | Out-Null
        Run-Git $mem @('commit', '-m', 'agent-memory-kit: install') | Out-Null
        $head = Run-Git $mem @('rev-parse', '--verify', 'HEAD')
        if ($head -ne 0) { Warn 'Could not create the first git commit (set git user.name and user.email). Memory still works.' }
    }
    else { Warn 'git not found. Memory will work, but you lose history and rollback.' }

    Head 'Connecting agents'
    $pointer = Fill (Get-Template 'agent-pointer.md') $map
    foreach ($a in (Get-EnabledAgents $cfg)) {
        foreach ($g in $a.globalFiles) {
            $path = Expand-Path $g.path
            $exists = Test-Path -LiteralPath $path
            if (-not $exists -and -not $g.createIfMissing) {
                Say ('  skip ' + $a.name + ': ' + $path + ' (not present, and createIfMissing is false)')
                continue
            }
            Set-Block $path $pointer 'end'
            Ok ($a.name + ': ' + $path)
        }
    }
    Say ''
    Say 'Agents that are disabled in config.json were not touched.'
    Say 'Next: run the menu again and choose "Set up a project".' 'White'
}

function Detect-Profile([string]$proj, $cfg) {
    if ($script:Profile -and $cfg.profiles.PSObject.Properties.Name -contains $script:Profile) { return $script:Profile }
    $names = @(Get-ChildItem -LiteralPath $proj -Force -File | ForEach-Object { $_.Name })
    if ($names -contains 'build.gradle' -or $names -contains 'build.gradle.kts' -or $names -contains 'settings.gradle' -or $names -contains 'settings.gradle.kts') { return 'android' }
    if ($names -contains 'package.json') { return 'node' }
    if ($names -contains 'pyproject.toml' -or $names -contains 'requirements.txt') { return 'python' }
    return 'default'
}

function Invoke-Init {
    $cfg = Get-Config
    $mem = Get-MemoryHome $cfg
    if (-not (Test-Path -LiteralPath (Join-Path $mem 'AGENTS.global.md'))) {
        Warn 'The shared memory is not installed yet. Run the "Install" step first.'
        return
    }
    $proj = Resolve-Project
    $name = Split-Path -Leaf $proj
    $pm = Join-Path $proj '.agent-memory'
    Head ('Setting up project: ' + $name)

    $profName = Detect-Profile $proj $cfg
    $prof = $cfg.profiles.$profName
    Ok ('Profile: ' + $profName + ' (' + $prof.description + '). Change with -Profile or edit .agent-memory\config.json')

    foreach ($d in @('memory', 'inbox', 'proposals', 'archive')) { New-Item -ItemType Directory -Force -Path (Join-Path $pm $d) | Out-Null }
    $keep = Join-Path $pm 'memory/.gitkeep'
    if (-not (Test-Path -LiteralPath $keep)) { Write-Text $keep '' }

    # Never-open list: config + profile + what is actually in this repo's root
    $never = New-Object System.Collections.Generic.List[string]
    foreach ($n in $cfg.neverOpen) { $never.Add([string]$n) }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($item in (Get-ChildItem -LiteralPath $proj -Force)) {
        if ($item.PSIsContainer) {
            if ($cfg.sensitiveFolders -contains $item.Name) { $found.Add($item.Name + '/') }
        }
        else {
            foreach ($pat in $cfg.sensitiveFilePatterns) {
                if ($item.Name -like $pat) { $found.Add($item.Name); break }
            }
        }
    }
    foreach ($n in $prof.extraNeverOpen) { if ($found -notcontains [string]$n) { $never.Add([string]$n) } }
    foreach ($f in $found) { $never.Add($f + '   (found in this project)') }
    $neverText = (($never | Select-Object -Unique | ForEach-Object { '- ' + $_ }) -join "`r`n")

    # Existing instruction files = sources of truth
    $sources = New-Object System.Collections.Generic.List[string]
    foreach ($s in @('AGENTS.md', 'GEMINI.md', 'CLAUDE.md', 'README.md', 'rules.md', 'progress.md')) {
        if (Test-Path -LiteralPath (Join-Path $proj $s)) { $sources.Add($s) }
    }
    if (Test-Path -LiteralPath (Join-Path $proj 'docs')) { $sources.Add('docs/') }
    $srcText = 'none found yet'
    if ($sources.Count -gt 0) { $srcText = ($sources -join ', ') }

    $indexPath = Join-Path $pm 'memory/INDEX.md'
    if (-not (Test-Path -LiteralPath $indexPath)) {
        $text = Fill (Get-Template 'project-index.md') @{
            PROJECT = $name; PROFILE_DESC = $prof.description; SOURCES = $srcText; NEVER_OPEN = $neverText }
        Write-Text $indexPath $text
        Ok 'Created memory\INDEX.md with a never-open list'
    }
    else { Say '  memory\INDEX.md already exists, left as it is.' }

    if ($found.Count -gt 0) {
        Warn 'Sensitive-looking files found in the project root (added to the never-open list):'
        foreach ($f in $found) { Say ('       ' + $f) 'Yellow' }
        Say '       Make sure they are git-ignored.' 'Yellow'
    }

    $pc = @{ profile = $profName; themes = @($prof.themes); monthsBack = $cfg.backfill.monthsBack; maxItemsPerNote = $cfg.backfill.maxItemsPerNote }
    $pcPath = Join-Path $pm 'config.json'
    if (-not (Test-Path -LiteralPath $pcPath)) { Write-Text $pcPath ((ConvertTo-Json $pc -Depth 4) + "`r`n") }

    # .gitignore lines
    $gi = Join-Path $proj '.gitignore'
    $giText = ''
    if (Test-Path -LiteralPath $gi) { $giText = Read-Text $gi }
    $lines = @('.agent-memory/inbox/', '.agent-memory/proposals/', '.agent-memory/archive/')
    $missing = @($lines | Where-Object { $giText -notmatch ('(?m)^' + [regex]::Escape($_) + '\s*$') })
    if ($missing.Count -gt 0) {
        $add = "`r`n# agent memory scratch (raw notes and proposals are not committed)`r`n" + ($missing -join "`r`n") + "`r`n"
        Write-Text $gi ($giText.TrimEnd() + "`r`n" + $add)
        Ok 'Added scratch folders to .gitignore'
    }

    # Optional pointer in project instruction files
    $ptr = Fill (Get-Template 'project-pointer.md') @{ GLOBAL_FILE = (Join-Path $mem 'AGENTS.global.md') }
    foreach ($rel in $cfg.projectPointerFiles) {
        $pf = Join-Path $proj $rel
        Set-Block $pf $ptr $cfg.projectPointerPosition
        Ok ('Added a project pointer to ' + $rel)
    }

    Head 'Done. What to do next'
    Say '  Option A (existing project with history): run "Backfill" in one agent, then "Dream" in a DIFFERENT agent.' 'White'
    Say '  Option B (new project): just work. Agents write notes to .agent-memory\inbox\ as they learn things.' 'White'
}

function Invoke-Backfill {
    $cfg = Get-Config
    $mem = Get-MemoryHome $cfg
    $proj = Resolve-Project
    $pcPath = Join-Path $proj '.agent-memory/config.json'
    if (-not (Test-Path -LiteralPath $pcPath)) { Warn 'Run "Set up a project" first.'; return }
    $pc = Read-Text $pcPath | ConvertFrom-Json
    $tool = Select-Tool $cfg 'Which agent should MINE this project?' ''
    $text = Fill (Get-Template 'backfill-prompt.md') @{
        TOOL_NAME = $tool; PROJECT = $proj; MONTHS = $pc.monthsBack
        MAX_ITEMS = $pc.maxItemsPerNote; THEMES = (@($pc.themes) -join ', ') }
    Send-Prompt $text 'backfill' $tool $proj $cfg
    Say ''
    Say 'When it finishes, run "Status" to see the notes, then "Dream" using a DIFFERENT agent.' 'White'
}

function Invoke-Dream {
    $cfg = Get-Config
    $proj = Resolve-Project
    if (-not (Test-Path -LiteralPath (Join-Path $proj '.agent-memory'))) { Warn 'Run "Set up a project" first.'; return }
    $notes = @(Get-Notes $proj | Where-Object { $_.Status -eq 'unprocessed' })
    if ($notes.Count -eq 0) { Warn 'No unprocessed notes in the inbox. Nothing to dream about yet.'; return }
    $writers = @($notes | Group-Object Tool | Sort-Object Count -Descending)
    $top = $writers[0].Name
    $suggest = ''
    foreach ($a in (Get-EnabledAgents $cfg)) { if ($a.name -ne $top) { $suggest = $a.name; break } }
    Say ('Unprocessed notes: ' + $notes.Count + '  (written by: ' + (($writers | ForEach-Object { $_.Name + ' x' + $_.Count }) -join ', ') + ')')
    if ($writers.Count -eq 1) { Say ('A different agent than "' + $top + '" should review them, so it does not grade its own work.') 'Yellow' }
    $tool = Select-Tool $cfg 'Which agent should DREAM (review and consolidate)?' $suggest
    if ($writers.Count -eq 1 -and $tool -eq $top) { Warn ('"' + $tool + '" wrote all of these notes. It will skip them all. Pick a different agent.'); return }

    $extra = New-Object System.Collections.Generic.List[string]
    if ($cfg.dream.staticOnly) {
        $extra.Add('Do NOT run any tests, builds, npm scripts, or application code. Judge each lesson by reading the cited source with bounded reads, and report found / not found only. Static evidence alone stays "verified (source)", never behavior-verified.')
    }
    foreach ($r in $cfg.dream.extraRules) { $extra.Add([string]$r) }
    $extraText = ''
    if ($extra.Count -gt 0) {
        $numbered = @()
        for ($i = 0; $i -lt $extra.Count; $i++) { $numbered += ([string](5 + $i) + '. ' + $extra[$i]) }
        $extraText = "`r`n" + ($numbered -join "`r`n") + "`r`n"
    }
    $text = Fill (Get-Template 'dream-prompt.md') @{
        TOOL_NAME = $tool; PROJECT = $proj; MAX_INDEX_LINES = $cfg.dream.maxIndexLines; EXTRA_RULES = $extraText }
    Send-Prompt $text 'dream' $tool $proj $cfg
    Say ''
    Say 'When it finishes and says it stopped, run "Review and merge".' 'White'
}

function Invoke-Review {
    $cfg = Get-Config
    $proj = Resolve-Project
    $pm = Join-Path $proj '.agent-memory'
    $propRoot = Join-Path $pm 'proposals'
    if (-not (Test-Path -LiteralPath $propRoot)) { Warn 'No proposals folder yet. Run a dream pass first.'; return }
    $latest = Get-ChildItem -LiteralPath $propRoot -Directory | Sort-Object Name | Select-Object -Last 1
    if (-not $latest) { Warn 'No proposal found. Run a dream pass first.'; return }
    $next = Join-Path $latest.FullName 'memory-next'
    $report = Join-Path $latest.FullName 'report.md'
    if (-not (Test-Path -LiteralPath $next) -or -not (Test-Path -LiteralPath $report)) {
        Warn ('Proposal ' + $latest.Name + ' is incomplete (needs memory-next\ and report.md). The agent may not have finished.')
        return
    }
    Head ('Reviewing proposal ' + $latest.Name)

    # 1. Leak scan, paths only
    $hits = @()
    foreach ($f in (Get-ChildItem -LiteralPath $latest.FullName -Recurse -File)) {
        $m = Select-String -LiteralPath $f.FullName -Pattern @($cfg.leakPatterns) -List -ErrorAction SilentlyContinue
        if ($m) { $hits += $f.FullName }
    }
    if ($hits.Count -gt 0) {
        Warn 'Possible secrets or email addresses found in these files. Merge blocked:'
        foreach ($h in $hits) { Say ('       ' + $h) 'Yellow' }
        Say '       Open them yourself, remove the data, then run Review again.' 'Yellow'
        return
    }
    Ok 'Leak scan clean (emails, keys, private-key headers)'

    # 2. What would change
    $mdir = Join-Path $pm 'memory'
    $changes = @()
    foreach ($f in (Get-ChildItem -LiteralPath $next -Filter '*.md' -File)) {
        $cur = Join-Path $mdir $f.Name
        if (-not (Test-Path -LiteralPath $cur)) { $changes += ('NEW      ' + $f.Name) }
        elseif ((Get-FileHash -LiteralPath $cur).Hash -ne (Get-FileHash -LiteralPath $f.FullName).Hash) { $changes += ('CHANGED  ' + $f.Name) }
    }
    if ($changes.Count -eq 0) { Say '  No memory files would change (the proposal is a no-op).' }
    else { foreach ($c in $changes) { Say ('  ' + $c) 'White' } }

    $idxNext = Join-Path $next 'INDEX.md'
    if (Test-Path -LiteralPath $idxNext) {
        $cnt = @(Get-Content -LiteralPath $idxNext).Count
        if ($cnt -gt $cfg.dream.maxIndexLines) { Warn ('INDEX.md would have ' + $cnt + ' lines (limit ' + $cfg.dream.maxIndexLines + '). It is loaded every session; trim it.') }
    }

    Head 'Read these yourself before merging'
    Say ('  Report:   ' + $report)
    Say ('  Proposal: ' + $next)
    Say '  Check the disagreements in the report, and that each lesson is true and narrowly worded.'

    if (-not $Yes) {
        $a = Read-Host "Type 'yes' to merge into memory and archive the processed notes (anything else cancels)"
        if ($a -ne 'yes') { Say 'Cancelled. Nothing was changed.'; return }
    }

    foreach ($f in (Get-ChildItem -LiteralPath $next -Filter '*.md' -File)) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $mdir $f.Name) -Force
    }
    Ok 'Merged into memory\'
    $reportText = Read-Text $report
    $moved = 0
    foreach ($n in (Get-Notes $proj)) {
        if ($reportText.Contains($n.Name)) {
            $arch = Join-Path $pm 'archive'
            Move-Item -LiteralPath $n.Path -Destination (Join-Path $arch $n.Name) -Force
            $moved++
        }
    }
    Ok ('Archived ' + $moved + ' processed note(s)')
    $left = @(Get-Notes $proj).Count
    if ($left -gt 0) { Say ('  ' + $left + ' note(s) still in the inbox (not named in the report).') }
    Say ''
    Say 'To track the memory in git (do not use "git add ."):' 'White'
    Say '  git add .agent-memory ; git commit -m "Update agent memory" -- .agent-memory' 'White'
}

function Invoke-Status([bool]$WithProject = $true) {
    $cfg = Get-Config
    $mem = Get-MemoryHome $cfg
    Head 'Shared memory'
    if (Test-Path -LiteralPath (Join-Path $mem 'AGENTS.global.md')) { Ok ('Installed at ' + $mem) } else { Warn ('Not installed (' + $mem + ')') }
    Head 'Agents'
    foreach ($a in $cfg.agents) {
        foreach ($g in $a.globalFiles) {
            $path = Expand-Path $g.path
            $state = 'disabled'
            if ($a.enabled) {
                if (Has-Block $path) { $state = 'connected' }
                elseif (-not (Test-Path -LiteralPath $path) -and -not $g.createIfMissing) { $state = 'n/a (no file)' }
                else { $state = 'NOT connected' }
            }
            Say ('  ' + $a.name.PadRight(16) + $state.PadRight(15) + $path)
        }
    }
    if (-not $WithProject) { return }
    $proj = $null
    try { $proj = Resolve-Project } catch { return }
    $pm = Join-Path $proj '.agent-memory'
    Head ('Project: ' + (Split-Path -Leaf $proj))
    if (-not (Test-Path -LiteralPath $pm)) { Warn 'Not set up yet.'; return }
    $notes = @(Get-Notes $proj)
    Say ('  Inbox notes: ' + $notes.Count)
    foreach ($g in ($notes | Group-Object Tool, Status)) { Say ('    ' + $g.Name + ' x' + $g.Count) }
    $topics = @(Get-ChildItem -LiteralPath (Join-Path $pm 'memory') -Filter '*.md' -File -ErrorAction SilentlyContinue)
    Say ('  Memory files: ' + $topics.Count)
    $idx = Join-Path $pm 'memory/INDEX.md'
    if (Test-Path -LiteralPath $idx) { Say ('  INDEX.md lines: ' + @(Get-Content -LiteralPath $idx).Count + ' (limit ' + $cfg.dream.maxIndexLines + ')') }
    $props = @(Get-ChildItem -LiteralPath (Join-Path $pm 'proposals') -Directory -ErrorAction SilentlyContinue)
    Say ('  Proposals waiting or done: ' + $props.Count)
    $unp = @($notes | Where-Object { $_.Status -eq 'unprocessed' }).Count
    if ($unp -ge 5) { Say ('  -> ' + $unp + ' unprocessed notes: a good time for a Dream pass.') 'Green' }
    elseif ($unp -eq 0) { Say '  -> Nothing waiting. Just keep working; notes accumulate on their own.' }
    else { Say ('  -> ' + $unp + ' unprocessed note(s). Around 5 is a good time to dream.') }
}

function Invoke-Uninstall {
    $cfg = Get-Config
    Head 'Disconnecting agents (your shared memory folder and notes are NOT deleted)'
    foreach ($a in $cfg.agents) {
        foreach ($g in $a.globalFiles) {
            $path = Expand-Path $g.path
            if (Remove-Block $path) { Ok ('Removed block from ' + $path) }
        }
    }
    foreach ($rel in $cfg.projectPointerFiles) { Say ('  Project pointer files (' + $rel + ') must be cleaned per project: delete the agent-memory block by hand.') }
    Say ''
    Say ('Backups of files this kit edited end in ".agent-memory.bak". The memory itself stays at ' + (Get-MemoryHome $cfg)) 'White'
}

# ---------------------------------------------------------------- menu

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host '  AGENT MEMORY KIT' -ForegroundColor Cyan
        Write-Host '  1) Install  (once: connect your agents to the shared memory)'
        Write-Host '  2) Set up a project'
        Write-Host '  3) Backfill (one agent mines the project history into notes)'
        Write-Host '  4) Dream    (a DIFFERENT agent reviews the notes)'
        Write-Host '  5) Review and merge'
        Write-Host '  6) Status'
        Write-Host '  7) Uninstall'
        Write-Host '  0) Exit'
        $c = Read-Host 'Choose'
        try {
            switch ($c) {
                '1' { Invoke-Install }
                '2' { Invoke-Init }
                '3' { Invoke-Backfill }
                '4' { Invoke-Dream }
                '5' { Invoke-Review }
                '6' {
                    $more = Read-Host 'Also check one project? (y/n)'
                    Invoke-Status ($more -eq 'y')
                }
                '7' { Invoke-Uninstall }
                '0' { return }
                default { Write-Host 'Pick a number from the list.' }
            }
        }
        catch { Write-Host ('  Error: ' + $_.Exception.Message) -ForegroundColor Red }
        # Ask for a fresh folder next time unless one was given on the command line
        if (-not $script:ProjectFromArgs) { $script:Project = $null }
    }
}

try {
    switch ($Action) {
        'menu' { Show-Menu }
        'install' { Invoke-Install }
        'init' { Invoke-Init }
        'backfill' { Invoke-Backfill }
        'dream' { Invoke-Dream }
        'review' { Invoke-Review }
        'status' { Invoke-Status $script:ProjectFromArgs }
        'uninstall' { Invoke-Uninstall }
    }
}
catch {
    Write-Host ('Error: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
