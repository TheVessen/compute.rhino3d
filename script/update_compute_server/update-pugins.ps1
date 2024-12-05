
# Define the repositories with additional details
$repos = @{
    "VektorNodeGhLib"      = @{
        "url"         = "https://github.com/TheVessen/VektorNodeGhLib.git"
        "branch"      = "main" # or "master" or any other branch name
        "projectFile" = "VektorNodeGhLib.sln" # specify the project file
        "buildOutput" = "Build\net48\" # specify the build output path
        "destination" = "C:\Users\RhinoComputeUser\AppData\Roaming\Grasshopper\Libraries\" # specify the destination folder
        "buildType"   = "solution" 
    }
}

# Define the base directory where the repositories are stored
$baseDir = "C:\temp\repos"

# Loop through the repositories
foreach ($repoName in $repos.Keys) {
    $repo = $repos[$repoName]
    Write-Host "Updating $repoName..."
    $repoDir = Join-Path $baseDir $repoName
    
    # Initialize a variable to track if the repository existed
    $repoExisted = $true

    # Clone if the directory doesn't exist, else fetch the latest changes
    if (-Not (Test-Path $repoDir)) {
        $repoExisted = $false
        git clone $repo.url $repoDir
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to clone $repoName" -ForegroundColor Red
            continue
        }
        Start-Sleep -Seconds 5  # Wait for 5 seconds
    }
    
    Set-Location $repoDir
    git fetch
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to fetch updates for $repoName" -ForegroundColor Red
        continue
    }

    # Check if there are any changes
    $changes = git diff --name-only origin/$($repo.branch)

    git reset --hard origin/$($repo.branch)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to reset $repoName to branch $repo.branch" -ForegroundColor Red
        continue
    }
    
    $status = git status
    Write-Host "Status: $status"
    Write-Host "Was downloaded: $repoExisted"

    if ($changes -or -Not $repoExisted) {

        git pull origin $repo.branch 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to pull updates for $repoName from branch $repo.branch" -ForegroundColor Red
            continue
        }

        Set-Location -LiteralPath $PSScriptRoot

        Write-Host "Building $repoName..."

        Set-Location $repoDir
        dotnet build $repo.projectFile --configuration Release

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Build of $repoName was successful" -ForegroundColor Green

            Write-Host "Copying build artifacts for $repoName..."
            $buildOutput = $repo.buildOutput

            $destination = $repo.destination
            $source = Join-Path $repoDir $buildOutput

            # Create the destination directory if it doesn't exist
            if (-Not (Test-Path $destination)) {
                New-Item -ItemType Directory -Force -Path $destination
            }

            # Print the value of $source and check if the path exists
            Write-Host "Source: $source"

            if (Test-Path $source) {
                # Delete the existing contents of the destination directory
                # Get-ChildItem -Path $destination -Recurse | Remove-Item -Force -Recurse

                # Copy the contents of the source directory to the destination directory
                Copy-Item -Path $source\* -Destination $destination -Recurse -Force

                Write-Host "Finished processing $repoName." -ForegroundColor Green
            }
            else {
                Write-Host "Build output for $repoName not found" -ForegroundColor Red
            }
        }
        Write-Host "Update and build process complete." -ForegroundColor Magenta
    }
    else {
        Write-Host "$repo is uptodate" -ForegroundColor Yellow
    }
}
    
Write-Host "Done" -ForegroundColor Magenta
