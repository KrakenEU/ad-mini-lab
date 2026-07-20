#Requires -Version 5.1
<#
.SYNOPSIS
    Seeds the AD Mini-Lab with a curated set of MODERN (2024-2026) Active
    Directory misconfigurations for red-team training. Run this AFTER the base
    lab is up (deploy-lab.ps1) - it turns the clean directory into a vulnerable
    playground. This is the "attack surface" companion to the base build.

.DESCRIPTION
    Run this ON DC1 (forest root, Enterprise Admin) - it seeds both the root
    domain (minilab.local) and, via -Server, the child domain
    (out.minilab.local), plus the forest-wide Enterprise CA.

    Every misconfiguration is a self-contained, idempotent function tagged for
    selective seeding. Each carries a header describing the ATTACK, the TOOL you
    would use, and the intended EXPLOITATION PATH - so the repo doubles as a
    walkthrough for the video series.

    THE INTENDED STORYLINE (child -> forest root escalation):
      foothold: OUT\jdoe (low-priv user, logs on at WS01)
        -> one of the child-domain misconfigs below -> child Domain Admin
        -> cross the parent/child trust -> Enterprise Admin of minilab.local

.PARAMETER Only
    Seed only these tags (comma-separated). Great for demoing one technique per
    video. Omit to seed everything. Use -List to see the tags.

.PARAMETER List
    List the available misconfiguration tags and exit.

.EXAMPLE
    .\seed-misconfigs.ps1 -List

.EXAMPLE
    .\seed-misconfigs.ps1 -Only badsuccessor,esc1

.EXAMPLE
    .\seed-misconfigs.ps1
    Seed the whole modern attack surface.
#>
[CmdletBinding()]
param(
    [string[]]$Only,
    [switch]$List
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory

# =============================================================================
# Environment
# =============================================================================
$RootDomain  = (Get-ADDomain).DNSRoot                       # minilab.local
$RootDN      = (Get-ADDomain).DistinguishedName
$ConfigDN    = (Get-ADRootDSE).configurationNamingContext
$ChildDomain = "out.minilab.local"
$ChildDC     = "dc2.$ChildDomain"
$ChildDN     = (Get-ADDomain -Server $ChildDC).DistinguishedName
$FootholdPass = "Winter2025!"   # OUT\jdoe (see seed-child-baseline.ps1)

# Well-known / recon'd schema GUIDs
$G_DMSA        = [guid]"0feb936f-47b3-49f2-9386-1dedc2c23765"  # msDS-DelegatedManagedServiceAccount class
$G_ENROLL      = [guid]"0e10c968-78fb-11d2-90d4-00c04f79dc55"  # Certificate-Enrollment extended right
$G_KEYCREDLINK = [guid]"5b47d60f-6090-40b2-9f37-2a4de88f3063"  # msDS-KeyCredentialLink attribute

# =============================================================================
# Helpers
# =============================================================================
function Resolve-Sid {
    param([Parameter(Mandatory)][string]$Name, [string]$Server)
    $p = @{ ErrorAction = 'SilentlyContinue' }; if ($Server) { $p.Server = $Server }
    $o = Get-ADUser     @p -Filter "sAMAccountName -eq '$Name'"; if ($o) { return $o.SID }
    $o = Get-ADGroup    @p -Filter "sAMAccountName -eq '$Name'"; if ($o) { return $o.SID }
    $o = Get-ADComputer @p -Filter "Name -eq '$Name'";           if ($o) { return $o.SID }
    throw "Resolve-Sid: principal '$Name' not found (server=$Server)"
}

# Grant an ACE on an AD object (optionally on a remote/child DC via $Server).
function Grant-Ace {
    param(
        [Parameter(Mandatory)][string]$TargetDN,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid,
        [Parameter(Mandatory)][System.DirectoryServices.ActiveDirectoryRights]$Rights,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]$Inheritance = 'None',
        [guid]$ObjectType = [guid]::Empty,
        [guid]$InheritedObjectType = [guid]::Empty,
        [string]$Server
    )
    $path = if ($Server) { "LDAP://$Server/$TargetDN" } else { "LDAP://$TargetDN" }
    $de   = New-Object System.DirectoryServices.DirectoryEntry($path)
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    if ($ObjectType -ne [guid]::Empty -and $InheritedObjectType -ne [guid]::Empty) {
        $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($Sid,$Rights,$allow,$ObjectType,$Inheritance,$InheritedObjectType)
    } elseif ($ObjectType -ne [guid]::Empty) {
        $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($Sid,$Rights,$allow,$ObjectType,$Inheritance)
    } else {
        $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($Sid,$Rights,$allow,$Inheritance)
    }
    $de.ObjectSecurity.AddAccessRule($ace)
    $de.CommitChanges()
    $de.Close()
}

