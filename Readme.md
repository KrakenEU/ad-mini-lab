# AD Mini-Lab

A small Active Directory forest you can build from scratch with a single command, made for practicing modern red team tradecraft against a realistic target. It stands up a parent domain, a child domain, an Enterprise CA, and a workstation, then optionally seeds a set of intentional misconfigurations for you to attack.

Nothing ships as a prebuilt VM. You clone the repo and generate your own lab, so the Windows evaluation timers start when you build, not when the repo was published.

## What you get

| VM | Role |
|:---|:---|
| **DC1** | Forest root `minilab.local` and the Enterprise CA (AD CS) |
| **DC2** | Child domain `out.minilab.local` (Windows Server 2025) |
| **WS01** | Windows client joined to `out.minilab.local` |

The three machines share an isolated network (`vmnet8`). They get their addresses from DHCP and find each other by name, so nothing in the lab depends on a fixed IP.

Once seeded, the attack surface covers a full child to forest root escalation: BadSuccessor (dMSA abuse on Server 2025), the AD CS ESC family (ESC1, ESC4, ESC6, ESC9, ESC13, ESC15, ESC16), Shadow Credentials, Resource-Based Constrained Delegation, an over-exposed gMSA, a BloodHound-friendly ACL chain, and a cross-domain group that bridges the child into a privileged root group. Thirteen chains in total.

## Prerequisites

You need VMware Workstation Pro, Vagrant with the `vagrant-vmware-desktop` plugin (and its Vagrant VMware Utility service running), Packer, 7-Zip (used to pack the Vagrant boxes), and two Windows evaluation ISOs. The server ISO must be Windows Server 2025, since the BadSuccessor / dMSA technique needs a 2025 domain controller. Nested virtualization (VT-x or AMD-V) must be enabled, and 32 GB of host RAM is comfortable for running all three VMs at once.

Place the ISOs here:

- `packer/isos/windows-server.iso` (Windows Server evaluation)
- `packer/isos/windows-client.iso` (Windows 11 evaluation)

Packer talks to the build VMs over WinRM, so configure your host's WinRM client once, as Administrator:

```powershell
winrm quickconfig -quiet
winrm set winrm/config/client '@{AllowUnencrypted="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'
winrm set winrm/config/client '@{TrustedHosts="*"}'
```

These only affect outbound connections from your host to the lab. Then validate everything in one go:

```powershell
.\scripts\check-prereqs.ps1
```

Run it as Administrator. It tells you exactly what is missing and the fix for each item.

## Quick start

Two steps, both run as Administrator.

### 1. Build and deploy the lab

From the repo root, on your host:

```powershell
.\scripts\deploy-lab.ps1 -Force
```

This runs the whole pipeline unattended: prerequisite check, both Packer builds, box packaging, and bringing up DC1, DC2, and WS01 with all of their provisioning. A clean build takes roughly 1.5 to 2 hours. If the golden images already exist it reuses them and finishes in 30 to 45 minutes.

### 2. Seed the misconfigurations

From the repo root, on your host:

```powershell
.\scripts\deploy-misconfigs.ps1
```

This pushes the seeding script onto DC1 and runs it there for you, over VMware's guest tools, so you never have to copy anything into the VM. It seeds all thirteen chains across both domains and the CA, and it is idempotent, so running it again is safe. Use `-List` to see the tags, or `-Only badsuccessor,esc13` to seed one technique at a time (useful when filming them individually).

The lab is now live and vulnerable. Log in as the foothold user `OUT\jdoe` on WS01 and work from there.

## Reset the lab

Broke the lab playing? Get back to a fresh, fully-seeded state in one command:

```powershell
.\scripts\reset-lab.ps1
```

It destroys the three VMs, re-clones them from the existing Vagrant boxes, re-provisions the domains, sets the domain-admin passwords, and re-seeds the misconfigurations. This is much faster than a full build, because nothing is rebuilt with Packer. Use `-SkipMisconfigs` for a clean lab, or `-Force` to skip the prompt.

A reset only needs the registered boxes, not the golden images. So once the boxes exist you can delete `packer/output-*` to reclaim around 36 GB, and resets still work. Keep the boxes if you want cheap resets. One caveat: if you delete the golden images, reset with `reset-lab.ps1`, not `deploy-lab.ps1`, since the latter would rebuild them with Packer.

## Bring it up part by part

If you prefer to run the pipeline one stage at a time, or you want to understand each piece:

**1. Check prerequisites**

```powershell
.\scripts\check-prereqs.ps1
```

**2. Detect the network and patch the build configs**

```powershell
.\scripts\detect-vmnet8.ps1
```

Reads your `vmnet8` subnet and writes the matching IPs into the Packer answer files.

**3. Build the golden images, one per OS**

```powershell
cd packer\build-server ; packer init . ; packer build windows-server.pkr.hcl
cd ..\build-client     ; packer init . ; packer build windows-client.pkr.hcl
```

Each build installs Windows unattended, installs VMware Tools, then syspreps the machine into a generalized image.

**4. Package the images as Vagrant boxes**

```powershell
.\scripts\setup-vagrant-boxes.ps1
```

**5. Bring up the VMs (order matters, DC1 first)**

```powershell
vagrant up dc1
vagrant up dc2
vagrant up ws01
```

DC1 promotes the forest root and installs the CA. DC2 creates the child domain and joins the forest. WS01 joins the child domain. Each machine locates the ones it needs by name.

**6. Seed the misconfigurations**

```powershell
.\scripts\deploy-misconfigs.ps1
```

Pushes `seed-misconfigs.ps1` onto DC1 and runs it there. To run the seeding directly on DC1 instead, copy `scripts/seed-misconfigs.ps1` into the VM and run it as a domain administrator.

## Credentials

| Account | Password | Notes |
|:---|:---|:---|
| `MINILAB\Administrator` | `TheKingOfTheHill23` | Root domain admin and Enterprise Admin |
| `OUT\Administrator` | `InsideOut67` | Child domain admin |
| `OUT\jdoe` | `Winter2025!` | Low-priv foothold, log in here on WS01 |
| DSRM | `ImThePr3sident99` | Only used during DC promotion, never a login |

Every seeded user has its own password (a few are weak on purpose, for password-spray practice):

- Root `minilab.local`: alice `Autumn2024!`, bob `Summer2025!`, carol `F1nanceGrp!7`, dave `Pl4tinum!Key`, eve `Spring2024!`, frank `Bl4ckHawk#7`, rootadmin `Str0ng!Vault#9`
- Child `out.minilab.local`: jdoe `Winter2025!`, slin `M4ple!River2`, helpdesk `Fr0ntD3sk!24`, childadm `Gr4nite!Peak8`

The whole build and Vagrant's WinRM run on the local Administrator password `ImThePr3sident` (still the local admin on WS01). The two domain Administrator accounts are switched to the passwords above as the very last step of `deploy-lab.ps1`, once nothing else needs to reconnect. One side effect: after that switch, `vagrant reload` or `vagrant provision` on a DC will fail to reconnect (its WinRM password no longer matches), so manage a finished lab over RDP or the console rather than re-provisioning it.

## Notes

The base build is clean on its own. Every intentional weakness lives in `seed-misconfigs.ps1` and nowhere else, so you can stand up a normal forest and add the attack surface only when you want it.

Windows Defender is left enabled on purpose. Enumeration over LDAP works fine, but running the offensive tools needs your own evasion, which is part of the exercise.

## License

See `LICENSE`.
