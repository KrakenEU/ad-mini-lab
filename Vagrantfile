ENV["VAGRANT_DEFAULT_PROVIDER"] = "vmware_desktop"

# --- Forest topology ---------------------------------------------------------
# Root domain (forest root) lives on DC1. DC2 hosts a CHILD domain
# (out.minilab.local) and WS01 is a workstation joined to that child domain.
# This models the classic modern red-team escalation storyline: foothold in the
# child domain -> Domain Admin of the child -> cross the parent/child trust ->
# Enterprise Admin of the forest root. The parent<->child trust is created
# automatically by Install-ADDSDomain; no manual trust setup is needed.
DOMAIN          = "minilab.local"     # forest root (DC1)
DOMAIN_NETBIOS  = "MINILAB"
CHILD_LABEL     = "out"               # single label of the child domain
CHILD_DOMAIN    = "out.minilab.local" # child domain FQDN (DC2 + WS01)
CHILD_NETBIOS   = "OUT"
# DSRM (Directory Services Restore Mode) password - only used during DC
# promotion, never a login credential for the Administrator account.
DSRM_PASS   = "ImThePr3sident99"
# Local Administrator password. Install-ADDSForest / Install-ADDSDomain promote
# the local Administrator account into each domain's Administrator account,
# keeping this same password - so this is also the admin password for both
# MINILAB\Administrator and OUT\Administrator. Must match config.winrm.password.
ADMIN_PASS  = "ImThePr3sident"

