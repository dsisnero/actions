#Requires -Modules Pester

# Unit tests for run-pester. The pure path and input helpers are called directly; the containment
# contract as a whole is exercised by running scripts/run.ps1 in a child pwsh against a fake Pester
# module, so no test here needs the network or the real Pester on PSModulePath.

BeforeAll {
  $script:ActionRoot = Split-Path -Parent $PSScriptRoot
  $script:RunScript = Join-Path $script:ActionRoot 'scripts/run.ps1'
  . (Join-Path $script:ActionRoot 'scripts/lib.ps1')

  $script:FakePesterVersion = '9.9.9'
  $script:Separator = [System.IO.Path]::DirectorySeparatorChar

  # `#>` inside a here-string would still be read as the end of a comment-based help block by the
  # parser, so the fake module is assembled from plain statements only. ~keep
  function New-FakePesterModule {
    param(
      [Parameter(Mandatory)]
      [string]$Root
    )

    $moduleDirectory = Join-Path (Join-Path $Root 'Pester') $script:FakePesterVersion
    New-Item -ItemType Directory -Path $moduleDirectory -Force | Out-Null

    $moduleBody = @'
function New-PesterConfiguration {
  return [pscustomobject]@{
    Run        = [pscustomobject]@{ Path = @(); Exit = $false }
    Output     = [pscustomobject]@{ CIFormat = ''; Verbosity = '' }
    Should     = [pscustomobject]@{ ErrorAction = '' }
    Filter     = [pscustomobject]@{ Tag = @(); FullName = @() }
    TestResult = [pscustomobject]@{ Enabled = $false; OutputPath = '' }
  }
}

function Invoke-Pester {
  param(
    [Parameter(Mandatory)]
    $Configuration
  )

  $capture = [pscustomobject]@{
    Path        = @($Configuration.Run.Path)
    Exit        = $Configuration.Run.Exit
    CIFormat    = $Configuration.Output.CIFormat
    Verbosity   = $Configuration.Output.Verbosity
    ErrorAction = $Configuration.Should.ErrorAction
    Tag         = @($Configuration.Filter.Tag)
    FullName    = @($Configuration.Filter.FullName)
    ResultPath  = $Configuration.TestResult.OutputPath
  }
  $capture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:FAKE_PESTER_CAPTURE -Encoding utf8
}

Export-ModuleMember -Function New-PesterConfiguration, Invoke-Pester
'@
    Set-Content -LiteralPath (Join-Path $moduleDirectory 'Pester.psm1') -Value $moduleBody -Encoding utf8

    $manifest = @"
@{
  ModuleVersion     = '$($script:FakePesterVersion)'
  GUID              = 'b4d1f0b2-6f5a-4f1e-9a4a-2b3c4d5e6f70'
  Author            = 'run-pester tests'
  RootModule        = 'Pester.psm1'
  FunctionsToExport = @('New-PesterConfiguration', 'Invoke-Pester')
}
"@
    Set-Content -LiteralPath (Join-Path $moduleDirectory 'Pester.psd1') -Value $manifest -Encoding utf8

    return $moduleDirectory
  }

  function Invoke-RunScript {
    param(
      [Parameter(Mandatory)]
      [hashtable]$Environment,

      [AllowNull()]
      [string]$WorkingDirectory
    )

    $keys = @(
      'GITHUB_WORKSPACE', 'PSModulePath', 'FAKE_PESTER_CAPTURE',
      'INPUT_PATH', 'INPUT_WORKING_DIRECTORY', 'INPUT_MODULE_PATH', 'INPUT_VERSION',
      'INPUT_OUTPUT_VERBOSITY', 'INPUT_FILTER_TAG', 'INPUT_FILTER_FULL_NAME', 'INPUT_RESULT_PATH'
    )

    $saved = @{}
    foreach ($key in $keys) {
      $saved[$key] = [System.Environment]::GetEnvironmentVariable($key)
      $value = if ($Environment.ContainsKey($key)) { $Environment[$key] } else { '' }
      [System.Environment]::SetEnvironmentVariable($key, $value)
    }

    # PSModulePath has to be reassigned inside the child: pwsh prepends the user, shared and
    # system module directories to whatever it inherits, so an inherited value alone would leave
    # the machine's real Pester ahead of the fake one these tests depend on. ~keep
    $modulePathLiteral = ([string]$Environment['PSModulePath']).Replace("'", "''")
    $scriptLiteral = $script:RunScript.Replace("'", "''")
    $command = "`$env:PSModulePath = '${modulePathLiteral}'; `$LASTEXITCODE = 0; " +
    "& '${scriptLiteral}'; exit `$LASTEXITCODE"

    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) {
      Push-Location -LiteralPath $WorkingDirectory
    }
    try {
      $output = & pwsh -NoProfile -Command $command 2>&1 | Out-String
      return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } finally {
      if (-not [string]::IsNullOrEmpty($WorkingDirectory)) {
        Pop-Location
      }
      foreach ($key in $keys) {
        [System.Environment]::SetEnvironmentVariable($key, $saved[$key])
      }
    }
  }
}

