BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'windows.ps1'

    # ~keep The script ends by executing the binary it just unpacked ("& $taskExe --version").
    # A shebang stub satisfies that on POSIX hosts; on Windows only a real PE image would, so
    # the tests that run to completion are skipped there and the Windows runner covers the
    # rest through the paths that throw before this line. See the -Skip reasons below.
    function New-ExecutableStub {
        param([string]$Path, [string]$Output)

        # ~keep chmod is a native binary and receives the string verbatim, while PowerShell's
        # own path parameters silently normalise "\" to "/" on POSIX. Passing the unnormalised
        # path made chmod fail against a name that does not exist, leaving a non-executable
        # stub that the script then failed to run -- without failing the assertions above it.
        $posixPath = $Path -replace '\\', '/'
        Set-Content -LiteralPath $posixPath -Value @('#!/bin/sh', "echo '$Output'")
        & chmod +x $posixPath
        if ($LASTEXITCODE -ne 0) { throw "could not make the stub at $posixPath executable" }
    }

    # ~keep CI runs all nine suites in a single pwsh process, so an environment variable left
    # ~keep behind here decides what the next file sees -- TEMP and USERPROFILE especially,
    # ~keep since [IO.Path]::GetTempPath() reads them. Snapshot on entry, hand back on exit.
    $script:SavedEnvironment = @{}
    foreach ($name in @('RUNNER_TEMP', 'GITHUB_PATH', 'GITHUB_TOKEN')) {
        $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

Describe 'install-task windows.ps1' {
    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) "install-task-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:BinDir = Join-Path $script:Root 'bin'
        New-Item -ItemType Directory -Path $script:BinDir -Force | Out-Null
        $script:GithubPath = Join-Path $script:Root 'github-path'
        Set-Content -LiteralPath $script:GithubPath -Value @()

        $env:RUNNER_TEMP = $script:Root
        $env:GITHUB_PATH = $script:GithubPath
        $env:GITHUB_TOKEN = $null

        # ~keep "$taskBinDir\task.exe" is string concatenation, not Join-Path, so the literal
        # backslash survives on POSIX and names a single file. The tests build the same string
        # rather than assuming a nested directory.
        $script:TaskExe = "$script:BinDir\task.exe"

        Mock Invoke-WebRequest { }
        Mock Expand-Archive { }
        Mock Remove-Item { }
        Mock Start-Sleep { }
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue
        $env:GITHUB_TOKEN = $null
    }

    It 'should_prefix_a_bare_pinned_version_with_v_when_building_the_download_url' {
        { & $script:Script '3.51.1' $script:BinDir } | Should -Throw

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/go-task/task/releases/download/v3.51.1/task_windows_amd64.zip'
        }
    }

    It 'should_keep_an_already_prefixed_version_unchanged_when_building_the_download_url' {
        { & $script:Script 'v3.51.1' $script:BinDir } | Should -Throw

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/go-task/task/releases/download/v3.51.1/task_windows_amd64.zip'
        }
    }

    It 'should_resolve_the_latest_tag_from_the_github_api_when_no_version_is_given' {
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'v3.52.0' } }

        { & $script:Script '' $script:BinDir } | Should -Throw

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.com/repos/go-task/task/releases/latest'
        }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/go-task/task/releases/download/v3.52.0/task_windows_amd64.zip'
        }
    }

    It 'should_fall_back_to_the_releases_latest_redirect_when_the_github_api_lookup_fails' {
        Mock Invoke-RestMethod { throw 'rate limit exceeded' }
        Mock Invoke-WebRequest {
            [pscustomobject]@{ Headers = @{ Location = 'https://github.com/go-task/task/releases/tag/v3.53.0' } }
        } -ParameterFilter { $Uri -eq 'https://github.com/go-task/task/releases/latest' }

        { & $script:Script 'latest' $script:BinDir } | Should -Throw

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/go-task/task/releases/download/v3.53.0/task_windows_amd64.zip'
        }
    }

    It 'should_throw_when_neither_the_api_nor_the_redirect_yields_a_latest_tag' {
        Mock Invoke-RestMethod { throw 'rate limit exceeded' }
        Mock Invoke-WebRequest {
            [pscustomobject]@{ Headers = @{} }
        } -ParameterFilter { $Uri -eq 'https://github.com/go-task/task/releases/latest' }

        $thrown = { & $script:Script 'latest' $script:BinDir } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly 'Could not resolve the latest Task release'
    }

    It 'should_send_a_bearer_authorization_header_when_a_github_token_is_present' {
        $env:GITHUB_TOKEN = 'secret-token'
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'v3.52.0' } }

        { & $script:Script 'latest' $script:BinDir } | Should -Throw

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Headers['Authorization'] -eq 'Bearer secret-token' -and
            $Headers['X-GitHub-Api-Version'] -eq '2022-11-28'
        }
    }

    It 'should_always_send_the_api_version_header_even_without_a_token' {
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'v3.52.0' } }

        { & $script:Script 'latest' $script:BinDir } | Should -Throw

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Headers.Count -eq 1 -and $Headers['X-GitHub-Api-Version'] -eq '2022-11-28'
        }
    }

    It 'should_retry_the_download_three_times_with_exponential_backoff_before_giving_up' {
        Mock Invoke-WebRequest { throw 'connection reset' }

        $thrown = { & $script:Script '3.51.1' $script:BinDir } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly 'Failed to download https://github.com/go-task/task/releases/download/v3.51.1/task_windows_amd64.zip after 3 attempts: connection reset'
        Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 4 }
    }

    It 'should_stop_retrying_once_a_download_attempt_succeeds' {
        $script:Attempts = 0
        Mock Invoke-WebRequest {
            $script:Attempts++
            if ($script:Attempts -eq 1) { throw 'transient failure' }
        }

        { & $script:Script '3.51.1' $script:BinDir } | Should -Throw

        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'should_throw_when_the_archive_did_not_contain_the_task_executable' {
        $thrown = { & $script:Script '3.51.1' $script:BinDir } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly "Task binary not found at $script:TaskExe"
        Get-Content -LiteralPath $script:GithubPath | Should -BeNullOrEmpty
    }

    It 'should_default_the_install_directory_to_task_bin_under_runner_temp' {
        $expected = "$(Join-Path $env:RUNNER_TEMP 'task-bin')\task.exe"

        $thrown = { & $script:Script '3.51.1' '' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly "Task binary not found at $expected"
    }

    It 'should_unpack_the_archive_into_the_requested_directory_and_delete_the_zip' {
        Mock Expand-Archive { New-ExecutableStub -Path $script:TaskExe -Output 'Task version: v3.51.1' }

        & $script:Script '3.51.1' $script:BinDir | Out-Null

        Should -Invoke Expand-Archive -Times 1 -Exactly -ParameterFilter {
            $Path -eq "$script:BinDir\task.zip" -and $DestinationPath -eq $script:BinDir
        }
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
            $Path -eq "$script:BinDir\task.zip"
        }
    } -Skip:($IsWindows)

    It 'should_report_the_installed_version_and_append_the_bin_directory_to_github_path' {
        Mock Expand-Archive { New-ExecutableStub -Path $script:TaskExe -Output 'Task version: v3.51.1' }

        # ~keep 6>&1 merges the information stream: the script announces the resolved version
        # with Write-Host, which the call operator does not place on the success stream.
        $output = @(& $script:Script '3.51.1' $script:BinDir 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain 'Installing Task v3.51.1'
        $output[-1] | Should -BeExactly 'Task version: v3.51.1'
        Get-Content -LiteralPath $script:GithubPath | Should -BeExactly $script:BinDir
    } -Skip:($IsWindows)

    AfterAll {
        foreach ($entry in $script:SavedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
    }
}