function Info($m) { Write-Host "    $m" -ForegroundColor Gray }
function Good($m) { Write-Host "    $m" -ForegroundColor Green }

# Base container / helper for AD CS certificate templates (all live in the
# forest Configuration partition, so they are managed here on DC1).
$TmplContainer = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigDN"
function Get-CaDN {
    (Get-ADObject -SearchBase "CN=Enrollment Services,CN=Public Key Services,CN=Services,$ConfigDN" `
        -Filter "objectClass -eq 'pKIEnrollmentService'").DistinguishedName
}

# Create a v2 certificate template by cloning the byte-array attributes of the
# built-in User template and overriding the security-relevant fields. Optionally
# grant a principal Enroll (and, for ESC4, GenericAll) and publish to the CA.
function New-VulnTemplate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$NameFlag = 0,             # 0x1 = ENROLLEE_SUPPLIES_SUBJECT (ESC1)
        [int]$EnrollmentFlag = 0,       # 0x80000 = NO_SECURITY_EXTENSION (ESC9)
        [string[]]$EKU = @('1.3.6.1.5.5.7.3.2'),      # Client Authentication
        [string[]]$CertificatePolicy,   # issuance policy OID(s) (ESC13)
        [System.Security.Principal.SecurityIdentifier]$EnrollSid,
        [switch]$WeakAcl,               # grant EnrollSid GenericAll on the template (ESC4)
        [switch]$Publish
    )
    $dn = "CN=$Name,$TmplContainer"
    if (-not (Get-ADObject -Filter "distinguishedName -eq '$dn'" -SearchBase $TmplContainer -ErrorAction SilentlyContinue)) {
        $src = Get-ADObject "CN=User,$TmplContainer" -Properties pKIExpirationPeriod,pKIOverlapPeriod,pKIKeyUsage,pKICriticalExtensions,pKIDefaultCSPs
        $attrs = @{
            'flags'                                = 131680
            'revision'                             = 100
            'msPKI-Template-Schema-Version'        = 2
            'msPKI-Template-Minor-Revision'        = 1
            'msPKI-RA-Signature'                   = 0
            'msPKI-Enrollment-Flag'                = $EnrollmentFlag
            'msPKI-Private-Key-Flag'               = 16
            'msPKI-Certificate-Name-Flag'          = $NameFlag
            'msPKI-Minimal-Key-Size'               = 2048
            'pKIDefaultKeySpec'                    = 1
            'pKIMaxIssuingDepth'                   = 0
            'pKIExtendedKeyUsage'                  = $EKU
            'msPKI-Certificate-Application-Policy' = $EKU
            'pKIExpirationPeriod'                  = $src.pKIExpirationPeriod
            'pKIOverlapPeriod'                     = $src.pKIOverlapPeriod
            'pKIKeyUsage'                          = $src.pKIKeyUsage
            'pKICriticalExtensions'                = $src.pKICriticalExtensions
            'pKIDefaultCSPs'                       = $src.pKIDefaultCSPs
        }
        if ($CertificatePolicy) { $attrs['msPKI-Certificate-Policy'] = $CertificatePolicy }
        New-ADObject -Name $Name -Type 'pKICertificateTemplate' -Path $TmplContainer -DisplayName $Name -OtherAttributes $attrs
        Info "created template $Name"
    }
    if ($EnrollSid) {
        Grant-Ace -TargetDN $dn -Sid $EnrollSid -Rights ExtendedRight -ObjectType $G_ENROLL
        Grant-Ace -TargetDN $dn -Sid $EnrollSid -Rights GenericRead
    }
    if ($WeakAcl -and $EnrollSid) { Grant-Ace -TargetDN $dn -Sid $EnrollSid -Rights GenericAll }
    if ($Publish) { Set-ADObject -Identity (Get-CaDN) -Add @{ certificateTemplates = $Name } -ErrorAction SilentlyContinue }
}

# Create an issuance-policy OID object linked to a group (ESC13). Returns the
# generated OID string via [ref]$OutOid.
function New-IssuancePolicy {
    param([Parameter(Mandatory)][string]$DisplayName, [Parameter(Mandatory)][string]$GroupDN, [ref]$OutOid)
    $oidC = "CN=OID,CN=Public Key Services,CN=Services,$ConfigDN"
    $cn   = "VulnIssuancePolicy"
    $dn   = "CN=$cn,$oidC"
    $existing = Get-ADObject -Filter "cn -eq '$cn'" -SearchBase $oidC -Properties 'msPKI-Cert-Template-OID' -ErrorAction SilentlyContinue
    if ($existing) { if ($OutOid) { $OutOid.Value = $existing.'msPKI-Cert-Template-OID' }; return }
    $oid = "1.3.6.1.4.1.311.21.8." + ((1..5 | ForEach-Object { Get-Random -Minimum 1000000 -Maximum 99999999 }) -join ".")
    New-ADObject -Name $cn -Type 'msPKI-Enterprise-Oid' -Path $oidC -OtherAttributes @{
        'msPKI-Cert-Template-OID' = $oid
        'flags'                   = 2
        'displayName'             = $DisplayName
        'msDS-OIDToGroupLink'     = $GroupDN
    }
    Info "created issuance policy OID $oid -> $GroupDN"
    if ($OutOid) { $OutOid.Value = $oid }
}

$AuthUsers = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-11")

# =============================================================================
# Misconfiguration definitions
# Each entry: Tag, Domain (label), Title, and a scriptblock Action.
# =============================================================================
$Misconfigs = [ordered]@{}

# -----------------------------------------------------------------------------
"badsuccessor" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "child"; Title = "BadSuccessor - dMSA migration abuse (Server 2025)"
  Action = {
    # ATTACK  : Akamai's BadSuccessor (May 2025). A principal with permission to
    #           CREATE dMSA objects in an OU can create a Delegated Managed
    #           Service Account, set msDS-ManagedAccountPrecededByLink to ANY
    #           target (incl. a Domain Admin) and flip msDS-DelegatedMSAState=2.
    #           The KDC then issues tickets carrying the target's SIDs -> full
    #           domain compromise from minimal rights. Needs a Server 2025 DC.
    # TOOL    : SharpSuccessor / bloodyAD / native ADSI
    # PATH    : OUT\jdoe -> create dMSA under OU=Onboarding -> link to OUT\childadm
    #           (child Domain Admin) -> authenticate as the dMSA.
    # SEED    : delegate "Create msDS-DelegatedManagedServiceAccount child objects"
    #           on a dedicated OU to the low-priv foothold user.
    $ouDN = "OU=Onboarding,$ChildDN"
    if (-not (Get-ADOrganizationalUnit -Server $ChildDC -Filter "DistinguishedName -eq '$ouDN'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Server $ChildDC -Name "Onboarding" -Path $ChildDN -ProtectedFromAccidentalDeletion $false
        Info "created OU=Onboarding in child"
    }
    $sid = Resolve-Sid -Name "jdoe" -Server $ChildDC
    # CreateChild of dMSA objects, inherited to the OU subtree
    Grant-Ace -TargetDN $ouDN -Sid $sid -Rights CreateChild -ObjectType $G_DMSA -Inheritance All -Server $ChildDC
    Good "OUT\jdoe can now create dMSA objects under OU=Onboarding (BadSuccessor)"
  }
}}

# -----------------------------------------------------------------------------
"shadowcred" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "child"; Title = "Shadow Credentials - writable msDS-KeyCredentialLink"
  Action = {
    # ATTACK  : Write access to a target's msDS-KeyCredentialLink lets you add
    #           your own key pair, then authenticate as that target via PKINIT
    #           (Key Trust) - no password reset, stealthy.
    # TOOL    : Certipy shadow auto / Whisker / pyWhisker
    # PATH    : OUT\jdoe -> write KeyCredentialLink on OUT\childadm -> PKINIT as
    #           childadm (child Domain Admin).
    # SEED    : grant jdoe GenericWrite (write-property on KeyCredentialLink) on childadm.
    $sid = Resolve-Sid -Name "jdoe" -Server $ChildDC
    $target = (Get-ADUser -Server $ChildDC -Filter "sAMAccountName -eq 'childadm'").DistinguishedName
    Grant-Ace -TargetDN $target -Sid $sid -Rights WriteProperty -ObjectType $G_KEYCREDLINK -Server $ChildDC
    Grant-Ace -TargetDN $target -Sid $sid -Rights GenericWrite  -Server $ChildDC
    Good "OUT\jdoe can write msDS-KeyCredentialLink on OUT\childadm (Shadow Credentials)"
  }
}}

# -----------------------------------------------------------------------------
"rbcd" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "child"; Title = "Resource-Based Constrained Delegation takeover"
  Action = {
    # ATTACK  : Write access to a computer's msDS-AllowedToActOnBehalfOfOther-
    #           Identity lets you configure RBCD from a machine account you
    #           control (default ms-DS-MachineAccountQuota = 10 lets any user
    #           create one), then S4U2Self/Proxy to get a service ticket as any
    #           user (e.g. Administrator) to that computer -> local SYSTEM.
    # TOOL    : Rubeus (s4u) / impacket rbcd.py + getST
    # PATH    : OUT\IT-Helpdesk (jdoe is a member) -> GenericWrite on WS01$ ->
    #           add attacker-controlled computer to RBCD -> compromise WS01.
    # SEED    : grant IT-Helpdesk GenericWrite over the WS01 computer object.
    $sid = Resolve-Sid -Name "IT-Helpdesk" -Server $ChildDC
    $ws01 = (Get-ADComputer -Server $ChildDC -Filter "Name -eq 'WS01'").DistinguishedName
    Grant-Ace -TargetDN $ws01 -Sid $sid -Rights GenericWrite -Server $ChildDC
    Good "OUT\IT-Helpdesk has GenericWrite on WS01\$ (RBCD)"
  }
}}

# -----------------------------------------------------------------------------
"gmsa" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "root"; Title = "Over-exposed gMSA - low-priv can read the password"
  Action = {
    # ATTACK  : A group Managed Service Account whose managed password is
    #           readable by a low-priv principal (msDS-GroupMSAMembership) can be
    #           retrieved and used; if that gMSA is over-privileged, it is a free
    #           escalation. (See also Golden gMSA if the KDS root key leaks.)
    # TOOL    : gMSADumper / Get-ADServiceAccount -Properties / NetExec
    # PATH    : MINILAB\IT-HelpDesk (bob is a member) -> read svc_backup gMSA
    #           password -> svc_backup is a member of a privileged group.
    # SEED    : create a KDS root key (backdated so it is usable immediately) and
    #           the gMSA in the ROOT domain (the KDS key is local to DC1 there, so
    #           this is reliable - a child gMSA would race the KDS key's forest
    #           replication and fail with "Key does not exist"). Allow IT-HelpDesk
    #           to retrieve the password and over-privilege the account.
    if (-not (Get-KdsRootKey -ErrorAction SilentlyContinue)) {
        Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10)) | Out-Null
        Info "created backdated KDS root key"
    }
    $grp = Get-ADGroup -Filter "sAMAccountName -eq 'IT-HelpDesk'"
    if (-not (Get-ADServiceAccount -Filter "Name -eq 'svc_backup'" -ErrorAction SilentlyContinue)) {
        New-ADServiceAccount -Name "svc_backup" `
            -DNSHostName "svc_backup.$RootDomain" `
            -PrincipalsAllowedToRetrieveManagedPassword $grp.SID `
            -Enabled $true
        Info "created gMSA svc_backup, readable by IT-HelpDesk"
    }
    # over-privilege it: member of root Domain Admins
    Add-ADGroupMember -Identity "Domain Admins" -Members "svc_backup$" -ErrorAction SilentlyContinue
    Good "gMSA svc_backup password readable by MINILAB\IT-HelpDesk and it is a Domain Admin"
  }
}}

