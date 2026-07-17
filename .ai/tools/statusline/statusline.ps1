# 读取 stdin
try { $raw = $input | Out-String } catch { $raw = "" }

# cwd：优先文件系统（切换 worktree 时最准）
$cwd = if ($pwd) { $pwd.Path } else { (Get-Location).Path }

# Model：正则提取（不依赖完整 JSON 解析，中文乱码也不影响）
$model = $null
if ($raw -match '"display_name"\s*:\s*"([^"]+)"') { $model = $matches[1] }
if (-not $model -and $raw -match '"id"\s*:\s*"([^"]+)"') { $model = $matches[1] }
if (-not $model) { $model = "?" }

$branch  = try { git -C $cwd branch --show-current 2>$null } catch { $null }
$gitRoot = try { git -C $cwd rev-parse --show-toplevel 2>$null } catch { $null }

if ($gitRoot) {
    $rootName = Split-Path $gitRoot -Leaf
    if ($cwd -ne $gitRoot) {
        $rel = $cwd.Substring($gitRoot.Length).TrimStart('\', '/')
        $displayDir = "$rootName/$rel"
    } else {
        $displayDir = $rootName
    }
} else {
    $displayDir = Split-Path $cwd -Leaf
}

$e = [char]27
$path   = "${e}[38;5;255m${displayDir}${e}[0m"
$sep    = "${e}[38;5;243m · ${e}[0m"
$model  = "${e}[38;5;249m${model}${e}[0m"

if ($branch) {
    if ($branch -eq 'master' -or $branch -eq 'production' -or $branch -eq 'main') {
        $branchColor = "${e}[38;5;203m${branch}${e}[0m"
    } else {
        $branchColor = "${e}[38;5;120m${branch}${e}[0m"
    }
    Write-Host "${path}${sep}${model}${sep}${branchColor}"
} else {
    Write-Host "${path}${sep}${model}"
}