Describe 'ConvertTo-NormalizedPath' {
  It 'should_fold_the_alternate_separator_when_the_path_uses_forward_slashes' {
    $expected = 'a' + $script:Separator + 'b'
    ConvertTo-NormalizedPath -Path 'a/b' | Should -BeExactly $expected
  }

  It 'should_drop_a_trailing_separator_when_the_path_ends_with_one' {
    $trailing = 'a' + $script:Separator + 'b' + $script:Separator
    ConvertTo-NormalizedPath -Path $trailing | Should -BeExactly ('a' + $script:Separator + 'b')
  }
}

Describe 'Test-PathIsWithin' {
  BeforeAll {
    $script:Workspace = Join-Path $TestDrive 'ws'
  }

  It 'should_return_true_when_the_path_is_the_parent_itself' {
    Test-PathIsWithin -Path $script:Workspace -Parent $script:Workspace | Should -BeTrue
  }

  It 'should_return_true_when_the_path_is_nested_under_the_parent' {
    Test-PathIsWithin -Path (Join-Path $script:Workspace 'tests/unit') -Parent $script:Workspace | Should -BeTrue
  }

  It 'should_return_true_when_the_parent_carries_a_trailing_separator' {
    Test-PathIsWithin -Path (Join-Path $script:Workspace 'tests') -Parent ($script:Workspace + $script:Separator) |
      Should -BeTrue
  }

  It 'should_return_false_when_the_path_only_shares_a_name_prefix_with_the_parent' {
    Test-PathIsWithin -Path ($script:Workspace + '-evil') -Parent $script:Workspace | Should -BeFalse
  }

  It 'should_return_false_when_the_path_is_the_parent_of_the_parent' {
    Test-PathIsWithin -Path (Split-Path -Parent $script:Workspace) -Parent $script:Workspace | Should -BeFalse
  }
}

Describe 'Resolve-PhysicalPath' {
  It 'should_collapse_parent_segments_when_the_path_walks_upwards' {
    $directory = Join-Path $TestDrive 'resolve/inner'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $walked = Join-Path $directory '..'

    Resolve-PhysicalPath -Path $walked | Should -BeExactly (Resolve-PhysicalPath -Path (Split-Path -Parent $directory))
  }

  It 'should_resolve_a_symlinked_component_in_the_middle_of_the_path' -Skip:$IsWindows {
    # The leaf is a real directory; only its parent is a link. ResolveLinkTarget alone would leave
    # the link spelling in place, and the containment check would then reject a legitimate path.
    $real = Join-Path $TestDrive 'physical-parent'
    New-Item -ItemType Directory -Path (Join-Path $real 'child') -Force | Out-Null
    $link = Join-Path $TestDrive 'linked-parent'
    if (-not (Test-Path -LiteralPath $link)) {
      New-Item -ItemType SymbolicLink -Path $link -Target $real | Out-Null
    }

    Resolve-PhysicalPath -Path (Join-Path $link 'child') |
      Should -BeExactly (Resolve-PhysicalPath -Path (Join-Path $real 'child'))
  }

  It 'should_keep_the_file_name_when_the_path_is_a_file' {
    $file = Join-Path $TestDrive 'resolve-file.txt'
    Set-Content -LiteralPath $file -Value 'x' -Encoding utf8

    Resolve-PhysicalPath -Path $file | Should -BeLike '*resolve-file.txt'
  }
}

