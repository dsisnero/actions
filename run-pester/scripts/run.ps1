# Run a Pester suite contained within the workspace.
#
# Inputs are typed rather than a free-form argv list. run-bats can splat a newline-delimited array
# at a command safely; Invoke-Pester takes a configuration object, so the equivalent here would be
# turning caller strings into cmdlet parameters -- an injection surface with no upside.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'lib.ps1')

$DefaultTestPath = 'tests'

function Import-RequiredPester {
  <#
  .SYNOPSIS
    Import Pester, optionally from an explicit manifest, and return the imported module.
  #>
  param(
    [AllowEmptyString()]
    [AllowNull()]
    [string]$ModulePath
  )

  if (-not [string]::IsNullOrWhiteSpace($ModulePath)) {
    if (-not (Test-Path -LiteralPath $ModulePath)) {
      throw "Pester module path does not exist: ${ModulePath}."
    }
    # Absolute, always: Import-Module treats a relative path that does not begin with "./" as a
    # module NAME, so a workflow-relative input such as ".fixtures/Pester.psd1" would be searched
    # for on PSModulePath and reported as missing. ~keep
    Import-Module -Name (Resolve-Path -LiteralPath $ModulePath).ProviderPath -Force
  } else {
    Import-Module -Name 'Pester' -Force -ErrorAction SilentlyContinue
  }

  $module = Get-Module -Name 'Pester'
  if ($null -eq $module) {
    throw 'Pester is not available. Run install-pester before run-pester.'
  }

  return $module
}

function Assert-PesterVersion {
  <#
  .SYNOPSIS
    Fail unless the imported Pester is exactly the version the caller asked for.

  .DESCRIPTION
    Without this, a runner image that ships its own Pester quietly runs the suite whenever the
    install step is missing, misordered, or installed somewhere PSModulePath does not reach.
  #>
  param(
    [Parameter(Mandatory)]
    [System.Management.Automation.PSModuleInfo]$Module,

    [AllowEmptyString()]
    [AllowNull()]
    [string]$RequiredVersion
  )

  if ([string]::IsNullOrWhiteSpace($RequiredVersion)) {
    return
  }

  $baseVersion = ($RequiredVersion -split '-', 2)[0]
  $expected = $null
  if (-not [version]::TryParse($baseVersion, [ref]$expected)) {
    throw "version must be a version number such as '6.2.0'; got '${RequiredVersion}'."
  }
  if ($Module.Version -ne $expected) {
    throw "Imported Pester is $($Module.Version), not the required ${expected}. Check that install-pester ran first."
  }
}

function Resolve-ContainedDirectory {
  <#
  .SYNOPSIS
    Resolve a directory input against a base and fail unless it stays inside Parent.
  #>
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Candidate,

    [Parameter(Mandatory)]
    [string]$Parent,

    [Parameter(Mandatory)]
    [string]$Description
  )

  if (-not (Test-Path -LiteralPath $Candidate -PathType Container)) {
    throw "${Description} does not exist: ${Candidate}."
  }

  $resolved = Resolve-PhysicalDirectory -Path $Candidate
  if (-not (Test-PathIsWithin -Path $resolved -Parent $Parent)) {
    throw "${Description} must be inside GITHUB_WORKSPACE."
  }

  return $resolved
}

function Join-InputPath {
  <#
  .SYNOPSIS
    Treat a rooted input as absolute and anything else as relative to Base, as run.sh does.
  #>
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Base,

    [Parameter(Mandatory)]
    [string]$Path
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  return (Join-Path $Base $Path)
}

try {
  $module = Import-RequiredPester -ModulePath $env:INPUT_MODULE_PATH
  Assert-PesterVersion -Module $module -RequiredVersion $env:INPUT_VERSION

  $workspaceInput = if ([string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) {
    (Get-Location).Path
  } else {
    $env:GITHUB_WORKSPACE
  }
  if (-not (Test-Path -LiteralPath $workspaceInput -PathType Container)) {
    throw "GitHub workspace does not exist: ${workspaceInput}."
  }
  $workspace = Resolve-PhysicalDirectory -Path $workspaceInput

  $workingDirectoryCandidate = if ([string]::IsNullOrWhiteSpace($env:INPUT_WORKING_DIRECTORY)) {
    (Get-Location).Path
  } else {
    Join-InputPath -Base (Get-Location).Path -Path $env:INPUT_WORKING_DIRECTORY
  }
  $workingDirectory = Resolve-ContainedDirectory -Candidate $workingDirectoryCandidate -Parent $workspace `
    -Description 'Working directory'

  $testPathInput = if ([string]::IsNullOrWhiteSpace($env:INPUT_PATH)) { $DefaultTestPath } else { $env:INPUT_PATH }
  $testPathCandidate = Join-InputPath -Base $workingDirectory -Path $testPathInput
  if (-not (Test-Path -LiteralPath $testPathCandidate)) {
    throw "Pester test path does not exist: ${testPathInput}."
  }
  if (Test-PathIsSymbolicLink -Path $testPathCandidate) {
    throw 'Pester test path must not be a symbolic link.'
  }
  $testPath = Resolve-PhysicalPath -Path $testPathCandidate
  if (-not (Test-PathIsWithin -Path $testPath -Parent $workspace)) {
    throw 'Pester test path must be inside GITHUB_WORKSPACE.'
  }
  if (-not (Test-PathIsWithin -Path $testPath -Parent $workingDirectory)) {
    throw 'Pester test path must be inside the working directory.'
  }

  $resultPath = $null
  if (-not [string]::IsNullOrWhiteSpace($env:INPUT_RESULT_PATH)) {
    # $workingDirectory is already physically resolved, so joining onto it and collapsing the
    # result is enough; the file itself does not exist yet and so cannot be a symlink.
    $resultCandidate = Join-InputPath -Base $workingDirectory -Path $env:INPUT_RESULT_PATH
    $resultPath = [System.IO.Path]::GetFullPath($resultCandidate)
    if (-not (Test-PathIsWithin -Path $resultPath -Parent $workspace)) {
      throw 'Pester result path must be inside GITHUB_WORKSPACE.'
    }

    $resultParent = [System.IO.Path]::GetDirectoryName($resultPath)
    if (-not (Test-Path -LiteralPath $resultParent -PathType Container)) {
      New-Item -ItemType Directory -Path $resultParent -Force | Out-Null
    }
  }

  $verbosity = Get-ValidatedVerbosity -Value $env:INPUT_OUTPUT_VERBOSITY
  # @() because PowerShell unrolls an empty array returned from a function into $null, and
  # $null.Count is a terminating error under Set-StrictMode. ~keep
  $tags = @(ConvertTo-FilterList -Name 'filter-tag' -Value ([string]$env:INPUT_FILTER_TAG))
  $fullNames = @(ConvertTo-FilterList -Name 'filter-full-name' -Value ([string]$env:INPUT_FILTER_FULL_NAME))

  $configuration = New-PesterConfiguration
  $configuration.Run.Path = @($testPath)
  $configuration.Run.Exit = $true
  $configuration.Output.CIFormat = 'GithubActions'
  $configuration.Output.Verbosity = $verbosity
  $configuration.Should.ErrorAction = 'Stop'
  if ($tags.Count -gt 0) {
    $configuration.Filter.Tag = $tags
  }
  if ($fullNames.Count -gt 0) {
    $configuration.Filter.FullName = $fullNames
  }
  if ($null -ne $resultPath) {
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = $resultPath
  }

  Invoke-Pester -Configuration $configuration
} catch {
  Write-Host "::error::$($_.Exception.Message)"
  exit 1
}