Vagrant.configure("2") do |config|

  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.winrm.username        = "Administrator"
  config.winrm.password        = ADMIN_PASS
  config.winrm.transport       = :plaintext
  config.winrm.basic_auth_only = true
  config.winrm.retry_limit     = 60
  config.winrm.retry_delay     = 15
  # Client OOBE (post-sysprep specialize pass) has been observed taking well
  # over 10 minutes even with VMware Tools/network healthy the whole time -
  # WinRM just isn't enabled yet (SetupComplete.cmd runs at the very end of
  # OOBE). Give it real headroom instead of bailing early.
  config.vm.boot_timeout       = 1800

  # ---------------------------------------------------------------------------
  # DC1
  # ---------------------------------------------------------------------------
  config.vm.define "dc1", primary: true do |dc1|
    dc1.vm.box          = "dc1-box"
    dc1.vm.communicator = "winrm"
    dc1.vm.hostname     = "DC1"

    dc1.vm.provider "vmware_desktop" do |v|
      v.vmx["memsize"]                  = "4096"
      v.vmx["numvcpus"]                 = "2"
      v.vmx["ethernet0.connectionType"] = "custom"
      v.vmx["ethernet0.vnet"]           = "vmnet8"
      v.vmx["ethernet0.virtualdev"]     = "vmxnet3"
      v.vmx["ethernet0.pcislotnumber"] = "192"
      # Fixed MAC for a stable device identity across clones. IP is whatever
      # DHCP hands out - other VMs discover DC1 by NetBIOS name, not IP.
      v.vmx["ethernet0.addressType"]    = "static"
      v.vmx["ethernet0.address"]        = "00:50:56:3A:1B:64"
      v.linked_clone    = false
      v.clone_directory = File.expand_path("lab-vms/dc1", __dir__)
    end

    # Step 1: promote forest root - reboots via scheduled task at the end
    dc1.vm.provision "shell",
      name:            "promote-forest",
      path:            "scripts/dc1-promote-forest.ps1",
      privileged:      true,
      powershell_args: "-ExecutionPolicy Bypass",
      env: {
        "DOMAIN"         => DOMAIN,
        "DOMAIN_NETBIOS" => DOMAIN_NETBIOS,
        "DSRM_PASS"      => DSRM_PASS
      }

    # Step 2: wait for DC1 to come back after reboot, then seed a clean baseline
    # (OUs / users / groups). This is the "clean" directory - NO misconfigs.
    # Intentional misconfigurations are applied separately by seed-misconfigs.ps1
    # so they can be shown and toggled independently in the video series.
    # The winrm retry_limit above gives Vagrant up to 15 minutes to reconnect.
    dc1.vm.provision "shell",
      name:            "seed-baseline",
      path:            "scripts/seed-baseline.ps1",
      privileged:      true,
      powershell_args: "-ExecutionPolicy Bypass",
      env: {
        "DOMAIN" => DOMAIN
      }

    # Step 3: install an Enterprise Root CA (AD CS) + web enrollment. This is
    # the backbone for the modern ADCS attack family (ESC1/ESC8/ESC13/ESC15/
    # ESC16). Forest-wide, so the child domain can enroll too.
    dc1.vm.provision "shell",
      name:            "install-adcs",
      path:            "scripts/dc1-install-adcs.ps1",
      privileged:      true,
      powershell_args: "-ExecutionPolicy Bypass",
      env: {
        "DOMAIN" => DOMAIN
      }
  end

  # ---------------------------------------------------------------------------
  # DC2
  # ---------------------------------------------------------------------------
  config.vm.define "dc2" do |dc2|
    dc2.vm.box          = "dc2-box"
    dc2.vm.communicator = "winrm"
    dc2.vm.hostname     = "DC2"

    dc2.vm.provider "vmware_desktop" do |v|
      v.vmx["memsize"]                  = "4096"
      v.vmx["numvcpus"]                 = "2"
      v.vmx["ethernet0.connectionType"] = "custom"
      v.vmx["ethernet0.vnet"]           = "vmnet8"
      v.vmx["ethernet0.virtualdev"]     = "vmxnet3"
      v.vmx["ethernet0.pcislotnumber"] = "192"
      # Fixed MAC for a stable device identity across clones. IP is whatever
      # DHCP hands out - other VMs discover DC2 by NetBIOS name, not IP.
      v.vmx["ethernet0.addressType"]    = "static"
      v.vmx["ethernet0.address"]        = "00:50:56:3A:1B:65"
      v.linked_clone    = false
      v.clone_directory = File.expand_path("lab-vms/dc2", __dir__)
    end

    # Step 1: promote DC2 as the FIRST DC of a new child domain
    # (out.minilab.local) under the forest root. Reboots at the end.
    dc2.vm.provision "shell",
      name:            "child-domain",
      path:            "scripts/dc2-child-domain.ps1",
      privileged:      true,
      powershell_args: "-ExecutionPolicy Bypass",
      env: {
        "PARENT_DOMAIN"  => DOMAIN,
        "PARENT_NETBIOS" => DOMAIN_NETBIOS,
        "CHILD_LABEL"    => CHILD_LABEL,
        "CHILD_NETBIOS"  => CHILD_NETBIOS,
        "DSRM_PASS"      => DSRM_PASS,
        "ADMIN_PASS"     => ADMIN_PASS
      }

    # Step 2: after reboot, fix up cross-domain DNS resolution and seed a clean
    # baseline (child OUs / users / groups + the low-priv foothold account WS01
    # logs in with). Misconfigs come later, from seed-misconfigs.ps1.
    dc2.vm.provision "shell",
      name:            "seed-child-baseline",
      path:            "scripts/seed-child-baseline.ps1",
      privileged:      true,
      powershell_args: "-ExecutionPolicy Bypass",
      env: {
        "CHILD_DOMAIN"  => CHILD_DOMAIN,
        "CHILD_NETBIOS" => CHILD_NETBIOS,
        "PARENT_DOMAIN" => DOMAIN,
        "ADMIN_PASS"    => ADMIN_PASS
      }
  end

  # ---------------------------------------------------------------------------
  # WS01
  # ---------------------------------------------------------------------------
  config.vm.define "ws01" do |ws01|
    ws01.vm.box          = "ws01-box"
    ws01.vm.communicator = "winrm"
    ws01.vm.hostname     = "WS01"

    ws01.vm.provider "vmware_desktop" do |v|
      v.vmx["memsize"]                  = "4096"
      v.vmx["numvcpus"]                 = "2"
      v.vmx["ethernet0.connectionType"] = "custom"
      v.vmx["ethernet0.vnet"]           = "vmnet8"
      v.vmx["ethernet0.virtualdev"]     = "vmxnet3"
      v.vmx["ethernet0.pcislotnumber"] = "192"
      # Fixed MAC for a stable device identity across clones. IP is whatever
      # DHCP hands out - other VMs discover WS01 by NetBIOS name, not IP.
      v.vmx["ethernet0.addressType"]    = "static"
      v.vmx["ethernet0.address"]        = "00:50:56:3A:1B:6E"
      v.linked_clone    = false
      v.clone_directory = File.expand_path("lab-vms/ws01", __dir__)
    end

    # WS01 joins the CHILD domain (out.minilab.local), discovering DC2 by name.
    ws01.vm.provision "shell",
      name:            "join-domain",
      path:            "scripts/ws01-join-domain.ps1",
      privileged:      true,
      powershell_args: "-ExecutionPolicy Bypass",
      env: {
        "DOMAIN"         => CHILD_DOMAIN,
        "DOMAIN_NETBIOS" => CHILD_NETBIOS,
        "JOIN_DC"        => "DC2",
        "ADMIN_PASS"     => ADMIN_PASS
      }
  end

end