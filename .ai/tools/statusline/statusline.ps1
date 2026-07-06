$inputJson = $input | Out-String | ConvertFrom-Json
$cwd = $inputJson.workspace.current_dir
$model = $inputJson.model.display_name

$branch = git -C $cwd branch --show-current 2>$null
$gitRoot = git -C $cwd rev-parse --show-toplevel 2>$null

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