# -----------------------------------------------------------------------------
"daclchain" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "child"; Title = "Multi-hop DACL chain (BloodHound-friendly)"
  Action = {
    # ATTACK  : A chain of object ACLs that BloodHound renders as a clean attack
    #           path, teaching ACL abuse enumeration and pathing.
    # TOOL    : BloodHound CE / SharpHound + PowerView (Set-DomainObjectOwner,
    #           Add-DomainObjectAcl, Add-DomainGroupMember)
    # PATH    : OUT\jdoe -WriteDacl-> OUT\Developers -GenericAll-> OUT\childadm
    #           i.e. jdoe grants itself rights over Developers, adds itself,
    #           then Developers' GenericAll over childadm -> reset/own childadm.
    # SEED    : jdoe WriteDacl on Developers; Developers GenericAll on childadm.
    $jdoe = Resolve-Sid -Name "jdoe" -Server $ChildDC
    $devs = Resolve-Sid -Name "Developers" -Server $ChildDC
    $devDN     = (Get-ADGroup -Server $ChildDC -Filter "sAMAccountName -eq 'Developers'").DistinguishedName
    $childadmDN = (Get-ADUser  -Server $ChildDC -Filter "sAMAccountName -eq 'childadm'").DistinguishedName
    Grant-Ace -TargetDN $devDN      -Sid $jdoe -Rights WriteDacl   -Server $ChildDC
    Grant-Ace -TargetDN $childadmDN -Sid $devs -Rights GenericAll  -Server $ChildDC
    Good "DACL chain: jdoe -WriteDacl-> Developers -GenericAll-> childadm"
  }
}}

