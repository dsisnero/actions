#Requires -Modules Pester

# Unit tests for install-pester/scripts/lib.ps1. Every control the action relies on is exercised
# here without touching the network: the archive cases run against fixture zips built in-process,
# and the checksum cases run against both a fixture table and the real committed checksums.tsv.

BeforeAll {
  $script:ActionRoot = Split-Path -Parent $PSScriptRoot
  . (Join-Path $script:ActionRoot 'scripts/lib.ps1')

  $script:CommittedChecksums = Join-Path $script:ActionRoot 'checksums.tsv'
  $script:Pester620Sha256 = 'e6ac7418d4f12500269aaca58ae56cf1caafbbf1afa2cec334e289d1cf50a239'
  $script:Pester571Sha256 = '4a27904c6814a5fbe4758f8e49861f6a1994aee77b71165a5c43c0371ba6c580'

  function New-TestArchive {
    param(
      [Parameter(Mandatory)]
      [string]$Path,

      [Parameter(Mandatory)]
      [AllowEmptyCollection()]
      [string[]]$EntryNames
    )

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
    try {
      $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
      try {
        foreach ($name in $EntryNames) {
          $entry = $archive.CreateEntry($name)
          $writer = [System.IO.StreamWriter]::new($entry.Open())
          try {
            $writer.Write("content of ${name}")
          } finally {
            $writer.Dispose()
          }
        }
      } finally {
        $archive.Dispose()
      }
    } finally {
      $stream.Dispose()
    }
  }

  function Invoke-ArchiveAssertion {
    param(
      [Parameter(Mandatory)]
      [string]$ArchivePath,

      [Parameter(Mandatory)]
      [string]$Destination
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
      return Assert-ArchiveIsSafe -Archive $archive -Destination $Destination
    } finally {
      $archive.Dispose()
    }
  }
}

Describe 'Test-PesterVersionString' {
  It 'should_accept_the_version_when_it_is_a_three_part_release' {
    Test-PesterVersionString -Version '6.2.0' | Should -BeTrue
  }

  It 'should_accept_the_version_when_it_is_a_two_part_release' {
    Test-PesterVersionString -Version '6.2' | Should -BeTrue
  }

  It 'should_accept_the_version_when_it_carries_a_prerelease_suffix' {
    Test-PesterVersionString -Version '6.3.0-beta1' | Should -BeTrue
  }

  It 'should_reject_the_version_when_it_is_latest' {
    Test-PesterVersionString -Version 'latest' | Should -BeFalse
  }

  It 'should_reject_the_version_when_it_has_four_parts' {
    Test-PesterVersionString -Version '1.2.3.4' | Should -BeFalse
  }

  It 'should_reject_the_version_when_it_is_a_traversal_path' {
    Test-PesterVersionString -Version '../../etc' | Should -BeFalse
  }

  It 'should_reject_the_version_when_it_carries_a_shell_separator' {
    Test-PesterVersionString -Version '1.2.3;rm' | Should -BeFalse
  }

  It 'should_reject_the_version_when_it_ends_with_a_newline' {
    Test-PesterVersionString -Version "6.2.0`n" | Should -BeFalse
  }

  It 'should_reject_the_version_when_a_second_line_follows_a_valid_one' {
    Test-PesterVersionString -Version "6.2.0`nlatest" | Should -BeFalse
  }

  It 'should_reject_the_version_when_it_is_empty' {
    Test-PesterVersionString -Version '' | Should -BeFalse
  }
}

