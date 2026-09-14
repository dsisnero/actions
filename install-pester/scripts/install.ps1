# Install a pinned Pester release from the PowerShell Gallery.
#
# PSGallery has no equivalent of the GitHub tarball-URL check install-bats leans on, so the pinned
# SHA256 in checksums.tsv is the only thing standing between this action and whatever the CDN
# serves. Every control below exists to keep that check unskippable.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'lib.ps1')

$DefaultVersion = '6.2.0'
$GalleryPackageBaseUrl = 'https://www.powershellgallery.com/api/v2/package/Pester'
$MaximumRedirects = 5
$MaximumDownloadAttempts = 3
$RequestTimeoutSeconds = 120
$BackoffBase = 2

function Write-ActionError {
  param(
    [Parameter(Mandatory)]
    [string]$Message
  )

  Write-Host "::error::${Message}"
}

function Assert-HttpsUrl {
  param(
    [Parameter(Mandatory)]
    [string]$Url,

    [Parameter(Mandatory)]
    [string]$Description
  )

  if (-not $Url.StartsWith('https://', [System.StringComparison]::Ordinal)) {
    throw "${Description} is not https: '${Url}'."
  }
}

function Invoke-HttpsDownload {
  <#
  .SYNOPSIS
    Download a URL to a file, following redirects manually so every hop can be proven https.

  .DESCRIPTION
    Invoke-WebRequest's own -MaximumRedirection follows a 302 to plain http without complaint,
    which is why curl in install-bats/scripts/install.sh passes --proto-redir '=https'. There is
    no PowerShell equivalent, so the hops are walked one at a time instead.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$Url,

    [Parameter(Mandatory)]
    [string]$OutFile
  )

  $current = $Url
  Assert-HttpsUrl -Url $current -Description 'Pester package URL'

  for ($hop = 0; $hop -le $MaximumRedirects; $hop++) {
    try {
      Invoke-WebRequest -Uri $current -OutFile $OutFile -MaximumRedirection 0 `
        -TimeoutSec $RequestTimeoutSeconds | Out-Null
      return
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
      $response = $_.Exception.Response
      $status = [int]$response.StatusCode
      if ($status -lt 300 -or $status -ge 400) {
        throw
      }

      $location = $response.Headers.Location
      if ($null -eq $location) {
        throw "Pester package URL '${current}' redirected without a Location header."
      }

      $current = $location.OriginalString
      Assert-HttpsUrl -Url $current -Description 'Pester package redirect target'
    }
  }

  throw "Pester package URL '${Url}' exceeded ${MaximumRedirects} redirects."
}

function Save-PesterPackage {
  param(
    [Parameter(Mandatory)]
    [string]$Url,

    [Parameter(Mandatory)]
    [string]$OutFile
  )

  for ($attempt = 1; $attempt -le $MaximumDownloadAttempts; $attempt++) {
    try {
      Invoke-HttpsDownload -Url $Url -OutFile $OutFile
      return
    } catch {
      if ($attempt -eq $MaximumDownloadAttempts) {
        throw "Could not download ${Url} after ${MaximumDownloadAttempts} attempts: $($_.Exception.Message)"
      }
      $wait = [Math]::Pow($BackoffBase, $attempt)
      Write-Host "Download attempt ${attempt} failed; retrying in ${wait}s"
      Start-Sleep -Seconds $wait
    }
  }
}

function New-PrivateStagingDirectory {
  param(
    [Parameter(Mandatory)]
    [string]$Parent
  )

  $path = Join-Path $Parent ".install-pester-$([System.Guid]::NewGuid().ToString('N'))"
  if (Test-Path -LiteralPath $path) {
    throw "Staging directory already exists: ${path}."
  }

  $directory = [System.IO.Directory]::CreateDirectory($path)
  if (-not $IsWindows) {
    # The umask 077 in install-bats/scripts/install.sh: the download lands here before it is
    # verified, so nothing else on the runner should be able to read or swap it. ~keep
    $directory.UnixFileMode = [System.IO.UnixFileMode]::UserRead `
      -bor [System.IO.UnixFileMode]::UserWrite `
      -bor [System.IO.UnixFileMode]::UserExecute
  }

  return $directory.FullName
}

function Write-WorkflowFile {
  param(
    # AllowNull/AllowEmptyString so the unset case reaches the explicit check below with a message
    # naming the variable, instead of surfacing as a parameter-binding error. ~keep
    [AllowNull()]
    [AllowEmptyString()]
    [string]$FilePath,

    [Parameter(Mandatory)]
    [string]$VariableName,

    [Parameter(Mandatory)]
    [hashtable]$Values
  )

  if ([string]::IsNullOrEmpty($FilePath)) {
    throw "${VariableName} is not set; install-pester must run in a GitHub Actions job."
  }

  foreach ($key in $Values.Keys) {
    Assert-WorkflowFileValue -Name $key -Value $Values[$key]
    Add-Content -LiteralPath $FilePath -Value "${key}=$($Values[$key])" -Encoding utf8
  }
}

function Get-InstallRoot {
  param(
    [AllowEmptyString()]
    [AllowNull()]
    [string]$Requested
  )

  if (-not [string]::IsNullOrWhiteSpace($Requested)) {
    return $Requested
  }
  if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    return (Join-Path $env:RUNNER_TEMP 'pester')
  }

  return (Join-Path (Join-Path $HOME '.local') 'pester')
}

$requestedVersion = if ([string]::IsNullOrWhiteSpace($env:INPUT_VERSION)) {
  $DefaultVersion
} else {
  $env:INPUT_VERSION
}

try {
  if (-not (Test-PesterVersionString -Version $requestedVersion)) {
    throw "Invalid Pester version '${requestedVersion}'. Use a pinned version such as '6.2.0'; " +
    "'latest' is not accepted."
  }

  $checksumPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'checksums.tsv'
  $expectedChecksum = Get-PinnedChecksum -Version $requestedVersion -ChecksumPath $checksumPath

  $installRoot = Get-InstallRoot -Requested $env:INPUT_INSTALL_DIR
  # Pester lands at <root>/modules/Pester/<version> so that adding <root>/modules to PSModulePath
  # makes `Import-Module Pester` resolve by name -- the layout Import-Module's own search expects.
  $modulesRoot = Join-Path $installRoot 'modules'
  $versionDirectory = Join-Path (Join-Path $modulesRoot 'Pester') $requestedVersion
  $manifestPath = Join-Path $versionDirectory 'Pester.psd1'

  New-Item -ItemType Directory -Path $modulesRoot -Force | Out-Null

  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    Write-Host "Using existing Pester ${requestedVersion} at ${manifestPath}"
  } else {
    if (Test-Path -LiteralPath $versionDirectory) {
      throw "Installation directory already exists but holds no Pester.psd1: ${versionDirectory}."
    }

    $stagingDirectory = New-PrivateStagingDirectory -Parent $installRoot
    try {
      $packagePath = Join-Path $stagingDirectory "pester.${requestedVersion}.nupkg"
      Save-PesterPackage -Url "${GalleryPackageBaseUrl}/${requestedVersion}" -OutFile $packagePath

      # Before extraction, always: an unverified archive must never touch the filesystem beyond
      # the private staging directory it was downloaded into.
      Assert-PackageChecksum -Path $packagePath -ExpectedSha256 $expectedChecksum

      $extractDirectory = Join-Path $stagingDirectory 'extract'
      New-Item -ItemType Directory -Path $extractDirectory -Force | Out-Null
      Expand-VerifiedPackage -ArchivePath $packagePath -Destination $extractDirectory

      if (-not (Test-Path -LiteralPath (Join-Path $extractDirectory 'Pester.psd1') -PathType Leaf)) {
        throw 'Extracted Pester package did not provide Pester.psd1.'
      }

      New-Item -ItemType Directory -Path (Split-Path -Parent $versionDirectory) -Force | Out-Null
      Move-Item -LiteralPath $extractDirectory -Destination $versionDirectory
    } finally {
      Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Pester manifest is missing at ${manifestPath}."
  }

  Import-Module -Name $manifestPath -Force
  $importedVersion = (Get-Module -Name Pester).Version
  $expectedVersion = [version]($requestedVersion -split '-', 2)[0]
  if ($importedVersion -ne $expectedVersion) {
    throw "Imported Pester reports ${importedVersion}, not the requested ${expectedVersion}."
  }
  Write-Host "Pester ${importedVersion} installed at ${manifestPath}"

  Write-WorkflowFile -FilePath $env:GITHUB_OUTPUT -VariableName 'GITHUB_OUTPUT' -Values @{
    'module-path' = $manifestPath
    'module-root' = $modulesRoot
    'version'     = $requestedVersion
  }

  $pathSeparator = [System.IO.Path]::PathSeparator
  $modulePath = if ([string]::IsNullOrEmpty($env:PSModulePath)) {
    $modulesRoot
  } else {
    "${modulesRoot}${pathSeparator}$($env:PSModulePath)"
  }
  Write-WorkflowFile -FilePath $env:GITHUB_ENV -VariableName 'GITHUB_ENV' -Values @{
    'PSModulePath' = $modulePath
  }
} catch {
  Write-ActionError -Message $_.Exception.Message
  exit 1
}