Describe 'Test-PathIsSymbolicLink' {
  It 'should_return_false_when_the_path_is_a_real_directory' {
    $directory = Join-Path $TestDrive 'real-dir'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    Test-PathIsSymbolicLink -Path $directory | Should -BeFalse
  }

  It 'should_return_true_when_the_path_is_a_symbolic_link' -Skip:$IsWindows {
    $target = Join-Path $TestDrive 'link-target'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $link = Join-Path $TestDrive 'the-link'
    New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null

    Test-PathIsSymbolicLink -Path $link | Should -BeTrue
  }
}

Describe 'ConvertTo-FilterList' {
  It 'should_return_an_empty_list_when_the_value_is_empty' {
    @(ConvertTo-FilterList -Name 'filter-tag' -Value '').Count | Should -Be 0
  }

  It 'should_return_one_element_per_line_when_every_line_is_populated' {
    ConvertTo-FilterList -Name 'filter-tag' -Value "windows`nneeds network" |
      Should -Be @('windows', 'needs network')
  }

  It 'should_keep_spaces_inside_a_line_when_splitting' {
    (ConvertTo-FilterList -Name 'filter-tag' -Value "windows`nneeds network")[1] | Should -BeExactly 'needs network'
  }

  It 'should_ignore_a_single_trailing_newline_when_the_block_scalar_kept_one' {
    ConvertTo-FilterList -Name 'filter-tag' -Value "windows`n" | Should -Be @('windows')
  }

  It 'should_split_on_windows_line_endings_when_the_value_uses_them' {
    ConvertTo-FilterList -Name 'filter-tag' -Value "windows`r`nslow" | Should -Be @('windows', 'slow')
  }

  It 'should_throw_when_a_line_is_empty' {
    { ConvertTo-FilterList -Name 'filter-tag' -Value "windows`n`nslow" } |
      Should -Throw -ExpectedMessage '*without empty lines*'
  }

  It 'should_throw_when_a_line_is_only_whitespace' {
    { ConvertTo-FilterList -Name 'filter-tag' -Value "windows`n   `nslow" } |
      Should -Throw -ExpectedMessage '*without empty lines*'
  }
}

Describe 'Get-ValidatedVerbosity' {
  It 'should_return_detailed_when_the_value_is_empty' {
    Get-ValidatedVerbosity -Value '' | Should -BeExactly 'Detailed'
  }

  It 'should_return_the_canonical_casing_when_the_value_differs_in_case' {
    Get-ValidatedVerbosity -Value 'diagnostic' | Should -BeExactly 'Diagnostic'
  }

  It 'should_throw_when_the_value_is_not_on_the_allowlist' {
    { Get-ValidatedVerbosity -Value 'Verbose' } | Should -Throw -ExpectedMessage '*must be one of*'
  }

  It 'should_throw_when_the_value_smuggles_an_extra_token' {
    { Get-ValidatedVerbosity -Value 'Detailed; Remove-Item /' } | Should -Throw -ExpectedMessage '*must be one of*'
  }
}

