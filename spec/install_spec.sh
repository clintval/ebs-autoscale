# shellcheck shell=bash
Describe 'install.sh argument handling and config rendering'
  run_install() {
    EBS_AUTOSCALE_RENDER_ONLY=1 EBS_AUTOSCALE_CONFIG_FILE="$CFG" \
      sh "$(script_path sbin/install.sh)" "$@"
  }
  setup() { CFG="${SHELLSPEC_TMPBASE}/cfg.json"; rm -f "$CFG"; }
  Before 'setup'

  It 'prints help and exits without root or an instance'
    When run sh "$(script_path sbin/install.sh)" --help
    The status should be success
    The output should include 'Install ebs-autoscale'
  End

  # btrfs is unavailable on AL2023, so it must fail loudly rather than silently
  # falling through to LVM as upstream did.
  It 'rejects a btrfs filesystem with an explanatory message'
    When call run_install -f btrfs
    The status should be failure
    The stderr should include 'Only lvm.ext4'
  End

  It 'accepts lvm.ext4 and renders the config'
    When call run_install -m /scratch -s 500 -f lvm.ext4 -t gp3 --volume-iops 4000 --volume-throughput 250
    The status should be success
    The stderr should include 'rendered config'
    The file "$CFG" should be exist
  End

  It 'normalizes a trailing-slash mountpoint'
    When call run_install -m /scratch/
    The status should be success
    The stderr should include 'rendered config'
    The contents of file "$CFG" should include '"mountpoint": "/scratch"'
  End

  # A leftover %%PLACEHOLDER%% means a rename fell out of sync (the throughput
  # typo class); the rendered config must be complete and valid.
  It 'renders valid JSON with no placeholders remaining'
    When call run_install -m /scratch -f lvm.ext4
    The status should be success
    The stderr should include 'rendered config'
    The contents of file "$CFG" should not include '%%'
    Assert valid_json "$(cat "$CFG")"
  End

  Describe '--min-free-space'
    It 'renders the given free-space floor'
      When call run_install --min-free-space 500
      The status should be success
      The stderr should include 'rendered config'
      The contents of file "$CFG" should include '"min_free_space": "500"'
    End

    It 'renders 0 (off) by default'
      When call run_install
      The status should be success
      The stderr should include 'rendered config'
      The contents of file "$CFG" should include '"min_free_space": "0"'
    End

    It 'keeps the default utilization threshold alongside it'
      When call run_install --min-free-space 500
      The status should be success
      The stderr should include 'rendered config'
      The contents of file "$CFG" should include '"initial_utilization_threshold": "50"'
    End

    It 'fails when combined with --initial-utilization-threshold'
      When call run_install --initial-utilization-threshold 60 --min-free-space 500
      The status should be failure
      The stderr should include 'error:'
      The stderr should include '--initial-utilization-threshold'
      The stderr should include '--min-free-space'
      The file "$CFG" should not be exist
    End

    It 'fails when combined with --initial-utilization-threshold in either order'
      When call run_install --min-free-space 500 --initial-utilization-threshold 50
      The status should be failure
      The stderr should include 'error:'
    End

    It 'rejects 0'
      When call run_install --min-free-space 0
      The status should be failure
      The stderr should include 'error:'
    End

    It 'rejects a non-numeric value'
      When call run_install --min-free-space abc
      The status should be failure
      The stderr should include 'error:'
      The file "$CFG" should not be exist
    End

    It 'rejects a negative value'
      When call run_install --min-free-space -5
      The status should be failure
      The stderr should include 'error:'
    End

    It 'rejects a decimal value'
      When call run_install --min-free-space 1.5
      The status should be failure
      The stderr should include 'error:'
    End

    It 'rejects an empty value'
      When call run_install --min-free-space ''
      The status should be failure
      The stderr should include 'error:'
    End

  End

  It 'still renders --initial-utilization-threshold on its own'
    When call run_install --initial-utilization-threshold 70
    The status should be success
    The stderr should include 'rendered config'
    The contents of file "$CFG" should include '"initial_utilization_threshold": "70"'
    The contents of file "$CFG" should include '"min_free_space": "0"'
  End

  It 'warns but succeeds on the deprecated --imdsv2 flag'
    When call run_install -m /scratch --imdsv2
    The status should be success
    The stderr should include 'rendered config'
    The stderr should include 'deprecated'
  End
End