# -----------------------------------------------------------------------------
"foreignadmin" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "root+child"; Title = "Cross-domain foreign privileged membership (child -> root)"
  Action = {
    # ATTACK  : A child-domain principal placed in a privileged ROOT-domain group
    #           bridges the trust: owning the child immediately grants root-domain
    #           privilege. The forest - not the domain - is the security boundary.
    # TOOL    : BloodHound (cross-domain edges) / Rubeus / mimikatz for the golden
    #           path, or simply logging on with the child principal.
    # PATH    : compromise OUT\Developers (via daclchain) -> Developers is a member
    #           of MINILAB\Server Operators (a root privileged group) -> root foothold
    #           -> from there to Enterprise Admin.
    # SEED    : add the child group OUT\Developers to a root privileged group.
    $devs = Resolve-Sid -Name "Developers" -Server $ChildDC
    # add the child group (as a foreign security principal) to root Server Operators
    $so = [ADSI]"LDAP://CN=Server Operators,CN=Builtin,$RootDN"
    $so.Add("LDAP://<SID=$($devs.Value)>")
    Good "OUT\Developers added to MINILAB\Server Operators (cross-domain escalation)"
  }
}}

# -----------------------------------------------------------------------------
"esc6" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "forest CA"; Title = "ADCS ESC6 - EDITF_ATTRIBUTESUBJECTALTNAME2 on the CA"
  Action = {
    # ATTACK  : With EDITF_ATTRIBUTESUBJECTALTNAME2 set, the CA honours a SAN
    #           supplied in ANY request - so a low-priv enrollee can request a
    #           cert for Administrator on an otherwise benign template.
    # TOOL    : Certipy req -upn administrator@minilab.local ...
    # SEED    : flip the CA policy flag and restart CertSvc.
    & certutil -setreg "policy\EditFlags" "+EDITF_ATTRIBUTESUBJECTALTNAME2" | Out-Null
    Restart-Service CertSvc -Force
    Good "CA now honours attacker-supplied SANs (ESC6)"
  }
}}

