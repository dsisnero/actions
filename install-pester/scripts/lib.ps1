# Pure helpers for install.ps1.
#
# Everything here is side-effect free apart from writing files under a caller-supplied destination,
# so every security control below can be exercised by install-pester/tests/install.Tests.ps1 without
# a network round trip. install.ps1 holds the orchestration and nothing else.

Set-StrictMode -Version Latest

function Test-PesterVersionString {
  <#
  .SYNOPSIS
    Return whether a requested Pester version is a version this action is willing to install.
  #>
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Version
  )

  # Mirrors normalize_version() in install-bats/scripts/install.sh, minus its "latest" branch.
  # A floating version cannot appear in checksums.tsv, so accepting one would mean running
  # unverified bytes -- exactly the gap this action exists to close.
  #
  # \A and \z rather than ^ and $: in .NET, `$` also matches immediately before a trailing
  # newline, so "6.2.0`n" would satisfy an anchored ^...$ pattern and then flow into
  # $GITHUB_OUTPUT as two lines. ~keep
  $versionPattern = '\A\d+\.\d+(\.\d+)?(-[0-9A-Za-z][0-9A-Za-z.-]*)?\z'

  return $Version -match $versionPattern
}

function Get-PinnedChecksum {
  <#
  .SYNOPSIS
    Look a version up in the pinned checksum table, throwing when it is absent.
  #>
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$ChecksumPath
  )

  $expectedFieldCount = 2
  $sha256HexPattern = '\A[0-9a-f]{64}\z'

  if (-not (Test-Path -LiteralPath $ChecksumPath -PathType Leaf)) {
    throw "Checksum table is missing: ${ChecksumPath}."
  }

  foreach ($line in [System.IO.File]::ReadAllLines($ChecksumPath)) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#', [System.StringComparison]::Ordinal)) {
      continue
    }

    $fields = $trimmed -split "`t"
    if ($fields.Count -ne $expectedFieldCount) {
      throw "Malformed entry in ${ChecksumPath}: expected '<version><TAB><sha256>', got '${trimmed}'."
    }
    if ($fields[0] -ne $Version) {
      continue
    }
    if ($fields[1] -notmatch $sha256HexPattern) {
      throw "Checksum table holds an invalid SHA256 for Pester ${Version}: '$($fields[1])'."
    }

    return $fields[1]
  }

  throw "Pester ${Version} is not pinned in ${ChecksumPath}. Add its verified SHA256 before installing it."
}

function Assert-PackageChecksum {
  <#
  .SYNOPSIS
    Fail unless a downloaded file hashes to the pinned SHA256.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [string]$ExpectedSha256
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Downloaded package is missing: ${Path}."
  }

  $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  $expected = $ExpectedSha256.ToLowerInvariant()
  if ($actual -ne $expected) {
    throw "SHA256 mismatch for ${Path}: expected ${expected}, got ${actual}."
  }
}

function Test-PackagingMetadataEntry {
  <#
  .SYNOPSIS
    Return whether a nupkg entry is OPC packaging metadata rather than module content.
  #>
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$EntryName
  )

  if ($EntryName -eq '[Content_Types].xml') {
    return $true
  }
  if ($EntryName.StartsWith('_rels/', [System.StringComparison]::Ordinal)) {
    return $true
  }
  if ($EntryName.StartsWith('package/', [System.StringComparison]::Ordinal)) {
    return $true
  }

  return $EntryName.EndsWith('.nuspec', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-PathComparison {
  <#
  .SYNOPSIS
    Return the string comparison that matches the filesystem's own path casing rules.
  #>
  [OutputType([System.StringComparison])]
  param()

  if ($IsWindows) {
    return [System.StringComparison]::OrdinalIgnoreCase
  }

  return [System.StringComparison]::Ordinal
}

function Assert-ArchiveIsSafe {
  <#
  .SYNOPSIS
    Fail unless every entry in an open nupkg extracts inside Destination, and return the plan.

  .DESCRIPTION
    Reimplements validate_archive() from install-bats/scripts/install.sh for the zip container.
    The returned plan is what Expand-VerifiedPackage extracts, so validation and extraction can
    never disagree about which entries exist or where they land.
  #>
  [OutputType([System.Collections.Generic.List[object]])]
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchive]$Archive,

    [Parameter(Mandatory)]
    [string]$Destination
  )

  $separator = [System.IO.Path]::DirectorySeparatorChar
  $destinationRoot = [System.IO.Path]::GetFullPath($Destination)
  $destinationPrefix = $destinationRoot.TrimEnd($separator) + $separator
  $comparison = Get-PathComparison

  $plan = [System.Collections.Generic.List[object]]::new()
  $manifestFound = $false

  foreach ($entry in $Archive.Entries) {
    $name = $entry.FullName

    if ([string]::IsNullOrWhiteSpace($name)) {
      throw 'Downloaded Pester package contains an entry with an empty path.'
    }
    # A backslash is a legal literal in a zip entry name but a separator on Windows, so an entry
    # named `a\..\..\evil` would pass a '/'-segment check and still escape. ~keep
    if ($name.Contains('\')) {
      throw "Downloaded Pester package contains a backslash in an entry path: '${name}'."
    }
    if ($name.StartsWith('/', [System.StringComparison]::Ordinal) -or [System.IO.Path]::IsPathRooted($name)) {
      throw "Downloaded Pester package contains a rooted entry path: '${name}'."
    }
    if ($name.Split('/') -contains '..') {
      throw "Downloaded Pester package contains a parent-directory entry path: '${name}'."
    }

    if ($name.EndsWith('/', [System.StringComparison]::Ordinal)) {
      continue
    }
    if (Test-PackagingMetadataEntry -EntryName $name) {
      continue
    }

    $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($destinationRoot, $name))
    if (-not $target.StartsWith($destinationPrefix, $comparison)) {
      throw "Downloaded Pester package entry '${name}' would extract outside ${destinationRoot}."
    }

    if ($name -eq 'Pester.psd1') {
      $manifestFound = $true
    }

    $plan.Add([pscustomobject]@{ Entry = $entry; Destination = $target })
  }

  if (-not $manifestFound) {
    throw 'Downloaded Pester package does not contain Pester.psd1.'
  }

  return $plan
}

function Expand-VerifiedPackage {
  <#
  .SYNOPSIS
    Extract the module content of an already-checksum-verified nupkg into Destination.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$ArchivePath,

    [Parameter(Mandatory)]
    [string]$Destination
  )

  $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    $plan = Assert-ArchiveIsSafe -Archive $archive -Destination $Destination

    foreach ($item in $plan) {
      $parent = [System.IO.Path]::GetDirectoryName($item.Destination)
      if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
      }
      # Not Expand-Archive: it wildcard-interprets -Path, so `[Content_Types].xml` reads as a
      # character class, and it would extract every entry including ones Assert-ArchiveIsSafe
      # deliberately excluded. ~keep
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($item.Entry, $item.Destination, $false)
    }
  } finally {
    $archive.Dispose()
  }
}

function Assert-WorkflowFileValue {
  <#
  .SYNOPSIS
    Fail unless a value is safe to append to $GITHUB_OUTPUT or $GITHUB_ENV.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Value
  )

  # Mirrors the GITHUB_TOKEN newline guard in install-bats/scripts/install.sh: these files are
  # line-oriented, so an embedded newline lets one value declare a second, attacker-chosen one.
  if ($Value.Contains("`n") -or $Value.Contains("`r")) {
    throw "${Name} must not contain carriage returns or newlines."
  }
}
