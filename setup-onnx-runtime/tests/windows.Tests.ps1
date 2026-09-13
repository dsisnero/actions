BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'windows.ps1'

    function New-OrtLayout {
        param(
            [string]$ExtractRoot,
            [string]$ArchId = 'x64',
            [string]$Version = '1.20.1',
            [switch]$WithoutLibDirectory,
            [switch]$WithoutLibFiles,
            [switch]$WithoutDlls
        )

        $root = Join-Path $ExtractRoot "onnxruntime-win-$ArchId-$Version"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        if ($WithoutLibDirectory) { return $root }

        $lib = Join-Path $root 'lib'
        New-Item -ItemType Directory -Path $lib -Force | Out-Null
        if (-not $WithoutLibFiles) {
            Set-Content -LiteralPath (Join-Path $lib 'onnxruntime.lib') -Value 'lib'
        }
        if (-not $WithoutDlls) {
            Set-Content -LiteralPath (Join-Path $lib 'onnxruntime.dll') -Value 'dll'
        }
        return $root
    }

    # ~keep CI runs all nine suites in a single pwsh process, so an environment variable left
    # ~keep behind here decides what the next file sees -- TEMP and USERPROFILE especially,
    # ~keep since [IO.Path]::GetTempPath() reads them. Snapshot on entry, hand back on exit.
    $script:SavedEnvironment = @{}
    foreach ($name in @('TEMP', 'GITHUB_WORKSPACE', 'GITHUB_ENV', 'RUNNER_ARCH', 'RUSTFLAGS', 'LIB', 'LIBRARY_PATH')) {
        $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

Describe 'setup-onnx-runtime windows.ps1' {
    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) "onnx-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:Workspace = Join-Path $script:Root 'workspace'
        New-Item -ItemType Directory -Path $script:Workspace -Force | Out-Null
        $script:GithubEnv = Join-Path $script:Root 'github-env'
        Set-Content -LiteralPath $script:GithubEnv -Value @()

        $env:TEMP = $script:Root
        $env:GITHUB_WORKSPACE = $script:Workspace
        $env:GITHUB_ENV = $script:GithubEnv
        $env:RUNNER_ARCH = 'X64'
        $env:RUSTFLAGS = $null
        $env:LIB = $null
        $env:LIBRARY_PATH = $null
        $script:ExtractRoot = Join-Path $env:TEMP 'onnxruntime'

        # ~keep The action runs this through `shell: pwsh`, where GitHub prepends
        # $ErrorActionPreference = 'stop'. The script sets no preference of its own, so the
        # ambient value decides whether its Write-Error calls are terminating. Reproducing the
        # runner's value here is what makes the error-path assertions faithful.
        $ErrorActionPreference = 'Stop'

        Mock Invoke-WebRequest { }
        Mock Expand-Archive { }
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue
        $env:RUSTFLAGS = $null
        $env:LIB = $null
        $env:LIBRARY_PATH = $null
    }

    It 'should_throw_usage_error_when_the_version_argument_is_missing' {
        $thrown = { & $script:Script } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly 'Usage: windows.ps1 <ortVersion> <destDir> [archId] [strategy]'
    }

    It 'should_throw_usage_error_when_the_destination_argument_is_missing' {
        $thrown = { & $script:Script '1.20.1' '' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly 'Usage: windows.ps1 <ortVersion> <destDir> [archId] [strategy]'
    }

    It 'should_download_the_x64_archive_when_the_cache_is_cold' {
        $ErrorActionPreference = 'Continue'

        & $script:Script '1.20.1' 'ort' 2>&1 | Out-Null

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/microsoft/onnxruntime/releases/download/v1.20.1/onnxruntime-win-x64-1.20.1.zip'
        }
    }

    It 'should_download_the_arm64_archive_when_the_arch_id_argument_says_arm64' {
        $ErrorActionPreference = 'Continue'

        & $script:Script '1.20.1' 'ort' 'ARM64' 2>&1 | Out-Null

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/microsoft/onnxruntime/releases/download/v1.20.1/onnxruntime-win-arm64-1.20.1.zip'
        }
    }

    It 'should_fall_back_to_runner_arch_when_no_arch_id_argument_is_given' {
        $ErrorActionPreference = 'Continue'
        $env:RUNNER_ARCH = 'ARM64'

        & $script:Script '1.20.1' 'ort' 2>&1 | Out-Null

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/microsoft/onnxruntime/releases/download/v1.20.1/onnxruntime-win-arm64-1.20.1.zip'
        }
    }

    It 'should_treat_any_non_arm64_architecture_as_x64' {
        $ErrorActionPreference = 'Continue'

        & $script:Script '1.20.1' 'ort' 'ppc64le' 2>&1 | Out-Null

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/microsoft/onnxruntime/releases/download/v1.20.1/onnxruntime-win-x64-1.20.1.zip'
        }
    }

    It 'should_skip_the_download_when_the_extracted_runtime_is_already_cached' {
        New-OrtLayout -ExtractRoot $script:ExtractRoot | Out-Null

        $output = @(& $script:Script '1.20.1' 'ort' 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain 'Cache hit: Using cached ONNX Runtime 1.20.1'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'should_fail_when_the_extracted_runtime_has_no_lib_directory' {
        New-OrtLayout -ExtractRoot $script:ExtractRoot -WithoutLibDirectory | Out-Null
        $expectedLib = Join-Path (Join-Path $script:ExtractRoot 'onnxruntime-win-x64-1.20.1') 'lib'

        $thrown = { & $script:Script '1.20.1' 'ort' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly "ERROR: ONNX Runtime lib directory missing at $expectedLib"
    }

    It 'should_fail_when_the_lib_directory_contains_no_library_files' {
        New-OrtLayout -ExtractRoot $script:ExtractRoot -WithoutLibFiles | Out-Null
        $expectedLib = Join-Path (Join-Path $script:ExtractRoot 'onnxruntime-win-x64-1.20.1') 'lib'

        $thrown = { & $script:Script '1.20.1' 'ort' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly "ERROR: No ONNX Runtime library files found in $expectedLib"
    }

    It 'should_fail_when_no_runtime_dlls_are_found_anywhere_under_the_runtime_root' {
        $root = New-OrtLayout -ExtractRoot $script:ExtractRoot -WithoutDlls

        $thrown = { & $script:Script '1.20.1' 'ort' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly "ERROR: No ONNX Runtime runtime DLLs found under $root"
    }

    It 'should_copy_the_libraries_and_dlls_into_a_relative_destination_under_the_workspace' {
        New-OrtLayout -ExtractRoot $script:ExtractRoot | Out-Null

        & $script:Script '1.20.1' 'ort-dest' | Out-Null

        $dest = Join-Path $script:Workspace 'ort-dest'
        (Get-ChildItem -Path $dest | Select-Object -ExpandProperty Name | Sort-Object) |
            Should -BeExactly @('onnxruntime.dll', 'onnxruntime.lib')
    }

    It 'should_copy_into_an_absolute_destination_without_prefixing_the_workspace' {
        New-OrtLayout -ExtractRoot $script:ExtractRoot | Out-Null
        $dest = Join-Path $script:Root 'absolute-dest'

        & $script:Script '1.20.1' $dest | Out-Null

        (Get-ChildItem -Path $dest | Select-Object -ExpandProperty Name | Sort-Object) |
            Should -BeExactly @('onnxruntime.dll', 'onnxruntime.lib')
    }

    It 'should_write_the_system_strategy_environment_by_default' {
        New-OrtLayout -ExtractRoot $script:ExtractRoot | Out-Null
        $ortLib = Join-Path (Join-Path $script:ExtractRoot 'onnxruntime-win-x64-1.20.1') 'lib'
        $dest = Join-Path $script:Workspace 'ort'

        & $script:Script '1.20.1' 'ort' | Out-Null

        $written = Get-Content -LiteralPath $script:GithubEnv
        $written | Should -Contain "ORT_LIB_LOCATION=$ortLib"
        $written | Should -Contain 'ORT_PREFER_DYNAMIC_LINK=1'
        $written | Should -Contain 'ORT_SKIP_DOWNLOAD=1'
        $written | Should -Contain 'ORT_STRATEGY=system'
        $written | Should -Contain "ORT_DYLIB_PATH=$dest\onnxruntime.dll"
        $written | Should -Contain "RUSTFLAGS=-L $ortLib"
    }

    It 'should_omit_the_system_only_variables_for_the_bundled_strategy' {
        New-OrtLayout -ExtractRoot $script:ExtractRoot | Out-Null
        $ortLib = Join-Path (Join-Path $script:ExtractRoot 'onnxruntime-win-x64-1.20.1') 'lib'

        $output = @(& $script:Script '1.20.1' 'ort' '' 'bundled' 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain 'Using bundled ORT strategy (Windows) - dynamic linking against pre-downloaded ORT (no static binaries for windows-gnu)'
        $written = Get-Content -LiteralPath $script:GithubEnv
        $written | Should -Contain "ORT_LIB_LOCATION=$ortLib"
        $written | Should -Not -Contain 'ORT_SKIP_DOWNLOAD=1'
        $written | Should -Not -Contain 'ORT_STRATEGY=system'
    }

    It 'should_append_the_library_directory_to_existing_rustflags' {
        New-OrtLayout -ExtractRoot $script:ExtractRoot | Out-Null
        $env:RUSTFLAGS = '-C target-cpu=native'
        $ortLib = Join-Path (Join-Path $script:ExtractRoot 'onnxruntime-win-x64-1.20.1') 'lib'

        & $script:Script '1.20.1' 'ort' | Out-Null

        Get-Content -LiteralPath $script:GithubEnv | Should -Contain "RUSTFLAGS=-C target-cpu=native -L $ortLib"
    }

    AfterAll {
        foreach ($entry in $script:SavedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
    }
}