# -----------------------------------------------------------------------------
"esc16" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "forest CA"; Title = "ADCS ESC16 - SID security extension disabled CA-wide"
  Action = {
    # ATTACK  : Disabling the szOID_NTDS_CA_SECURITY_EXT (1.3.6.1.4.1.311.25.2)
    #           on the CA means issued certs never carry the requester's SID, so
    #           strong certificate mapping cannot bind them - opening weak-mapping
    #           / account-impersonation abuses (pairs with ESC9/ESC10-style paths).
    # TOOL    : Certipy (find will flag ESC16; req/auth to exploit)
    # SEED    : add the security-extension OID to the CA DisableExtensionList.
    & certutil -setreg "policy\DisableExtensionList" "+1.3.6.1.4.1.311.25.2" | Out-Null
    Restart-Service CertSvc -Force
    Good "CA no longer embeds the SID security extension (ESC16)"
  }
}}

# -----------------------------------------------------------------------------
"esc1" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "forest CA"; Title = "ADCS ESC1 - enrollee-supplies-subject client-auth template"
  Action = {
    # ATTACK  : A template that (a) lets the enrollee supply the subject/SAN,
    #           (b) has a client-auth EKU, (c) is enrollable by low-priv users
    #           with no manager approval. Request a cert as Administrator ->
    #           authenticate as Administrator.
    # TOOL    : certipy req -ca minilab-DC1-CA -template ESC1-VulnUser -upn administrator@minilab.local
    # SEED    : ESC1 template (ENROLLEE_SUPPLIES_SUBJECT), Auth Users enroll, published.
    New-VulnTemplate -Name "ESC1-VulnUser" -NameFlag 1 -EnrollSid $AuthUsers -Publish
    Good "published ESC1 template 'ESC1-VulnUser' (enrollable by Authenticated Users)"
  }
}}