Describe 'Get-PinnedChecksum' {
  BeforeAll {
    $script:TablePath = Join-Path $TestDrive 'checksums.tsv'
    $lines = @(
      '# a comment',
      '',
      "6.2.0`t${script:Pester620Sha256}",
      "5.7.1`t${script:Pester571Sha256}"
    )
    Set-Content -LiteralPath $script:TablePath -Value $lines -Encoding utf8
  }

  It 'should_return_the_pinned_digest_when_the_version_is_in_the_table' {
    Get-PinnedChecksum -Version '6.2.0' -ChecksumPath $script:TablePath | Should -BeExactly $script:Pester620Sha256
  }

  It 'should_return_the_pinned_digest_when_the_version_is_the_older_pin' {
    Get-PinnedChecksum -Version '5.7.1' -ChecksumPath $script:TablePath | Should -BeExactly $script:Pester571Sha256
  }

  It 'should_throw_when_the_version_is_absent_from_the_table' {
    { Get-PinnedChecksum -Version '6.9.9' -ChecksumPath $script:TablePath } |
      Should -Throw -ExpectedMessage '*6.9.9 is not pinned*'
  }

  It 'should_throw_when_the_table_file_does_not_exist' {
    { Get-PinnedChecksum -Version '6.2.0' -ChecksumPath (Join-Path $TestDrive 'absent.tsv') } |
      Should -Throw -ExpectedMessage '*Checksum table is missing*'
  }

  It 'should_throw_when_a_row_does_not_have_exactly_two_fields' {
    $path = Join-Path $TestDrive 'malformed.tsv'
    Set-Content -LiteralPath $path -Value "6.2.0 ${script:Pester620Sha256}" -Encoding utf8
    { Get-PinnedChecksum -Version '6.2.0' -ChecksumPath $path } | Should -Throw -ExpectedMessage '*Malformed entry*'
  }

  It 'should_throw_when_a_row_holds_something_other_than_a_sha256' {
    $path = Join-Path $TestDrive 'baddigest.tsv'
    Set-Content -LiteralPath $path -Value "6.2.0`tnot-a-digest" -Encoding utf8
    { Get-PinnedChecksum -Version '6.2.0' -ChecksumPath $path } | Should -Throw -ExpectedMessage '*invalid SHA256*'
  }

  It 'should_return_the_verified_digest_when_reading_the_committed_table' {
    Get-PinnedChecksum -Version '6.2.0' -ChecksumPath $script:CommittedChecksums |
      Should -BeExactly $script:Pester620Sha256
    Get-PinnedChecksum -Version '5.7.1' -ChecksumPath $script:CommittedChecksums |
      Should -BeExactly $script:Pester571Sha256
  }

  It 'should_reject_latest_when_reading_the_committed_table' {
    { Get-PinnedChecksum -Version 'latest' -ChecksumPath $script:CommittedChecksums } |
      Should -Throw -ExpectedMessage '*is not pinned*'
  }
}

