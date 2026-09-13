BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'install-windows.ps1'

    # ~keep These are native Windows commands the script calls by bare name. Pester cannot mock
    # a command it cannot resolve, so stubs must exist before any Mock replaces them, and
    # PowerShell's function-before-executable resolution is what guarantees a host that happens
    # to ship cmake or php never reaches the real binary.
    function choco { $global:LASTEXITCODE = 0 }
    function cmake { $global:LASTEXITCODE = 0 }
    function php { $global:LASTEXITCODE = 0 }
    function clang { $global:LASTEXITCODE = 0 }
    function tesseract { $global:LASTEXITCODE = 0 }

    # ~keep CI runs all nine suites in a single pwsh process, so an environment variable left
    # ~keep behind here decides what the next file sees -- TEMP and USERPROFILE especially,
    # ~keep since [IO.Path]::GetTempPath() reads them. Snapshot on entry, hand back on exit.
    $script:SavedEnvironment = @{}
    foreach ($name in @('GITHUB_ENV', 'GITHUB_PATH', 'VCPKG_INSTALLATION_ROOT', 'TESSERACT_CACHE_HIT', 'LLVM_CACHE_HIT', 'CMAKE_CACHE_HIT', 'LIBHEIF_CACHE_HIT', 'TESSDATA_PREFIX', 'PATH')) {
        $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

Describe 'install-system-deps install-windows.ps1' {
    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) "sysdeps-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:GithubEnv = Join-Path $script:Root 'github-env'
        $script:GithubPath = Join-Path $script:Root 'github-path'
        Set-Content -LiteralPath $script:GithubEnv -Value @()
        Set-Content -LiteralPath $script:GithubPath -Value @()

        $env:GITHUB_ENV = $script:GithubEnv
        $env:GITHUB_PATH = $script:GithubPath
        $env:VCPKG_INSTALLATION_ROOT = $null
        $env:TESSERACT_CACHE_HIT = 'true'
        $env:LLVM_CACHE_HIT = 'true'
        $env:CMAKE_CACHE_HIT = 'true'
        $env:LIBHEIF_CACHE_HIT = 'true'
        $env:TESSDATA_PREFIX = $null
        $script:SavedPath = $env:PATH

        # ~keep Join-Path resolves the drive qualifier through the PowerShell provider and so
        # raises DriveNotFoundException for the script's "C:\vcpkg" default on any POSIX host.
        # [IO.Path]::Combine is the same join without the drive lookup.
        Mock Join-Path { [System.IO.Path]::Combine($Path, $ChildPath) }

        # ~keep A test-declared filesystem, absent by default. Answering from the REAL
        # ~keep filesystem was not a mock at all: windows-latest genuinely ships
        # ~keep C:\vcpkg\vcpkg.exe and C:\Program Files\CMake\bin, so the two tests about an
        # ~keep ABSENT path were asserting against a present one and failed there while passing
        # ~keep on macOS. Worse, a present C:\vcpkg made the script reach
        # ~keep `& $vcpkgExe install libheif ...` -- a call BY PATH, which Pester cannot
        # ~keep intercept -- so the real vcpkg built libheif and boost from source and cost
        # ~keep ~14 minutes of CI wall clock, 839s of this job's 846s. Never declare
        # ~keep C:/vcpkg/vcpkg.exe present here: that re-enables the real build.
        # ~keep $global: not $script:, because $script: is invisible inside a Pester 6 mock body.
        # ~keep Separators are normalised so one declaration matches on Windows and POSIX alike.
        $global:VirtualPaths = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        Mock Test-Path { $global:VirtualPaths.Contains(([string]$Path).Replace('\', '/')) }
        Mock Start-Sleep { }
        Mock Invoke-WebRequest { }
        Mock choco { $global:LASTEXITCODE = 0 }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Program Files\CMake\bin\cmake.exe' } } -ParameterFilter { $Name -eq 'cmake' }
        Mock Get-Command { throw 'tesseract is not recognised' } -ParameterFilter { $Name -eq 'tesseract' }
    }

    AfterEach {
        Remove-Variable -Name VirtualPaths -Scope Global -ErrorAction SilentlyContinue
        $env:PATH = $script:SavedPath
        $env:TESSDATA_PREFIX = $null
        $env:VCPKG_INSTALLATION_ROOT = $null
        Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue
    }

    It 'should_skip_every_chocolatey_install_when_all_caches_are_warm' {
        & $script:Script 6>&1 | Out-Null

        Should -Invoke choco -Times 0 -Exactly
    }

    It 'should_report_each_warm_cache_without_installing' {
        $output = @(& $script:Script 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain '✓ Tesseract found in cache'
        $output | Should -Contain '✓ LLVM/Clang found in cache'
        $output | Should -Contain '✓ libheif/boost/zlib found in cache'
        $output | Should -Contain '✓ CMake found in cache'
    }

    It 'should_install_tesseract_and_llvm_and_cmake_when_their_caches_are_cold' {
        $env:TESSERACT_CACHE_HIT = 'false'
        $env:LLVM_CACHE_HIT = 'false'
        $env:CMAKE_CACHE_HIT = 'false'

        & $script:Script 6>&1 | Out-Null

        Should -Invoke choco -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq 'install -y tesseract --no-progress' }
        Should -Invoke choco -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq 'install -y llvm --no-progress' }
        Should -Invoke choco -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq 'install -y cmake --no-progress' }
    }

    It 'should_write_the_default_vcpkg_root_to_github_env_when_the_libheif_cache_is_cold' {
        $env:LIBHEIF_CACHE_HIT = 'false'

        & $script:Script 6>&1 | Out-Null

        Get-Content -LiteralPath $script:GithubEnv | Should -Contain 'VCPKG_ROOT=C:\vcpkg'
    }

    It 'should_write_the_configured_vcpkg_root_to_github_env_when_the_libheif_cache_is_cold' {
        $env:LIBHEIF_CACHE_HIT = 'false'
        $env:VCPKG_INSTALLATION_ROOT = 'D:\tools\vcpkg'

        & $script:Script 6>&1 | Out-Null

        Get-Content -LiteralPath $script:GithubEnv | Should -Contain 'VCPKG_ROOT=D:\tools\vcpkg'
    }

    It 'should_still_publish_the_vcpkg_root_when_the_libheif_cache_is_warm' {
        & $script:Script 6>&1 | Out-Null

        Get-Content -LiteralPath $script:GithubEnv | Should -Contain 'VCPKG_ROOT=C:\vcpkg'
    }

    It 'should_warn_and_skip_the_vcpkg_installs_when_the_vcpkg_executable_is_absent' {
        $env:LIBHEIF_CACHE_HIT = 'false'

        $output = @(& $script:Script 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain '::warning::vcpkg.exe not found at C:\vcpkg/vcpkg.exe; skipping libheif/boost/zlib install'
    }

    It 'should_warn_but_continue_when_the_optional_tesseract_install_fails' {
        $env:TESSERACT_CACHE_HIT = 'false'
        Mock choco { throw 'chocolatey failed' } -ParameterFilter { ($args -join ' ') -like '*tesseract*' }

        $output = @(& $script:Script 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain '::warning::Failed to install Tesseract (optional dependency - gem build does not require it)'
    }

    It 'should_retry_a_failing_install_three_times_with_exponential_backoff' {
        $env:LLVM_CACHE_HIT = 'false'
        Mock choco { throw 'chocolatey failed' } -ParameterFilter { ($args -join ' ') -like '*llvm*' }

        $output = @(& $script:Script 6>&1 | ForEach-Object { $_.ToString() })

        Should -Invoke choco -Times 3 -Exactly -ParameterFilter { ($args -join ' ') -like '*llvm*' }
        $output | Should -Contain 'Attempt 3 of 3...'
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 10 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 20 }
        $output | Should -Contain '::warning::Failed to install LLVM/Clang via Chocolatey'
    }

    It 'should_throw_when_cmake_cannot_be_installed_after_three_attempts' {
        $env:CMAKE_CACHE_HIT = 'false'
        Mock choco { throw 'chocolatey failed' } -ParameterFilter { ($args -join ' ') -like '*cmake*' }

        $thrown = { & $script:Script 6>&1 | Out-Null } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly 'Failed to install CMake after 3 attempts'
    }

    It 'should_fail_verification_when_cmake_is_absent_after_installation' {
        Mock Get-Command { throw 'cmake is not recognised' } -ParameterFilter { $Name -eq 'cmake' }

        $thrown = { & $script:Script 6>&1 | Out-Null } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly 'CMake verification failed'
    }

    It 'should_publish_the_resolved_cmake_path_to_github_env' {
        & $script:Script 6>&1 | Out-Null

        Get-Content -LiteralPath $script:GithubEnv | Should -Contain 'CMAKE=C:\Program Files\CMake\bin\cmake.exe'
    }

    It 'should_skip_every_missing_directory_when_configuring_path' {
        $output = @(& $script:Script 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain '  Path not found (skipping): C:\Program Files\CMake\bin'
        $output | Should -Contain '  Path not found (skipping): C:\Program Files\LLVM\bin'
        Get-Content -LiteralPath $script:GithubPath | Should -BeNullOrEmpty
    }

    It 'should_report_tesseract_as_missing_without_failing_the_run' {
        $output = @(& $script:Script 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain '⚠ Tesseract not found on PATH (not required for build)'
        $output | Should -Contain '  Tesseract not found in common locations'
    }

    It 'should_export_tessdata_prefix_when_tesseract_is_found_in_a_common_location' {
        $tesseractExe = 'C:\Program Files\Tesseract-OCR\tesseract.exe'
        $tessdata = 'C:\Program Files\Tesseract-OCR\tessdata'
        # ~keep Forward slashes: Split-Path/Join-Path normalise to the host separator, and the
        # ~keep mock compares on the normalised form.
        $global:VirtualPaths.Add('C:/Program Files/Tesseract-OCR/tesseract.exe') | Out-Null
        $global:VirtualPaths.Add('C:/Program Files/Tesseract-OCR/tessdata') | Out-Null

        $output = @(& $script:Script 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain "  Found Tesseract at: $tesseractExe (not on PATH)"

        # ~keep The exported value is assembled from Split-Path plus Join-Path, both of which
        # emit the host's separator, so it is "...\tessdata" on a Windows runner and
        # ".../tessdata" here. Normalising both sides keeps the assertion exact about the
        # components without asserting the host's slash convention.
        $written = Get-Content -LiteralPath $script:GithubEnv | ForEach-Object { $_ -replace '\\', '/' }
        $written | Should -Contain "TESSDATA_PREFIX=$($tessdata -replace '\\', '/')"
    }

    AfterAll {
        foreach ($entry in $script:SavedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
    }
}