# -----------------------------------------------------------------------------
"esc4" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "forest CA"; Title = "ADCS ESC4 - template with a writable (weak) ACL"
  Action = {
    # ATTACK  : A template object that a low-priv principal can WRITE. The
    #           attacker rewrites the (otherwise benign) template into an ESC1
    #           on the fly - enrollee-supplies-subject + client auth - then
    #           requests a cert as any user.
    # TOOL    : certipy template (to weaponize) then certipy req ...
    # SEED    : a benign client-auth template with GenericAll for Authenticated Users.
    New-VulnTemplate -Name "ESC4-WeakACL" -NameFlag 0 -EnrollSid $AuthUsers -WeakAcl -Publish
    Good "ESC4: template 'ESC4-WeakACL' is writable (GenericAll) by Authenticated Users"
  }
}}

# -----------------------------------------------------------------------------
"esc9" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "forest CA"; Title = "ADCS ESC9 - no security extension on the template"
  Action = {
    # ATTACK  : A template with CT_FLAG_NO_SECURITY_EXTENSION (0x80000) issues
    #           certs without the requester's SID, so strong certificate mapping
    #           can't bind them. Combined with weak UPN/mapping this enables
    #           impersonation (classic ESC9 with a writable target UPN).
    # TOOL    : certipy (find flags ESC9; account/shadow + req to exploit)
    # SEED    : enrollee-supplies-subject client-auth template with the
    #           NO_SECURITY_EXTENSION enrollment flag set.
    New-VulnTemplate -Name "ESC9-NoSecExt" -NameFlag 1 -EnrollmentFlag 0x80000 -EnrollSid $AuthUsers -Publish
    Good "ESC9: template 'ESC9-NoSecExt' omits the SID security extension"
  }
}}

