BeforeAll {
    # ~keep Deliberately NOT a call into the script's own ConvertTo-Msys2Path: an expectation
    # ~keep produced by the code under test matches that code however broken it is. This walks
    # ~keep characters where the script uses a regex, so the two cannot share a defect, and
    # ~keep should_translate_a_windows_drive_path_into_its_msys2_equivalent pins both against a
    # ~keep literal C:\ws -> /c/ws. Needed because the temp root carries a drive letter on a
    # ~keep Windows runner and none on POSIX -- these six assertions passed on macOS only
    # ~keep because the conversion was a no-op there, so they asserted nothing about it.
    function ConvertTo-ExpectedMsys2Path {
        param([string]$WindowsPath)
        $forward = $WindowsPath.Replace('\', '/')
        if ($forward.Length -ge 2 -and $forward[1] -eq ':') {
            return '/' + [char]::ToLowerInvariant($forward[0]) + $forward.Substring(2)
        }
        return $forward
    }

    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'windows.ps1'

    # ~keep CI runs all nine suites in a single pwsh process, so an environment variable left
    # ~keep behind here decides what the next file sees -- TEMP and USERPROFILE especially,
    # ~keep since [IO.Path]::GetTempPath() reads them. Snapshot on entry, hand back on exit.
    $script:SavedEnvironment = @{}
    foreach ($name in @('GITHUB_WORKSPACE', 'GITHUB_ENV', 'GITHUB_PATH', 'PKG_CONFIG_PATH', 'CC', 'CXX', 'AR', 'RANLIB', 'PATH')) {
        $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

Describe 'setup-go-cgo-env windows.ps1' {
    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) "go-cgo-$(New-Guid)"
        $script:ExpectedRoot = ConvertTo-ExpectedMsys2Path $script:Root
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'target/release') -Force | Out-Null
        $script:GithubEnv = Join-Path $script:Root 'github-env'
        $script:GithubPath = Join-Path $script:Root 'github-path'
        Set-Content -LiteralPath $script:GithubEnv -Value @()
        Set-Content -LiteralPath $script:GithubPath -Value @()

        $env:GITHUB_WORKSPACE = $script:Root
        $env:GITHUB_ENV = $script:GithubEnv
        $env:GITHUB_PATH = $script:GithubPath
        $env:PKG_CONFIG_PATH = $null

        # ~keep The script both reads and writes these, and Pester runs every test in one
        # process, so a value set by an earlier test would otherwise decide whether a later
        # one writes CC/CXX/AR/RANLIB into GITHUB_ENV.
        $env:CC = $null
        $env:CXX = $null
        $env:AR = $null
        $env:RANLIB = $null
        $script:SavedPath = $env:PATH

        # ~keep Default mock answers from the real filesystem via .NET so that only the
        # Windows-absolute probes below are faked. Pester 6 does not fall back to the real
        # command when no -ParameterFilter matches, it throws, so this default is required.
        Mock Test-Path { [System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path) }
        Mock Test-Path { $false } -ParameterFilter { $Path -like '*x86_64-w64-mingw32-gcc.exe' }

        # ~keep Join-Path resolves the drive qualifier through the PowerShell provider, so the
        # script's own `Join-Path "C:\msys64\mingw64\bin" ...` on line 63 raises
        # DriveNotFoundException on any POSIX host -- the script cannot otherwise be run to
        # completion here at all. [IO.Path]::Combine is the same pure-string join without the
        # drive lookup, and yields byte-identical results to Join-Path for every other path
        # these tests use, on Windows and POSIX alike.
        Mock Join-Path { [System.IO.Path]::Combine($Path, $ChildPath) }
    }

    AfterEach {
        $env:PATH = $script:SavedPath
        $env:CC = $null
        $env:CXX = $null
        $env:AR = $null
        $env:RANLIB = $null
        Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue
    }

    It 'should_write_the_cgo_environment_for_an_existing_ffi_directory' {
        & $script:Script 'target/release' 'crates/xberg-ffi' 'xberg_ffi' | Out-Null

        Get-Content -LiteralPath $script:GithubEnv | Should -BeExactly @(
            "PKG_CONFIG_PATH=$script:ExpectedRoot/crates/xberg-ffi"
            'CGO_ENABLED=1'
            "CGO_CFLAGS=-I$script:ExpectedRoot/crates/xberg-ffi/include"
            "CGO_LDFLAGS=-L$script:ExpectedRoot/target/release"
        )
    }

    It 'should_throw_when_the_ffi_library_directory_is_missing' {
        $thrown = { & $script:Script 'missing' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly "Error: FFI library directory not found: $(Join-Path $script:Root 'missing')"
        Get-Content -LiteralPath $script:GithubEnv | Should -BeNullOrEmpty
    }

    It 'should_fall_back_to_the_default_directories_when_arguments_are_empty' {
        & $script:Script '' '' '' | Out-Null

        Get-Content -LiteralPath $script:GithubEnv | Should -BeExactly @(
            "PKG_CONFIG_PATH=$script:ExpectedRoot/crates/xberg-ffi"
            'CGO_ENABLED=1'
            "CGO_CFLAGS=-I$script:ExpectedRoot/crates/xberg-ffi/include"
            "CGO_LDFLAGS=-L$script:ExpectedRoot/target/release"
        )
    }

    It 'should_prefer_the_windows_gnu_target_directory_when_it_exists' {
        $gnuDir = Join-Path $script:Root 'target/x86_64-pc-windows-gnu/release'
        New-Item -ItemType Directory -Path $gnuDir -Force | Out-Null

        $output = @(& $script:Script 'target/release' 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain "Using Windows GNU target path: $(Join-Path $script:Root 'target/x86_64-pc-windows-gnu/release')"
        Get-Content -LiteralPath $script:GithubEnv | Should -Contain "CGO_LDFLAGS=-L$script:ExpectedRoot/target/x86_64-pc-windows-gnu/release"
    }

    It 'should_translate_a_windows_drive_path_into_its_msys2_equivalent' {
        # ~keep GITHUB_WORKSPACE is a Windows path with a drive letter, which cannot exist on
        # this host, so the two directory probes are faked. The conversion itself -- the
        # behaviour under test -- is pure string handling and runs identically on any OS.
        $env:GITHUB_WORKSPACE = 'C:\ws'
        Mock Test-Path { $false } -ParameterFilter { $Path -like '*x86_64-pc-windows-gnu*' }
        Mock Test-Path { $true } -ParameterFilter { $Path -like 'C:\ws*target/release' }

        & $script:Script 'target/release' 'crates/xberg-ffi' | Out-Null

        Get-Content -LiteralPath $script:GithubEnv | Should -BeExactly @(
            'PKG_CONFIG_PATH=/c/ws/crates/xberg-ffi'
            'CGO_ENABLED=1'
            'CGO_CFLAGS=-I/c/ws/crates/xberg-ffi/include'
            'CGO_LDFLAGS=-L/c/ws/target/release'
        )
    }

    It 'should_append_the_existing_pkg_config_path_after_the_crate_directory' {
        $env:PKG_CONFIG_PATH = '/usr/lib/pkgconfig'

        & $script:Script 'target/release' 'crates/xberg-ffi' | Out-Null

        Get-Content -LiteralPath $script:GithubEnv | Should -Contain "PKG_CONFIG_PATH=$script:ExpectedRoot/crates/xberg-ffi:/usr/lib/pkgconfig"
    }

    It 'should_add_the_ffi_directory_to_github_path' {
        & $script:Script 'target/release' | Out-Null

        Get-Content -LiteralPath $script:GithubPath | Should -BeExactly (Join-Path $script:Root 'target/release')
    }

    It 'should_export_the_mingw_toolchain_when_its_gcc_is_present' {
        Mock Test-Path { $true } -ParameterFilter { $Path -like '*x86_64-w64-mingw32-gcc.exe' }

        $output = @(& $script:Script 'target/release' 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain 'Using MinGW64 toolchain: C:\msys64\mingw64\bin'
        Get-Content -LiteralPath $script:GithubEnv | Should -BeExactly @(
            "PKG_CONFIG_PATH=$script:ExpectedRoot/crates/xberg-ffi"
            'CGO_ENABLED=1'
            "CGO_CFLAGS=-I$script:ExpectedRoot/crates/xberg-ffi/include"
            'CC=x86_64-w64-mingw32-gcc'
            'CXX=x86_64-w64-mingw32-g++'
            'AR=x86_64-w64-mingw32-ar'
            'RANLIB=x86_64-w64-mingw32-ranlib'
            "CGO_LDFLAGS=-L$script:ExpectedRoot/target/release"
        )
        Get-Content -LiteralPath $script:GithubPath | Should -Contain 'C:\msys64\mingw64\bin'
    }

    It 'should_not_export_compiler_variables_when_the_mingw_toolchain_is_absent' {
        & $script:Script 'target/release' | Out-Null

        $written = Get-Content -LiteralPath $script:GithubEnv
        $written | Should -Not -Contain 'CC=x86_64-w64-mingw32-gcc'
        $written | Should -Not -Contain 'RANLIB=x86_64-w64-mingw32-ranlib'
    }

    It 'should_warn_when_the_declared_ffi_header_does_not_exist' {
        $output = @(& $script:Script 'target/release' 'crates/xberg-ffi' 'xberg_ffi' 'include/xberg.h' 6>&1 |
                ForEach-Object { $_.ToString() })

        $output | Should -Contain "Warning: FFI header not found at $(Join-Path $script:Root 'include/xberg.h')"
    }

    It 'should_confirm_the_ffi_header_when_it_exists' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'include') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'include/xberg.h') -Value '#pragma once'

        $output = @(& $script:Script 'target/release' 'crates/xberg-ffi' 'xberg_ffi' 'include/xberg.h' 6>&1 |
                ForEach-Object { $_.ToString() })

        $output | Should -Contain 'FFI header verified at include/xberg.h'
    }

    It 'should_use_the_supplied_crate_directory_for_pkg_config_and_include_paths' {
        & $script:Script 'target/release' 'crates/custom-ffi' | Out-Null

        Get-Content -LiteralPath $script:GithubEnv | Should -BeExactly @(
            "PKG_CONFIG_PATH=$script:ExpectedRoot/crates/custom-ffi"
            'CGO_ENABLED=1'
            "CGO_CFLAGS=-I$script:ExpectedRoot/crates/custom-ffi/include"
            "CGO_LDFLAGS=-L$script:ExpectedRoot/target/release"
        )
    }

    AfterAll {
        foreach ($entry in $script:SavedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
    }
}