Describe 'Assert-PackageChecksum' {
  BeforeAll {
    $script:PackagePath = Join-Path $TestDrive 'package.bin'
    Set-Content -LiteralPath $script:PackagePath -Value 'pester bytes' -NoNewline -Encoding utf8
    $script:PackageSha256 = (Get-FileHash -LiteralPath $script:PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
  }

  It 'should_return_without_error_when_the_digest_matches' {
    { Assert-PackageChecksum -Path $script:PackagePath -ExpectedSha256 $script:PackageSha256 } | Should -Not -Throw
  }

  It 'should_return_without_error_when_the_expected_digest_is_uppercase' {
    { Assert-PackageChecksum -Path $script:PackagePath -ExpectedSha256 $script:PackageSha256.ToUpperInvariant() } |
      Should -Not -Throw
  }

  It 'should_throw_when_the_digest_does_not_match' {
    { Assert-PackageChecksum -Path $script:PackagePath -ExpectedSha256 ('0' * 64) } |
      Should -Throw -ExpectedMessage '*SHA256 mismatch*'
  }

  It 'should_throw_when_the_downloaded_package_is_missing' {
    { Assert-PackageChecksum -Path (Join-Path $TestDrive 'absent.bin') -ExpectedSha256 ('0' * 64) } |
      Should -Throw -ExpectedMessage '*Downloaded package is missing*'
  }
}

Describe 'Assert-ArchiveIsSafe' {
  BeforeAll {
    $script:SafeEntries = @(
      'Pester.psd1',
      'Pester.psm1',
      'bin/net8.0/Pester.dll',
      '_rels/.rels',
      'package/services/metadata/core-properties/nuget.psmdcp',
      '[Content_Types].xml',
      'Pester.nuspec'
    )
    $script:SafeArchive = Join-Path $TestDrive 'safe.nupkg'
    New-TestArchive -Path $script:SafeArchive -EntryNames $script:SafeEntries
    $script:Destination = Join-Path $TestDrive 'extract'
  }

  It 'should_plan_only_the_module_entries_when_the_archive_is_safe' {
    $plan = Invoke-ArchiveAssertion -ArchivePath $script:SafeArchive -Destination $script:Destination
    $names = $plan | ForEach-Object { $_.Entry.FullName }
    $names | Should -Be @('Pester.psd1', 'Pester.psm1', 'bin/net8.0/Pester.dll')
  }

  It 'should_plan_destinations_inside_the_target_when_the_archive_is_safe' {
    $plan = Invoke-ArchiveAssertion -ArchivePath $script:SafeArchive -Destination $script:Destination
    $expected = Join-Path $script:Destination 'Pester.psd1'
    ($plan | Where-Object { $_.Entry.FullName -eq 'Pester.psd1' }).Destination | Should -BeExactly $expected
  }

  It 'should_throw_when_an_entry_escapes_the_destination' {
    $path = Join-Path $TestDrive 'escape.nupkg'
    New-TestArchive -Path $path -EntryNames @('Pester.psd1', '../evil.txt')
    { Invoke-ArchiveAssertion -ArchivePath $path -Destination $script:Destination } |
      Should -Throw -ExpectedMessage '*parent-directory entry path*'
  }

  It 'should_throw_when_an_entry_escapes_the_destination_from_a_nested_directory' {
    $path = Join-Path $TestDrive 'nested-escape.nupkg'
    New-TestArchive -Path $path -EntryNames @('Pester.psd1', 'bin/../../evil.txt')
    { Invoke-ArchiveAssertion -ArchivePath $path -Destination $script:Destination } |
      Should -Throw -ExpectedMessage '*parent-directory entry path*'
  }

  It 'should_throw_when_an_entry_path_is_rooted' {
    $path = Join-Path $TestDrive 'rooted.nupkg'
    New-TestArchive -Path $path -EntryNames @('Pester.psd1', '/etc/evil')
    { Invoke-ArchiveAssertion -ArchivePath $path -Destination $script:Destination } |
      Should -Throw -ExpectedMessage '*rooted entry path*'
  }

  It 'should_throw_when_an_entry_path_contains_a_backslash' {
    $path = Join-Path $TestDrive 'backslash.nupkg'
    New-TestArchive -Path $path -EntryNames @('Pester.psd1', 'bin\evil.txt')
    { Invoke-ArchiveAssertion -ArchivePath $path -Destination $script:Destination } |
      Should -Throw -ExpectedMessage '*backslash in an entry path*'
  }

  It 'should_throw_when_the_archive_does_not_contain_the_pester_manifest' {
    $path = Join-Path $TestDrive 'nomanifest.nupkg'
    New-TestArchive -Path $path -EntryNames @('Pester.psm1', 'bin/net8.0/Pester.dll')
    { Invoke-ArchiveAssertion -ArchivePath $path -Destination $script:Destination } |
      Should -Throw -ExpectedMessage '*does not contain Pester.psd1*'
  }

  It 'should_throw_when_the_manifest_is_only_present_as_packaging_metadata' {
    $path = Join-Path $TestDrive 'metadata-only.nupkg'
    New-TestArchive -Path $path -EntryNames @('package/Pester.psd1')
    { Invoke-ArchiveAssertion -ArchivePath $path -Destination $script:Destination } |
      Should -Throw -ExpectedMessage '*does not contain Pester.psd1*'
  }
}

Describe 'Expand-VerifiedPackage' {
  It 'should_extract_only_the_module_entries_when_the_archive_is_safe' {
    $archivePath = Join-Path $TestDrive 'expand-safe.nupkg'
    New-TestArchive -Path $archivePath -EntryNames @(
      'Pester.psd1',
      'bin/net8.0/Pester.dll',
      '[Content_Types].xml',
      'Pester.nuspec',
      '_rels/.rels'
    )
    $destination = Join-Path $TestDrive 'expand-safe-out'

    Expand-VerifiedPackage -ArchivePath $archivePath -Destination $destination

    Test-Path -LiteralPath (Join-Path $destination 'Pester.psd1') -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $destination 'bin/net8.0/Pester.dll') -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $destination '[Content_Types].xml') | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $destination 'Pester.nuspec') | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $destination '_rels') | Should -BeFalse
  }

  It 'should_write_nothing_outside_the_destination_when_an_entry_escapes' {
    $archivePath = Join-Path $TestDrive 'expand-escape.nupkg'
    New-TestArchive -Path $archivePath -EntryNames @('Pester.psd1', '../evil.txt')
    $destination = Join-Path (Join-Path $TestDrive 'expand-escape-out') 'inner'

    { Expand-VerifiedPackage -ArchivePath $archivePath -Destination $destination } |
      Should -Throw -ExpectedMessage '*parent-directory entry path*'

    Test-Path -LiteralPath (Join-Path (Split-Path -Parent $destination) 'evil.txt') | Should -BeFalse
  }
}

Describe 'Assert-WorkflowFileValue' {
  It 'should_return_without_error_when_the_value_has_no_line_breaks' {
    { Assert-WorkflowFileValue -Name 'version' -Value '6.2.0' } | Should -Not -Throw
  }

  It 'should_return_without_error_when_the_value_is_empty' {
    { Assert-WorkflowFileValue -Name 'version' -Value '' } | Should -Not -Throw
  }

  It 'should_throw_when_the_value_contains_a_newline' {
    { Assert-WorkflowFileValue -Name 'module-path' -Value "ok`nPATH=/evil" } |
      Should -Throw -ExpectedMessage '*must not contain carriage returns or newlines*'
  }

  It 'should_throw_when_the_value_contains_a_carriage_return' {
    { Assert-WorkflowFileValue -Name 'module-path' -Value "ok`rPATH=/evil" } |
      Should -Throw -ExpectedMessage '*must not contain carriage returns or newlines*'
  }
}