# -----------------------------------------------------------------------------
"esc13" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "forest CA"; Title = "ADCS ESC13 - issuance policy linked to a privileged group"
  Action = {
    # ATTACK  : A template carrying an issuance policy whose OID is linked
    #           (msDS-OIDToGroupLink) to a group. Enrolling and authenticating
    #           with the cert injects that group's membership into your token -
    #           if the group is privileged, that is instant escalation. No
    #           enrollee-supplies-subject needed, so it slips past ESC1 detection.
    # TOOL    : certipy find (flags ESC13) ; req + auth
    # PATH    : enrol ESC13-PolicyToGroup as a low-priv user -> token gains
    #           PKI-Policy-Admins -> which is in BUILTIN\Administrators.
    # SEED    : a Universal group in BUILTIN\Administrators, an issuance-policy
    #           OID linked to it, and a client-auth template carrying that policy.
    if (-not (Get-ADGroup -Filter "sAMAccountName -eq 'PKI-Policy-Admins'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name "PKI-Policy-Admins" -SamAccountName "PKI-Policy-Admins" -GroupScope Universal -GroupCategory Security -Path "OU=Tier0,$RootDN"
        Info "created Universal group PKI-Policy-Admins"
    }
    $grpDN = (Get-ADGroup "PKI-Policy-Admins").DistinguishedName
    Add-ADGroupMember -Identity "Administrators" -Members "PKI-Policy-Admins" -ErrorAction SilentlyContinue
    $oid = $null
    New-IssuancePolicy -DisplayName "Vuln ESC13 Policy" -GroupDN $grpDN -OutOid ([ref]$oid)
    New-VulnTemplate -Name "ESC13-PolicyToGroup" -NameFlag 0 -CertificatePolicy @($oid) -EnrollSid $AuthUsers -Publish
    Good "ESC13: template links an issuance policy -> PKI-Policy-Admins (in BUILTIN\Administrators)"
  }
}}

# -----------------------------------------------------------------------------
"esc15" | ForEach-Object { $Misconfigs[$_] = @{
  Domain = "forest CA"; Title = "ADCS ESC15 / EKUwu (CVE-2024-49019) - abusable v1 template"
  Action = {
    # ATTACK  : Schema v1 templates don't constrain application policies, so an
    #           enrollee can inject an arbitrary application policy (e.g. Client
    #           Authentication or Certificate Request Agent) into the request via
    #           the v1 template - EKUwu. The default 'WebServer' v1 template is
    #           the canonical target once it is enrollable.
    # TOOL    : certipy req -template WebServer -application-policies '1.3.6.1.5.5.7.3.2' ...
    # SEED    : make the built-in v1 WebServer template enrollable by Auth Users + publish.
    $wsDN = "CN=WebServer,$TmplContainer"
    Grant-Ace -TargetDN $wsDN -Sid $AuthUsers -Rights ExtendedRight -ObjectType $G_ENROLL
    Grant-Ace -TargetDN $wsDN -Sid $AuthUsers -Rights GenericRead
    Set-ADObject -Identity (Get-CaDN) -Add @{ certificateTemplates = 'WebServer' } -ErrorAction SilentlyContinue
    Good "ESC15: v1 WebServer template now enrollable by Authenticated Users (EKUwu)"
  }
}}

# =============================================================================
# Runner
# =============================================================================
if ($List) {
    Write-Host "`nAvailable misconfigurations:`n" -ForegroundColor Cyan
    foreach ($k in $Misconfigs.Keys) {
        "{0,-14} [{1,-10}] {2}" -f $k, $Misconfigs[$k].Domain, $Misconfigs[$k].Title | Write-Host
    }
    Write-Host "`nSeed all: .\seed-misconfigs.ps1   |   Seed some: -Only tag1,tag2`n"
    return
}

$targets = if ($Only) { $Only } else { $Misconfigs.Keys }
Write-Host "`n=== Seeding misconfigurations on $RootDomain / $ChildDomain ===`n" -ForegroundColor Cyan
$ok = 0; $fail = 0
foreach ($tag in $targets) {
    if (-not $Misconfigs.Contains($tag)) { Write-Host "[skip] unknown tag: $tag" -ForegroundColor Yellow; continue }
    $m = $Misconfigs[$tag]
    Write-Host "[$tag] $($m.Title)" -ForegroundColor White
    try { & $m.Action; $ok++ }
    catch { Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red; $fail++ }
    Write-Host ""
}
Write-Host "=== Done. $ok seeded, $fail failed. ===" -ForegroundColor Cyan
Write-Host "Foothold: OUT\jdoe / $FootholdPass (interactive logon at WS01)." -ForegroundColor Cyan
