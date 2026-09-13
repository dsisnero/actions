BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'windows.ps1'

    # ~keep `cargo` is a native command the script calls by bare name. Pester cannot mock a
    # command it cannot resolve, so a stub function has to exist first; PowerShell resolves
    # functions ahead of executables, which is what keeps a cargo installed on the host from
    # ever being reached. The stub records nothing itself -- each test replaces it with Mock.
    function cargo { $global:LASTEXITCODE = 0 }

    # ~keep CI runs all nine suites in a single pwsh process, so an environment variable left
    # ~keep behind here decides what the next file sees -- TEMP and USERPROFILE especially,
    # ~keep since [IO.Path]::GetTempPath() reads them. Snapshot on entry, hand back on exit.
    $script:SavedEnvironment = @{}
    foreach ($name in @('USERPROFILE', 'TEMP', 'GITHUB_TOKEN', 'ALEF_ALLOW_UNRELEASED', 'CARGO_INSTALL_ROOT')) {
        $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

Describe 'install-alef windows.ps1' {
    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) "install-alef-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null

        $env:USERPROFILE = Join-Path $script:Root 'home'
        $env:TEMP = $script:Root
        $env:GITHUB_TOKEN = $null
        $env:ALEF_ALLOW_UNRELEASED = $null
        $env:CARGO_INSTALL_ROOT = $null
        $script:BinDir = "$($env:USERPROFILE)\AppData\Local\alef"
        $script:AlefExe = "$script:BinDir\alef.exe"

        # ~keep Every path here is built by string concatenation against a Windows USERPROFILE,
        # so the filesystem cmdlets are mocked rather than left to create backslash-named files
        # on this host. The path strings themselves are what the assertions check.
        Mock New-Item { }
        Mock Move-Item { }
        Mock Remove-Item { }
        Mock Expand-Archive { }
        Mock Invoke-WebRequest { }
        Mock Test-Path { $true }
        Mock Get-ChildItem { [pscustomobject]@{ FullName = "$script:BinDir\extract\alef.exe" } }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Users\runner\.cargo\bin\cargo.exe' } }
        Mock cargo { $global:LASTEXITCODE = 0 }
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue
        $env:GITHUB_TOKEN = $null
        $env:ALEF_ALLOW_UNRELEASED = $null
        $env:CARGO_INSTALL_ROOT = $null
        $global:LASTEXITCODE = 0
    }

    It 'should_throw_usage_error_when_the_install_ref_is_empty' {
        $thrown = { & $script:Script '' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly 'Usage: windows.ps1 <installRef>'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'should_download_the_msvc_release_archive_for_a_pinned_version' {
        $output = & $script:Script '1.4.0'

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://github.com/xberg-io/alef/releases/download/v1.4.0/alef-x86_64-pc-windows-msvc.zip'
        }
        Should -Invoke cargo -Times 0 -Exactly
        $output | Should -BeExactly "Alef is ready at $script:AlefExe"
    }

    It 'should_move_the_extracted_executable_to_the_install_location' {
        & $script:Script '1.4.0' | Out-Null

        Should -Invoke Move-Item -Times 1 -Exactly -ParameterFilter {
            $Destination -eq $script:AlefExe
        }
    }

    It 'should_look_up_the_release_through_the_api_when_the_direct_download_fails' {
        Mock Invoke-WebRequest { throw '404 Not Found' } -ParameterFilter {
            $Uri -like '*alef-x86_64-pc-windows-msvc.zip'
        }
        Mock Invoke-RestMethod {
            [pscustomobject]@{ assets = @(
                    [pscustomobject]@{ name = 'alef-x86_64-unknown-linux-gnu.tar.gz'; browser_download_url = 'https://example.invalid/linux.tar.gz' }
                    [pscustomobject]@{ name = 'alef-x86_64-pc-windows-gnu.zip'; browser_download_url = 'https://example.invalid/windows.zip' }
                ) }
        }

        & $script:Script '1.4.0' | Out-Null

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.com/repos/xberg-io/alef/releases/tags/v1.4.0'
        }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://example.invalid/windows.zip'
        }
        Should -Invoke cargo -Times 0 -Exactly
    }

    It 'should_send_a_bearer_authorization_header_on_the_release_api_lookup' {
        $env:GITHUB_TOKEN = 'secret-token'
        Mock Invoke-WebRequest { throw '404 Not Found' } -ParameterFilter {
            $Uri -like '*alef-x86_64-pc-windows-msvc.zip'
        }
        Mock Invoke-RestMethod {
            [pscustomobject]@{ assets = @(
                    [pscustomobject]@{ name = 'alef-windows.zip'; browser_download_url = 'https://example.invalid/windows.zip' }
                ) }
        }

        & $script:Script '1.4.0' | Out-Null

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Headers['Authorization'] -eq 'Bearer secret-token' -and
            $Headers['X-GitHub-Api-Version'] -eq '2022-11-28'
        }
    }

    It 'should_build_from_source_when_the_release_has_no_windows_asset' {
        Mock Invoke-WebRequest { throw '404 Not Found' } -ParameterFilter {
            $Uri -like '*alef-x86_64-pc-windows-msvc.zip'
        }
        Mock Invoke-RestMethod {
            [pscustomobject]@{ assets = @(
                    [pscustomobject]@{ name = 'alef-x86_64-apple-darwin.tar.gz'; browser_download_url = 'https://example.invalid/mac.tar.gz' }
                ) }
        }

        $output = @(& $script:Script '1.4.0' 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain 'Falling back to source build...'
        Should -Invoke cargo -Times 1 -Exactly -ParameterFilter {
            ($args -join ' ') -eq 'install --git https://github.com/xberg-io/alef --tag v1.4.0 --locked --force alef'
        }
    }

    It 'should_build_from_the_main_branch_when_the_install_ref_is_main' {
        $output = @(& $script:Script 'main' 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain 'Building alef from main branch via cargo install...'
        Should -Invoke cargo -Times 1 -Exactly -ParameterFilter {
            ($args -join ' ') -eq 'install --git https://github.com/xberg-io/alef --branch main --locked --force alef'
        }
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'should_set_cargo_install_root_to_the_alef_bin_directory_before_building' {
        & $script:Script 'main' | Out-Null

        $env:CARGO_INSTALL_ROOT | Should -BeExactly $script:BinDir
    }

    It 'should_throw_when_a_pinned_tag_cannot_be_built_and_unreleased_is_not_allowed' {
        Mock Invoke-WebRequest { throw '404 Not Found' }
        Mock Invoke-RestMethod { throw 'no such release' }
        Mock cargo { $global:LASTEXITCODE = 101 }

        $thrown = { & $script:Script '9.9.9' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly 'alef v9.9.9 could not be installed: no release archive and no buildable tag v9.9.9 in xberg-io/alef. The pinned alef version is not released - cut the release, correct the pin in alef.toml, or opt in to an unpinned build with allow-unreleased: true (or version: main).'
        Should -Invoke cargo -Times 1 -Exactly
    }

    It 'should_build_an_unpinned_main_binary_when_a_pinned_tag_fails_and_unreleased_is_allowed' {
        $env:ALEF_ALLOW_UNRELEASED = 'true'
        Mock Invoke-WebRequest { throw '404 Not Found' }
        Mock Invoke-RestMethod { throw 'no such release' }
        Mock cargo {
            if (($args -join ' ') -like '*--tag*') { $global:LASTEXITCODE = 101 } else { $global:LASTEXITCODE = 0 }
        }

        $output = @(& $script:Script '9.9.9' 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain '::warning::alef v9.9.9 has no usable tag; allow-unreleased is set, so an unpinned main build is used instead. This binary is NOT v9.9.9.'
        Should -Invoke cargo -Times 1 -Exactly -ParameterFilter {
            ($args -join ' ') -eq 'install --git https://github.com/xberg-io/alef --branch main --locked --force alef'
        }
    }

    It 'should_move_the_cargo_built_executable_out_of_the_cargo_bin_subdirectory' {
        & $script:Script 'main' | Out-Null

        Should -Invoke Move-Item -Times 1 -Exactly -ParameterFilter {
            $Path -eq "$script:BinDir\bin\alef.exe" -and $Destination -eq $script:AlefExe
        }
    }

    It 'should_throw_when_cargo_install_produced_no_executable' {
        Mock Test-Path { $false }

        $thrown = { & $script:Script 'main' } | Should -Throw -PassThru

        $thrown.Exception.Message | Should -BeExactly "cargo install did not produce alef.exe at $script:BinDir\bin\alef.exe"
    }

    It 'should_fall_back_to_a_source_build_when_the_archive_contained_no_alef_executable' {
        Mock Get-ChildItem { $null }

        # ~keep The extraction failure is not fatal: the script's outer catch turns any release
        # failure into a source build, so the observable behaviour is the fallback, not a throw.
        $output = @(& $script:Script '1.4.0' 6>&1 | ForEach-Object { $_.ToString() })

        $output | Should -Contain "Release download failed: alef.exe not found in extracted archive at $script:BinDir\extract"
        $output | Should -Contain 'Falling back to source build...'
        Should -Invoke cargo -Times 1 -Exactly -ParameterFilter {
            ($args -join ' ') -eq 'install --git https://github.com/xberg-io/alef --tag v1.4.0 --locked --force alef'
        }
    }

    AfterAll {
        foreach ($entry in $script:SavedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
    }
}
