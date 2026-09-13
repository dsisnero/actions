BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'windows.ps1'

    # ~keep CI runs all nine suites in a single pwsh process, so an environment variable left
    # ~keep behind here decides what the next file sees -- TEMP and USERPROFILE especially,
    # ~keep since [IO.Path]::GetTempPath() reads them. Snapshot on entry, hand back on exit.
    $script:SavedEnvironment = @{}
    foreach ($name in @('USERPROFILE', 'TEMP', 'GITHUB_PATH', 'GITHUB_TOKEN', 'PROCESSOR_ARCHITECTURE')) {
        $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

Describe 'ensure-gh windows.ps1' {
    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) "ensure-gh-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:GithubPath = Join-Path $script:Root 'github-path'
        Set-Content -LiteralPath $script:GithubPath -Value @()

        $env:USERPROFILE = Join-Path $script:Root 'home'
        $env:TEMP = $script:Root
        $env:GITHUB_PATH = $script:GithubPath
        $env:GITHUB_TOKEN = $null
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        $script:BinDir = "$($env:USERPROFILE)\AppData\Local\gh"

        # ~keep Every filesystem-touching cmdlet is mocked rather than allowed through: the
        # script builds Windows paths by string concatenation ("$dir\gh.exe"), which on a
        # POSIX host would create one flat file with backslashes in its name instead of the
        # nested tree Windows makes. The path *strings* are the behaviour under test.
        Mock New-Item { }
        Mock Move-Item { }
        Mock Expand-Archive { }
        Mock Remove-Item { }
        Mock Invoke-WebRequest { }
        Mock Test-Path { $true }
        Mock Get-Command { $null }
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue
        $env:GITHUB_TOKEN = $null
    }

    It 'should_throw_usage_error_when_version_argument_is_empty' {
        $thrown = { & $script:Script '' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly 'Usage: windows.ps1 <version>'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'should_exit_without_downloading_when_gh_is_already_installed' {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Program Files\GitHub CLI\gh.exe' } }

        $output = & $script:Script 'latest'

        $output | Should -BeExactly 'gh already installed: C:\Program Files\GitHub CLI\gh.exe'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Get-Content -LiteralPath $script:GithubPath | Should -BeNullOrEmpty
    }

    It 'should_download_the_amd64_archive_for_a_pinned_version' {
        & $script:Script '2.60.1' | Out-Null

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/cli/cli/releases/download/v2.60.1/gh_2.60.1_windows_amd64.zip'
        }
    }

    It 'should_strip_a_leading_v_from_the_requested_version_before_building_the_url' {
        & $script:Script 'v2.60.1' | Out-Null

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/cli/cli/releases/download/v2.60.1/gh_2.60.1_windows_amd64.zip'
        }
    }

    It 'should_request_the_arm64_archive_when_the_runner_reports_arm64' {
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'

        & $script:Script '2.60.1' | Out-Null

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/cli/cli/releases/download/v2.60.1/gh_2.60.1_windows_arm64.zip'
        }
    }

    It 'should_resolve_the_latest_tag_through_the_github_api_and_download_that_version' {
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'v2.62.0' } }

        $output = & $script:Script 'latest'

        $output[0] | Should -BeExactly 'Resolved latest gh version: 2.62.0'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.com/repos/cli/cli/releases/latest'
        }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/cli/cli/releases/download/v2.62.0/gh_2.62.0_windows_amd64.zip'
        }
    }

    It 'should_send_a_bearer_authorization_header_when_a_github_token_is_present' {
        $env:GITHUB_TOKEN = 'secret-token'
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'v2.62.0' } }

        & $script:Script 'latest' | Out-Null

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Headers['Authorization'] -eq 'Bearer secret-token' -and
            $Headers['X-GitHub-Api-Version'] -eq '2022-11-28'
        }
    }

    It 'should_send_no_authorization_header_when_no_github_token_is_present' {
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'v2.62.0' } }

        & $script:Script 'latest' | Out-Null

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Headers.Count -eq 0
        }
    }

    It 'should_throw_when_the_archive_does_not_contain_the_expected_gh_executable' {
        Mock Test-Path { $false } -ParameterFilter { $Path -like '*gh_2.60.1_windows_amd64*' }

        $thrown = { & $script:Script '2.60.1' } | Should -Throw -PassThru

        # ~keep Separators are normalised before comparison because Join-Path rewrites them to
        # the host's convention: the same expression yields "...\bin\gh.exe" on a Windows
        # runner and ".../bin/gh.exe" here. The path *components* are what this asserts.
        $message = $thrown.Exception.Message -replace '\\', '/'
        $message | Should -Match '^gh\.exe not found at expected path: .+/gh_2\.60\.1_windows_amd64/bin/gh\.exe$'
        Should -Invoke Move-Item -Times 0 -Exactly
    }

    It 'should_move_the_extracted_executable_into_the_local_bin_directory' {
        & $script:Script '2.60.1' | Out-Null

        Should -Invoke Move-Item -Times 1 -Exactly -ParameterFilter {
            $Destination -eq "$($env:USERPROFILE)\AppData\Local\gh\gh.exe"
        }
    }

    It 'should_append_the_bin_directory_to_github_path_after_a_successful_install' {
        $output = & $script:Script '2.60.1'

        $output[-1] | Should -BeExactly "gh v2.60.1 installed at $script:BinDir\gh.exe"
        Get-Content -LiteralPath $script:GithubPath | Should -BeExactly $script:BinDir
    }

    It 'should_remove_the_temporary_download_directory_even_when_the_download_fails' {
        Mock Invoke-WebRequest { throw 'network down' }

        { & $script:Script '2.60.1' } | Should -Throw

        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
            $Path -like "*ensure-gh-*"
        }
        Get-Content -LiteralPath $script:GithubPath | Should -BeNullOrEmpty
    }

    AfterAll {
        foreach ($entry in $script:SavedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
    }
}
