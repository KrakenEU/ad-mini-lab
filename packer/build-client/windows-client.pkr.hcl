packer {
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

variable "iso_path" {
  type    = string
  default = "../isos/windows-client.iso"
}

variable "vmware_tools_iso" {
  type        = string
  default     = "C:\\Program Files (x86)\\VMware\\VMware Workstation\\windows.iso"
  description = "Path to VMware Tools ISO on the host. Default covers standard VMware Workstation installation."
}

variable "output_dir" {
  type    = string
  default = "../output-windows-client"
}

variable "vm_name" {
  type    = string
  default = "windows-client-golden"
}

variable "disk_size_mb" {
  type    = number
  default = 61440
}

variable "memory_mb" {
  type    = number
  default = 4096
}

variable "cpus" {
  type    = number
  default = 2
}

variable "admin_password" {
  type      = string
  default   = "ImThePr3sident"
  sensitive = true
}

variable "winrm_timeout" {
  type    = string
  default = "90m"
}

source "vmware-iso" "windows_client" {
  vm_name       = var.vm_name
  guest_os_type = "windows9-64"

  iso_url      = var.iso_path
  iso_checksum = "none"

  disk_size         = var.disk_size_mb
  disk_adapter_type = "lsisas1068"

  memory = var.memory_mb
  cpus   = var.cpus

  firmware = "bios"

  boot_wait    = "6s"
  boot_command = ["<spacebar>"]

  floppy_files = ["../answer-files/client/autounattend.xml"]

  network              = "vmnet8"
  network_adapter_type = "vmxnet3"

  output_directory = var.output_dir
  skip_compaction  = false

  winrm_host     = "10.10.10.11"
  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_password
  winrm_timeout  = var.winrm_timeout
  winrm_insecure = true
  winrm_use_ssl  = false

  # Sysprep is launched HERE, as the shutdown_command, not from a provisioner.
  # Packer only waits for the VM to power itself off if a shutdown_command is
  # set; with none it force-halts the instant the last provisioner returns,
  # killing the detached sysprep task mid-generalize so the image is never
  # actually generalized (clones keep the machine SID, hostname and static IP).
  # See windows-server.pkr.hcl for the full story - it bit the server image
  # hard, because two clones of it (dc1 + dc2) then shared a SID and DC2 could
  # not authenticate to DC1 once DC1 was promoted.
  shutdown_command = "schtasks /Run /TN packer-sysprep"
  shutdown_timeout = "30m"

  vmx_data = {
    "mks.enable3d"           = "FALSE"
    "msg.autoAnswer"         = "TRUE"
    "ulm.disableMitigations" = "TRUE"
    "usb.present"            = "TRUE"
    "ehci.present"           = "TRUE"
    "ethernet0.addresstype"  = "static"
    "ethernet0.address"      = "00:50:56:3A:1B:2D"
  }
}

build {
  name    = "windows-client-golden"
  sources = ["source.vmware-iso.windows_client"]

  provisioner "powershell" {
    inline = [
      "Write-Host '[Packer] WinRM connection OK'",
      "$os = Get-CimInstance Win32_OperatingSystem",
      "Write-Host ('[Packer] OS: ' + $os.Caption + ' ' + $os.Version)",
      "Write-Host ('[Packer] Hostname: ' + $env:COMPUTERNAME)"
    ]
  }

  # Disable Windows Update before sysprep. A pending/in-progress update at
  # generalize time re-runs (or resumes) on every single clone's first boot
  # - "This might take a few minutes / Don't turn off your PC" - which can
  # hang for tens of minutes on every `vagrant up`, not just once.
  provisioner "powershell" {
    inline = [
      "Write-Host '[Packer] Disabling Windows Update service...'",
      "Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue",
      "Set-Service -Name wuauserv -StartupType Disabled",
      "Write-Host '[Packer] Windows Update service disabled'"
    ]
  }

  provisioner "file" {
    source      = var.vmware_tools_iso
    destination = "C:\\Windows\\Temp\\vmware-tools.iso"
  }

  # Helper script that runs the installer and drops a completion marker.
  # Launched via a detached scheduled task so the install survives the
  # WinRM connection blip caused by the vmxnet3 driver reload mid-install.
  provisioner "file" {
    source      = "../../scripts/vmtools-install.cmd"
    destination = "C:\\Windows\\Temp\\vmtools-install.cmd"
  }

  # Mount the uploaded ISO, stage the installer locally, and launch it detached
  provisioner "powershell" {
    inline = [
      "Write-Host '[Packer] Mounting VMware Tools ISO...'",
      "$iso = 'C:\\Windows\\Temp\\vmware-tools.iso'",
      "$mount = Mount-DiskImage -ImagePath $iso -PassThru",
      "$drive = ($mount | Get-Volume).DriveLetter",
      "Write-Host ('[Packer] VMware Tools mounted at ' + $drive + ':')",
      "$root = $drive + ':\\'",
      "$setupItem = Get-ChildItem $root -Filter 'setup*.exe' -Recurse | Select-Object -First 1",
      "if (-not $setupItem) { Write-Error 'No setup.exe found on VMware Tools ISO'; exit 1 }",
      "Write-Host ('[Packer] Found installer: ' + $setupItem.FullName)",
      "Copy-Item $setupItem.FullName 'C:\\Windows\\Temp\\vmtools-setup.exe' -Force",
      "Dismount-DiskImage -ImagePath $iso | Out-Null",
      "Remove-Item $iso -Force -ErrorAction SilentlyContinue",
      "Remove-Item 'C:\\Windows\\Temp\\vmtools-done.txt' -Force -ErrorAction SilentlyContinue",
      "Write-Host '[Packer] Scheduling VMware Tools install as a detached task'",
      "schtasks /Create /TN vmtools-install /TR \"C:\\Windows\\Temp\\vmtools-install.cmd\" /SC ONCE /ST 23:59 /RU SYSTEM /RL HIGHEST /F",
      "schtasks /Run /TN vmtools-install",
      "Write-Host '[Packer] VMware Tools install task launched'"
    ]
  }

  # Poll for completion in a separate command: if WinRM drops mid-poll
  # (network blip from the driver reload), the retry just checks again.
  # Logs the scheduled task's live status every 30s so a timeout is diagnosable.
  provisioner "powershell" {
    inline = [
      "Write-Host '[Packer] Waiting for VMware Tools install to finish...'",
      "$deadline = (Get-Date).AddMinutes(20)",
      "$lastLog = Get-Date",
      "function Test-ToolsDone { (Test-Path 'C:\\Windows\\Temp\\vmtools-done.txt') -or [bool](Get-Process -Name vmtoolsd -ErrorAction SilentlyContinue) }",
      "while (-not (Test-ToolsDone)) {",
      "  if (Test-Path 'C:\\Windows\\Temp\\vmtools-failed.txt') {",
      "    Write-Error 'VMware Tools installer was missing - see vmtools-failed.txt'",
      "    exit 1",
      "  }",
      "  if ((Get-Date) -gt $deadline) {",
      "    Write-Host '[Packer] TIMEOUT - dumping diagnostics'",
      "    schtasks /Query /TN vmtools-install /V /FO LIST 2>&1 | Write-Host",
      "    Get-Process | Where-Object { $_.Path -like '*vmtools*' -or $_.Path -like '*VMware*' } | Format-Table Name,Id,Path -AutoSize | Out-String | Write-Host",
      "    Get-ChildItem 'C:\\Windows\\Temp' -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'vmtools*' } | Format-Table Name,Length,LastWriteTime -AutoSize | Out-String | Write-Host",
      "    Write-Error 'Timed out waiting for VMware Tools install'",
      "    exit 1",
      "  }",
      "  if (((Get-Date) - $lastLog).TotalSeconds -ge 30) {",
      "    $status = ((schtasks /Query /TN vmtools-install /FO LIST /V 2>&1) -join ' ')",
      "    Write-Host ('[Packer] still waiting - ' + $status)",
      "    $lastLog = Get-Date",
      "  }",
      "  Start-Sleep -Seconds 5",
      "}",
      "$LASTEXITCODE = 0",
      "Remove-Item 'C:\\Windows\\Temp\\vmtools-done.txt' -Force -ErrorAction SilentlyContinue",
      "Remove-Item 'C:\\Windows\\Temp\\vmtools-setup.exe' -Force -ErrorAction SilentlyContinue",
      "schtasks /Delete /TN vmtools-install /F 2>&1 | Out-Null; $LASTEXITCODE = 0",
      "Write-Host '[Packer] VMware Tools installed successfully'"
    ]
  }

  # Controlled reboot after VMware Tools install
  provisioner "windows-restart" {
    restart_timeout = "10m"
  }

  provisioner "powershell" {
    inline = [
      "New-Item -ItemType Directory -Path 'C:\\Windows\\Setup\\Scripts' -Force | Out-Null"
    ]
  }

  provisioner "file" {
    source      = "../../scripts/SetupComplete.cmd"
    destination = "C:\\Windows\\Setup\\Scripts\\SetupComplete.cmd"
  }

  # Upload the OOBE unattend file so sysprep answers OOBE automatically on clones
  provisioner "file" {
    source      = "../answer-files/unattend-oobe.xml"
    destination = "C:\\Windows\\System32\\Sysprep\\unattend.xml"
  }

  # Strip the cached answer file's FirstLogonCommands before sysprep. Windows
  # copies the original autounattend.xml to C:\Windows\Panther\unattend.xml and
  # sysprep does NOT replace it, so every clone re-processes its oobeSystem pass
  # and re-applies the build's static IP (10.10.10.11) at first logon, clobbering
  # the DHCP reset SetupComplete.cmd just did. Only one clone is made from this
  # image (ws01), so it never collided the way the server image did - but a baked
  # static IP on a clone is wrong regardless, and it would collide the moment a
  # second client clone existed. See windows-server.pkr.hcl for the full story.
  provisioner "powershell" {
    inline = [
      "Write-Host '[Packer] Removing cached FirstLogonCommands so clones do not re-apply the build static IP'",
      "foreach ($p in @('C:\\Windows\\Panther\\unattend.xml','C:\\Windows\\Panther\\Unattend\\unattend.xml')) {",
      "  if (Test-Path $p) {",
      "    [xml]$x = Get-Content $p",
      "    $nodes = @($x.GetElementsByTagName('FirstLogonCommands'))",
      "    foreach ($n in $nodes) { [void]$n.ParentNode.RemoveChild($n) }",
      "    if ($nodes.Count -gt 0) { $x.Save($p); Write-Host ('[Packer] Stripped FirstLogonCommands from ' + $p) }",
      "  }",
      "}",
      "Write-Host '[Packer] Creating detached network reset + sysprep task (run by shutdown_command)'",
      "schtasks /Create /TN packer-sysprep /TR \"cmd /c netsh interface ip set address Ethernet0 dhcp & netsh interface ip set dns Ethernet0 dhcp & C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet /unattend:C:\\Windows\\System32\\Sysprep\\unattend.xml\" /SC ONCE /ST 23:59 /RU SYSTEM /RL HIGHEST /F",
      "Write-Host '[Packer] Sysprep task created'"
    ]
  }
}
