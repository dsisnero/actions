BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'strip-internal-paths.ps1'

    function New-CrateManifest {
        param([string[]]$Lines)

        $root = Join-Path ([System.IO.Path]::GetTempPath()) "strip-paths-$(New-Guid)"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $manifest = Join-Path $root 'Cargo.toml'
        Set-Content -LiteralPath $manifest -Value $Lines
        [pscustomobject]@{ Root = $root; Manifest = $manifest }
    }
}

Describe 'strip-internal-paths.ps1' {
    AfterEach {
        if ($script:Fixture) {
            Remove-Item -Recurse -Force $script:Fixture.Root -ErrorAction SilentlyContinue
            $script:Fixture = $null
        }
    }

    It 'should_drop_relative_path_key_and_keep_version_for_a_sibling_dependency' {
        $script:Fixture = New-CrateManifest @(
            '[dependencies]'
            'xberg-core = { version = "1.4.0", path = "../xberg-core" }'
        )

        & $script:Script -CrateManifest $script:Fixture.Manifest

        Get-Content -LiteralPath $script:Fixture.Manifest | Should -BeExactly @(
            '[dependencies]'
            'xberg-core = { version = "1.4.0" }'
        )
    }

    It 'should_keep_a_single_separator_when_the_stripped_path_sits_between_two_keys' {
        $script:Fixture = New-CrateManifest @(
            '[dependencies]'
            'xberg-core = { version = "1.4.0", path = "../xberg-core", features = ["ocr"] }'
        )

        & $script:Script -CrateManifest $script:Fixture.Manifest

        Get-Content -LiteralPath $script:Fixture.Manifest | Should -BeExactly @(
            '[dependencies]'
            'xberg-core = { version = "1.4.0", features = ["ocr"] }'
        )
    }

    It 'should_drop_a_leading_path_key_together_with_its_trailing_comma' {
        $script:Fixture = New-CrateManifest @(
            '[dependencies]'
            'xberg-core = { path = "../xberg-core", version = "1.4.0" }'
        )

        & $script:Script -CrateManifest $script:Fixture.Manifest

        # ~keep The doubled space is real output, not a typo: only the trailing comma group
        # matches for a leading `path`, so the evaluator drops the separator entirely and the
        # brace's own space remains. Cosmetic — the result is still valid TOML.
        Get-Content -LiteralPath $script:Fixture.Manifest | Should -BeExactly @(
            '[dependencies]'
            'xberg-core = {  version = "1.4.0" }'
        )
    }

    It 'should_strip_relative_paths_in_dev_and_build_and_target_dependency_tables' {
        $script:Fixture = New-CrateManifest @(
            '[dev-dependencies]'
            'helper = { version = "1", path = "../helper" }'
            '[build-dependencies]'
            'builder = { version = "1", path = "./builder" }'
            "[target.'cfg(windows)'.dependencies]"
            'winhelp = { version = "1", path = "../winhelp" }'
        )

        & $script:Script -CrateManifest $script:Fixture.Manifest

        Get-Content -LiteralPath $script:Fixture.Manifest | Should -BeExactly @(
            '[dev-dependencies]'
            'helper = { version = "1" }'
            '[build-dependencies]'
            'builder = { version = "1" }'
            "[target.'cfg(windows)'.dependencies]"
            'winhelp = { version = "1" }'
        )
    }

    It 'should_strip_a_relative_path_from_a_dependency_sub_table' {
        $script:Fixture = New-CrateManifest @(
            '[dependencies.xberg-core]'
            'version = "1.4.0"'
            'path = "../xberg-core"'
        )

        & $script:Script -CrateManifest $script:Fixture.Manifest

        Get-Content -LiteralPath $script:Fixture.Manifest | Should -BeExactly @(
            '[dependencies.xberg-core]'
            'version = "1.4.0"'
            ''
        )
    }

    It 'should_leave_lib_and_bin_paths_untouched_because_they_are_not_dependency_tables' {
        $original = @(
            '[lib]'
            'path = "src/lib.rs"'
            ''
            '[[bin]]'
            'name = "tool"'
            'path = "src/bin/tool.rs"'
        )
        $script:Fixture = New-CrateManifest $original

        & $script:Script -CrateManifest $script:Fixture.Manifest

        Get-Content -LiteralPath $script:Fixture.Manifest | Should -BeExactly $original
    }

    It 'should_leave_a_registry_dependency_without_a_path_key_unchanged' {
        $original = @(
            '[dependencies]'
            'serde = { version = "1", features = ["derive"] }'
            'anyhow = "1.0.86"'
        )
        $script:Fixture = New-CrateManifest $original

        & $script:Script -CrateManifest $script:Fixture.Manifest

        Get-Content -LiteralPath $script:Fixture.Manifest | Should -BeExactly $original
    }

    It 'should_stop_stripping_once_a_non_dependency_table_header_is_reached' {
        $script:Fixture = New-CrateManifest @(
            '[dependencies]'
            'xberg-core = { version = "1", path = "../xberg-core" }'
            '[lib]'
            'path = "src/lib.rs"'
        )

        & $script:Script -CrateManifest $script:Fixture.Manifest

        Get-Content -LiteralPath $script:Fixture.Manifest | Should -BeExactly @(
            '[dependencies]'
            'xberg-core = { version = "1" }'
            '[lib]'
            'path = "src/lib.rs"'
        )
    }

    It 'should_be_a_no_op_when_run_a_second_time_on_an_already_stripped_manifest' {
        $script:Fixture = New-CrateManifest @(
            '[dependencies]'
            'xberg-core = { version = "1.4.0", path = "../xberg-core" }'
        )

        & $script:Script -CrateManifest $script:Fixture.Manifest
        $afterFirst = Get-Content -LiteralPath $script:Fixture.Manifest
        & $script:Script -CrateManifest $script:Fixture.Manifest

        Get-Content -LiteralPath $script:Fixture.Manifest | Should -BeExactly $afterFirst
    }

    It 'should_leave_lines_without_the_path_substring_untouched_inside_a_dependency_table' {
        $original = @(
            '[dependencies]'
            '# a sibling crate used to live here'
            'serde = "1"'
            ''
        )
        $script:Fixture = New-CrateManifest $original

        & $script:Script -CrateManifest $script:Fixture.Manifest

        Get-Content -LiteralPath $script:Fixture.Manifest | Should -BeExactly $original
    }
}
