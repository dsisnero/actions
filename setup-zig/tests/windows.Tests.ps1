BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'windows.ps1'

    function New-ZigIndex {
        [pscustomobject]@{
            'master'  = [pscustomobject]@{
                version          = '0.15.0-dev.1234'
                'x86_64-windows' = [pscustomobject]@{ tarball = 'https://ziglang.org/builds/zig-x86_64-windows-master.zip' }
            }
            '0.13.0'  = [pscustomobject]@{
                'x86_64-windows'  = [pscustomobject]@{ tarball = 'https://ziglang.org/download/0.13.0/zig-x86_64-windows-0.13.0.zip' }
                'aarch64-windows' = [pscustomobject]@{ tarball = 'https://ziglang.org/download/0.13.0/zig-aarch64-windows-0.13.0.zip' }
            }
            '0.14.0'  = [pscustomobject]@{
                'x86_64-windows' = [pscustomobject]@{ tarball = 'https://ziglang.org/download/0.14.0/zig-x86_64-windows-0.14.0.zip' }
            }
            '0.9.1'   = [pscustomobject]@{
                'x86_64-windows' = [pscustomobject]@{ tarball = 'https://ziglang.org/download/0.9.1/zig-x86_64-windows-0.9.1.zip' }
            }
        }
    }

    # ~keep The script finishes by running the unpacked "zig.exe". A shebang stub covers that
    # on POSIX hosts only, so the two tests that reach it are skipped on Windows; every other
    # behaviour here is asserted through paths that throw before that line.
    function New-ExtractedZig {
        param([string]$InstallDir, [string]$DirectoryName, [string]$Output)

        $dir = Join-Path $InstallDir $DirectoryName
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $exe = Join-Path $dir 'zig.exe'
        Set-Content -LiteralPath $exe -Value @('#!/bin/sh', "echo '$Output'")
        & chmod +x $exe
        if ($LASTEXITCODE -ne 0) { throw "could not make the stub at $exe executable" }
    }

    # ~keep CI runs all nine suites in a single pwsh process, so an environment variable left
    # ~keep behind here decides what the next file sees -- TEMP and USERPROFILE especially,
    # ~keep since [IO.Path]::GetTempPath() reads them. Snapshot on entry, hand back on exit.
    $script:SavedEnvironment = @{}
    foreach ($name in @('RUNNER_TEMP', 'GITHUB_PATH', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER')) {
        $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

Describe 'setup-zig windows.ps1' {
    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) "setup-zig-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:GithubPath = Join-Path $script:Root 'github-path'
        Set-Content -LiteralPath $script:GithubPath -Value @()

        $env:RUNNER_TEMP = $script:Root
        $env:GITHUB_PATH = $script:GithubPath
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        $env:PROCESSOR_IDENTIFIER = 'Intel64 Family 6'
        $script:InstallDir = Join-Path $script:Root 'zig'

        Mock Invoke-RestMethod { New-ZigIndex }
        Mock Invoke-WebRequest { }
        Mock Expand-Archive { }
        Mock Start-Sleep { }
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue
    }

    It 'should_read_the_release_index_from_the_official_ziglang_download_url' {
        { & $script:Script -Version '0.14.0' } | Should -Throw

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://ziglang.org/download/index.json'
        }
    }

    It 'should_select_the_highest_numbered_release_when_the_version_is_latest' {
        { & $script:Script -Version 'latest' } | Should -Throw

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://ziglang.org/download/0.14.0/zig-x86_64-windows-0.14.0.zip'
        }
    }

    It 'should_use_the_master_entry_when_the_version_is_master' {
        { & $script:Script -Version 'master' } | Should -Throw

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://ziglang.org/builds/zig-x86_64-windows-master.zip'
        }
    }

    It 'should_download_the_exact_release_when_the_version_is_pinned' {
        { & $script:Script -Version '0.13.0' } | Should -Throw

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://ziglang.org/download/0.13.0/zig-x86_64-windows-0.13.0.zip'
        }
    }

    It 'should_request_the_aarch64_asset_when_the_runner_reports_arm64' {
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'

        { & $script:Script -Version '0.13.0' } | Should -Throw

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://ziglang.org/download/0.13.0/zig-aarch64-windows-0.13.0.zip'
        }
    }

    It 'should_throw_when_the_requested_version_is_absent_from_the_index' {
        $thrown = { & $script:Script -Version '0.99.0' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly "Zig version '0.99.0' not found in ziglang.org index"
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'should_throw_when_the_index_entry_has_no_asset_for_the_detected_platform' {
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'

        $thrown = { & $script:Script -Version '0.14.0' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly 'No aarch64-windows asset for Zig 0.14.0'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'should_retry_the_download_three_times_before_propagating_the_failure' {
        Mock Invoke-WebRequest { throw 'connection reset' }

        $thrown = { & $script:Script -Version '0.14.0' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly 'connection reset'
        Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 2 }
    }

    It 'should_stop_retrying_once_a_download_attempt_succeeds' {
        $script:Attempts = 0
        Mock Invoke-WebRequest {
            $script:Attempts++
            if ($script:Attempts -eq 1) { throw 'transient failure' }
        }

        { & $script:Script -Version '0.14.0' } | Should -Throw

        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'should_throw_when_the_archive_yielded_no_zig_directory' {
        $thrown = { & $script:Script -Version '0.14.0' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly "Could not locate extracted zig directory under $script:InstallDir"
        Get-Content -LiteralPath $script:GithubPath | Should -BeNullOrEmpty
    }

    It 'should_download_the_archive_into_the_zig_directory_under_runner_temp' {
        { & $script:Script -Version '0.14.0' } | Should -Throw

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $OutFile -eq (Join-Path $script:InstallDir 'zig.zip')
        }
        Should -Invoke Expand-Archive -Times 1 -Exactly -ParameterFilter {
            $Path -eq (Join-Path $script:InstallDir 'zig.zip') -and $DestinationPath -eq $script:InstallDir
        }
    }

    It 'should_append_the_extracted_directory_to_github_path_and_report_the_zig_version' {
        Mock Expand-Archive {
            New-ExtractedZig -InstallDir $script:InstallDir -DirectoryName 'zig-x86_64-windows-0.14.0' -Output '0.14.0'
        }
        $expected = Join-Path $script:InstallDir 'zig-x86_64-windows-0.14.0'

        $output = @(& $script:Script -Version '0.14.0' 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain 'Resolved Zig 0.14.0 -> 0.14.0'
        $output[-1] | Should -BeExactly '0.14.0'
        Get-Content -LiteralPath $script:GithubPath | Should -BeExactly $expected
    } -Skip:($IsWindows)

    It 'should_report_the_master_build_version_from_the_index_entry' {
        Mock Expand-Archive {
            New-ExtractedZig -InstallDir $script:InstallDir -DirectoryName 'zig-x86_64-windows-master' -Output '0.15.0-dev.1234'
        }

        $output = @(& $script:Script -Version 'master' 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain 'Resolved Zig master -> 0.15.0-dev.1234'
    } -Skip:($IsWindows)

    AfterAll {
        foreach ($entry in $script:SavedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
    }
}
