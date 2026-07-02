$inputJson = $input | Out-String | ConvertFrom-Json
$cwd = $inputJson.workspace.current_dir
$model = $inputJson.model.display_name

$branch = git -C $cwd branch --show-current 2>$null
$dir = Split-Path $cwd -Leaf

if ($branch) {
    Write-Host "$dir [$model] $branch"
} else {
    Write-Host "$dir [$model]"
}
