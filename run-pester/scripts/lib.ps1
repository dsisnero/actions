# Pure helpers for run.ps1.
#
# These are the reimplementation of run-bats/scripts/run.sh's containment contract. They are kept
# side-effect free so run-pester/tests/run.Tests.ps1 can exercise the path logic directly, without
# a Pester-inside-Pester run.

Set-StrictMode -Version Latest

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

function ConvertTo-NormalizedPath {
  <#
  .SYNOPSIS
    Put a path into the one separator spelling and trailing-separator form comparisons can use.

  .DESCRIPTION
    A workspace-relative input may legally arrive with forward slashes on Windows, so the two
    sides of a prefix comparison have to be spelled the same way before they are compared.
  #>
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  $separator = [System.IO.Path]::DirectorySeparatorChar
  $normalized = $Path.Replace([System.IO.Path]::AltDirectorySeparatorChar, $separator)
  if ($normalized.Length -gt 1) {
    $normalized = $normalized.TrimEnd($separator)
  }

  return $normalized
}

function Test-PathIsWithin {
  <#
  .SYNOPSIS
    Return whether Path is Parent itself or lives underneath it.
  #>
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [string]$Parent
  )

  $normalizedPath = ConvertTo-NormalizedPath -Path $Path
  $normalizedParent = ConvertTo-NormalizedPath -Path $Parent
  $comparison = Get-PathComparison

  if ($normalizedPath.Equals($normalizedParent, $comparison)) {
    return $true
  }

  # The separator is part of the prefix on purpose: without it "/ws-evil" reads as inside "/ws".
  return $normalizedPath.StartsWith($normalizedParent + [System.IO.Path]::DirectorySeparatorChar, $comparison)
}

function Resolve-PhysicalDirectory {
  <#
  .SYNOPSIS
    The `cd "$dir" && pwd -P` of run.sh: collapse the path and follow it to its real target.
  #>
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  $full = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetPathRoot($full)
  # [char[]] is load-bearing: an untyped array binds String.Split(char[], int) instead, and
  # RemoveEmptyEntries then arrives as a count of 1, returning the whole path as one segment. ~keep
  $separators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $segments = $full.Substring($root.Length).Split($separators, [System.StringSplitOptions]::RemoveEmptyEntries)

  # Component by component, because ResolveLinkTarget only resolves the LAST one while `pwd -P`
  # resolves every one. On macOS /var is itself a link to /private/var, so resolving only the leaf
  # leaves a workspace under $TMPDIR spelled differently from the same directory reached through
  # the shell's own working directory -- and the containment check then rejects its own workspace.
  # ResolveLinkTarget with $true follows chains itself and throws on a cycle. ~keep
  $current = $root
  foreach ($segment in $segments) {
    $current = [System.IO.Path]::Combine($current, $segment)
    $resolved = [System.IO.Directory]::ResolveLinkTarget($current, $true)
    if ($null -ne $resolved) {
      $current = $resolved.FullName
    }
  }

  return (Get-Item -Force -LiteralPath $current).FullName
}

function Resolve-PhysicalPath {
  <#
  .SYNOPSIS
    Physically resolve a file or directory, mirroring run.sh's split handling of the two.
  #>
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  if (Test-Path -LiteralPath $Path -PathType Container) {
    return Resolve-PhysicalDirectory -Path $Path
  }

  $full = [System.IO.Path]::GetFullPath($Path)
  $parent = [System.IO.Path]::GetDirectoryName($full)
  if ([string]::IsNullOrEmpty($parent)) {
    return $full
  }

  return (Join-Path (Resolve-PhysicalDirectory -Path $parent) ([System.IO.Path]::GetFileName($full)))
}

function Test-PathIsSymbolicLink {
  <#
  .SYNOPSIS
    Return whether a path is itself a symbolic link or reparse point.
  #>
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  $item = Get-Item -Force -LiteralPath $Path

  return -not [string]::IsNullOrEmpty($item.LinkType)
}

function ConvertTo-FilterList {
  <#
  .SYNOPSIS
    Split a newline-delimited action input into values, rejecting empty lines.

  .DESCRIPTION
    Mirrors the args loop in run.sh. An empty line is rejected rather than dropped: an empty tag
    or full-name filter silently changes which tests run, and a caller who typed a blank line
    meant something else.
  #>
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Value
  )

  if ([string]::IsNullOrEmpty($Value)) {
    return @()
  }

  $lines = [string[]]($Value -split "`r?`n")
  if ($lines[-1] -eq '') {
    # A YAML `|` block scalar keeps one trailing newline; that one is punctuation, not a value.
    $lines = $lines[0..($lines.Count - 2)]
  }
  if ($lines.Count -eq 0) {
    return @()
  }

  foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      throw "${Name} must be newline-delimited values without empty lines."
    }
  }

  return $lines
}

function Get-ValidatedVerbosity {
  <#
  .SYNOPSIS
    Return the canonically-cased Pester output verbosity, or throw for anything off the allowlist.
  #>
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Value
  )

  $allowed = @('None', 'Normal', 'Detailed', 'Diagnostic')
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return 'Detailed'
  }

  foreach ($candidate in $allowed) {
    if ($candidate.Equals($Value, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $candidate
    }
  }

  throw "output-verbosity must be one of $($allowed -join ', '); got '${Value}'."
}