Describe 'run.ps1' {
  BeforeAll {
    $script:ModulesRoot = Join-Path $TestDrive 'modules'
    $script:FakeModuleDirectory = New-FakePesterModule -Root $script:ModulesRoot

    $script:Workspace = Join-Path $TestDrive 'workspace'
    $script:SuiteDirectory = Join-Path $script:Workspace 'tests'
    New-Item -ItemType Directory -Path $script:SuiteDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $script:SuiteDirectory 'sample.Tests.ps1') -Value '# fixture' -Encoding utf8
    New-Item -ItemType Directory -Path (Join-Path $script:Workspace 'other') -Force | Out-Null

    $script:CapturePath = Join-Path $TestDrive 'capture.json'

    function New-RunEnvironment {
      param(
        [hashtable]$Overrides = @{}
      )

      $environment = @{
        GITHUB_WORKSPACE        = $script:Workspace
        PSModulePath            = $script:ModulesRoot
        FAKE_PESTER_CAPTURE     = $script:CapturePath
        INPUT_WORKING_DIRECTORY = $script:Workspace
        INPUT_PATH              = 'tests'
        INPUT_VERSION           = $script:FakePesterVersion
      }
      foreach ($key in $Overrides.Keys) {
        $environment[$key] = $Overrides[$key]
      }

      return $environment
    }
  }

  BeforeEach {
    Remove-Item -LiteralPath $script:CapturePath -Force -ErrorAction SilentlyContinue
  }

  It 'should_run_the_suite_when_every_path_is_contained' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment)

    $result.ExitCode | Should -Be 0 -Because $result.Output
    $capture = Get-Content -LiteralPath $script:CapturePath -Raw | ConvertFrom-Json
    $capture.Path | Should -Be @((Resolve-PhysicalPath -Path $script:SuiteDirectory))
    $capture.Exit | Should -BeTrue
    $capture.CIFormat | Should -BeExactly 'GithubActions'
    $capture.ErrorAction | Should -BeExactly 'Stop'
    $capture.Verbosity | Should -BeExactly 'Detailed'
  }

  It 'should_pass_multi_word_filters_through_intact_when_they_are_newline_delimited' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{
        INPUT_FILTER_TAG       = "windows`nneeds network"
        INPUT_FILTER_FULL_NAME = 'Describe*'
      })

    $result.ExitCode | Should -Be 0 -Because $result.Output
    $capture = Get-Content -LiteralPath $script:CapturePath -Raw | ConvertFrom-Json
    $capture.Tag | Should -Be @('windows', 'needs network')
    $capture.FullName | Should -Be @('Describe*')
  }

  It 'should_reject_the_test_path_when_it_is_outside_the_workspace' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{ INPUT_PATH = '../' })

    $result.ExitCode | Should -Be 1
    $result.Output | Should -BeLike '*must be inside GITHUB_WORKSPACE*'
    Test-Path -LiteralPath $script:CapturePath | Should -BeFalse
  }

  It 'should_reject_the_test_path_when_it_is_outside_the_working_directory' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{
        INPUT_WORKING_DIRECTORY = (Join-Path $script:Workspace 'other')
        INPUT_PATH              = (Join-Path $script:Workspace 'tests')
      })

    $result.ExitCode | Should -Be 1
    $result.Output | Should -BeLike '*must be inside the working directory*'
  }

  It 'should_reject_the_working_directory_when_it_is_outside_the_workspace' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{
        INPUT_WORKING_DIRECTORY = ([string]$TestDrive)
        INPUT_PATH              = (Join-Path $script:SuiteDirectory 'sample.Tests.ps1')
      })

    $result.ExitCode | Should -Be 1
    $result.Output | Should -BeLike '*Working directory must be inside GITHUB_WORKSPACE*'
  }

  It 'should_reject_the_test_path_when_it_is_a_symbolic_link' -Skip:$IsWindows {
    # Not skipped for convenience: creating a symbolic link on Windows needs Developer Mode or
    # SeCreateSymbolicLinkPrivilege, neither of which a GitHub-hosted runner grants by default,
    # so the fixture -- not the control -- is what would fail there. ~keep
    $link = Join-Path $script:Workspace 'linked-tests'
    if (-not (Test-Path -LiteralPath $link)) {
      New-Item -ItemType SymbolicLink -Path $link -Target $script:SuiteDirectory | Out-Null
    }

    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{ INPUT_PATH = 'linked-tests' })

    $result.ExitCode | Should -Be 1
    $result.Output | Should -BeLike '*must not be a symbolic link*'
  }

  It 'should_reject_the_test_path_when_it_does_not_exist' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{ INPUT_PATH = 'absent' })

    $result.ExitCode | Should -Be 1
    $result.Output | Should -BeLike '*does not exist*'
  }

  It 'should_reject_the_run_when_filter_tag_contains_an_empty_line' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{
        INPUT_FILTER_TAG = "windows`n`nslow"
      })

    $result.ExitCode | Should -Be 1
    $result.Output | Should -BeLike '*without empty lines*'
    Test-Path -LiteralPath $script:CapturePath | Should -BeFalse
  }

  It 'should_reject_the_run_when_output_verbosity_is_not_on_the_allowlist' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{ INPUT_OUTPUT_VERBOSITY = 'Verbose' })

    $result.ExitCode | Should -Be 1
    $result.Output | Should -BeLike '*must be one of*'
  }

  It 'should_reject_the_run_when_the_imported_pester_is_not_the_required_version' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{ INPUT_VERSION = '6.2.0' })

    $result.ExitCode | Should -Be 1
    $result.Output | Should -BeLike "*Imported Pester is $($script:FakePesterVersion), not the required 6.2.0*"
    Test-Path -LiteralPath $script:CapturePath | Should -BeFalse
  }

  It 'should_report_that_pester_is_missing_when_no_module_can_be_imported' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{
        PSModulePath  = (Join-Path $TestDrive 'no-modules')
        INPUT_VERSION = ''
      })

    $result.ExitCode | Should -Be 1
    $result.Output | Should -BeLike '*Run install-pester before run-pester*'
  }

  It 'should_reject_the_result_path_when_it_leaves_the_workspace' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{
        INPUT_RESULT_PATH = '../escaped-results.xml'
      })

    $result.ExitCode | Should -Be 1
    $result.Output | Should -BeLike '*result path must be inside GITHUB_WORKSPACE*'
  }

  It 'should_enable_the_result_file_when_the_result_path_stays_inside_the_workspace' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{
        INPUT_RESULT_PATH = 'results/pester.xml'
      })

    $result.ExitCode | Should -Be 0 -Because $result.Output
    $capture = Get-Content -LiteralPath $script:CapturePath -Raw | ConvertFrom-Json
    $expected = [System.IO.Path]::GetFullPath((Join-Path $script:Workspace 'results/pester.xml'))
    $capture.ResultPath | Should -BeExactly $expected
  }

  It 'should_import_the_named_manifest_when_module_path_is_given' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{
        PSModulePath      = (Join-Path $TestDrive 'no-modules')
        INPUT_MODULE_PATH = (Join-Path $script:FakeModuleDirectory 'Pester.psd1')
      })

    $result.ExitCode | Should -Be 0 -Because $result.Output
    Test-Path -LiteralPath $script:CapturePath | Should -BeTrue
  }

  It 'should_import_the_named_manifest_when_module_path_is_relative' {
    # Import-Module reads a relative path with no "./" prefix as a module NAME, so run.ps1 has to
    # make it absolute before importing.
    $relative = Join-Path (Join-Path 'modules' 'Pester') "$($script:FakePesterVersion)/Pester.psd1"
    $result = Invoke-RunScript -WorkingDirectory ([string]$TestDrive) -Environment (New-RunEnvironment -Overrides @{
        PSModulePath      = (Join-Path $TestDrive 'no-modules')
        INPUT_MODULE_PATH = $relative
      })

    $result.ExitCode | Should -Be 0 -Because $result.Output
    Test-Path -LiteralPath $script:CapturePath | Should -BeTrue
  }

  It 'should_reject_the_run_when_the_named_manifest_does_not_exist' {
    $result = Invoke-RunScript -Environment (New-RunEnvironment -Overrides @{
        INPUT_MODULE_PATH = (Join-Path $TestDrive 'absent/Pester.psd1')
      })

    $result.ExitCode | Should -Be 1
    $result.Output | Should -BeLike '*Pester module path does not exist*'
  }
}
