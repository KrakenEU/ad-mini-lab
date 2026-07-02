\# AD Mini-Lab



A one-command-deployable Active Directory lab, built as a foundation for offensive/defensive AD security research (delegations, ACLs, AdminSDHolder, etc).



Instead of shipping a pre-built VM or `.ovf`, this repo automates the full build from scratch: anyone who clones it generates their own lab, with their own Windows evaluation period starting at build time, not at the time the repo was published.



\## Architecture



| VM | Role | IP | Specs |

|---|---|---|---|

| DC1 | First DC, forest/domain owner | 192.168.56.10 | 2 vCPU / 4GB RAM |

| DC2 | Second DC, replica | 192.168.56.11 | 2 vCPU / 4GB RAM |

| WS01 | Domain-joined Windows client | 192.168.56.20 | 2 vCPU / 4GB RAM |



Internal host-only network (dedicated `vmnet`), static IPs, DNS pointing to DC1 (and later DC2). No dependency on DHCP.



\## How the pipeline works



1\. \*\*Packer\*\* builds generalized "golden" images (one per OS: Windows Server, Windows client) from an unattended install via `autounattend.xml`.

2\. \*\*Vagrant\*\* clones those golden images into the lab's three VMs and orchestrates boot order and provisioning:

&#x20;  - DC1 promotes the forest/domain.

&#x20;  - DC2 waits until DC1 is operational, then joins as an additional DC.

&#x20;  - WS01 joins the domain.

&#x20;  - Finally, DC1 runs a seeding script that creates OUs, users, groups, and a couple of intentionally misconfigured delegations as a starting point for testing.



Seeding is kept deliberately minimal in this first version. More specific cases (AdminSDHolder, CREATOR\_OWNER inheritance, etc.) will be added incrementally later on.



\## Repository structure



```

ad-mini-lab/

├── packer/

│   ├── windows-server.pkr.hcl

│   ├── windows-client.pkr.hcl

│   ├── http/

│   │   ├── autounattend-server.xml

│   │   └── autounattend-client.xml

│   └── iso/                  # downloaded ISOs go here (not included in the repo)

├── Vagrantfile

├── scripts/

│   ├── check-prereqs.ps1

│   ├── dc1-promote-forest.ps1

│   ├── dc2-join-as-dc.ps1

│   ├── ws01-join-domain.ps1

│   └── seed-delegations.ps1

└── README.md

```



\## Prerequisites



Install the following components in this order; each one depends on the previous one already being in place.



\### 1. VMware Workstation Pro



Free for personal use. Download it from the official Broadcom/VMware site and register for the free license (even though it's "free", the installer may still prompt for a key if you haven't registered).



\### 2. Vagrant



Official installer from \[developer.hashicorp.com/vagrant](https://developer.hashicorp.com/vagrant). Use the latest stable release.



\### 3. The `vagrant-vmware-desktop` plugin



```powershell

vagrant plugin install vagrant-vmware-desktop

```



This plugin also installs, as a separate step, the \*\*Vagrant VMware Utility\*\* (a system service on Windows). Without that service running, Vagrant will fail with unclear communication errors when trying to bring up the VMs. Verify the service is active:



```powershell

Get-Service vagrant-vmware-utility

```



If it doesn't appear or is stopped, reboot after installation or start it manually from `services.msc`.



\### 4. Packer



Official installer from \[developer.hashicorp.com/packer](https://developer.hashicorp.com/packer).



\### 5. Evaluation ISOs



Microsoft doesn't allow automated direct downloads (it sits behind a form), so this step is manual:



\- \*\*Windows Server (evaluation)\*\*: download it from the \[Microsoft Evaluation Center](https://www.microsoft.com/evalcenter/) and place it at `packer/iso/windows-server.iso`.

\- \*\*Windows 10/11 (evaluation)\*\*: same evaluation center, place it at `packer/iso/windows-client.iso`.



\### Hardware requirements



\- Nested virtualization enabled in BIOS/UEFI (VT-x or AMD-V).

\- Minimum recommended: 16GB of host RAM (32GB to comfortably run all 3 VMs at once).

\- Disk space: budget for 60-80GB between ISOs and virtual disks.



\### Automated verification



Before launching anything, run the prerequisite-check script:



```powershell

.\\scripts\\check-prereqs.ps1

```



This script validates that all of the above software is installed and properly configured, and tells you exactly what's missing before you waste time on a `vagrant up` that's going to fail halfway through.



\## Quick start



```powershell

.\\scripts\\check-prereqs.ps1

packer build packer\\windows-server.pkr.hcl

packer build packer\\windows-client.pkr.hcl

vagrant up

```



The first full `vagrant up` (image builds + provisioning of all 3 VMs) can easily take 1-2 hours depending on your hardware.



\## Project status



This lab is a work in progress, documented alongside a video series. Delegation seeding will be expanded with specific cases (AdminSDHolder, ACE inheritance, etc.) in later commits.



\## License



See `LICENSE`.

