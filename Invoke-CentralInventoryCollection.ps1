#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Zentrale Inventory Collection für GPO/Startup/Login-Scripts
    Sammelt Hardware, Standort (via IP), Entra ID/Intune Readiness
    Exportiert als CSV für zentrale Auswertung

.DESCRIPTION
    Optimiert für:
    - Deployment via GPO (Startup/Login-Script)
    - Minimale Performance-Auswirkung
    - CSV-Export statt API
    - Hardware-Kompatibilität für Entra ID/Intune
    - Automatische Standort-Erkennung via IP

.PARAMETER CsvPath
    Netzwerk-Pfad für CSV-Export (z.B. \\fileserver\inventory\)
    Falls leer: C:\Temp\Inventory

.PARAMETER LocalOnly
    Wenn $true: Nur lokal speichern, nicht netzweit
    Standard: $false

.PARAMETER Verbose
    Wenn $true: Detaillierte Logs schreiben
    Standard: $false

.EXAMPLE
    .\Invoke-CentralInventoryCollection.ps1 -CsvPath "\\fileserver\inventory\"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$CsvPath = "\\roemergarten.local\netlogon\pccollect",
    
    [Parameter(Mandatory=$false)]
    [bool]$LocalOnly = $false,
    
    [Parameter(Mandatory=$false)]
    [bool]$Verbose = $false
)

# ============================================================================
# KONFIGURATION
# ============================================================================

$Script:LocalCachePath = "C:\ProgramData\Inventory"
$Script:LogFile = ""
$Script:LockFile = Join-Path -Path $Script:LocalCachePath -ChildPath "inventory.lock"

# Standort-Mapping (IP-Präfix -> Standort)
$Script:LocationMapping = @{
    "192.168.1." = "Standort-A"
    "192.168.2." = "Standort-B"
    "10.0.1." = "Standort-C"
    "10.0.2." = "Standort-D"
    "172.16." = "Homeoffice"
    "127." = "Localhost"
}

# Entra ID/Intune Kompatibilitäts-Anforderungen
$Script:Compatibility = @{
    "MinWindowsBuild" = 14393
    "MinRAMGB" = 4
    "RequireTPM20" = $true
    "RequireSecureBoot" = $false
    "RequireUEFI" = $false
    "Require64Bit" = $true
}

# ============================================================================
# FUNKTIONEN - LOGGING
# ============================================================================

function Initialize-Environment {
    if (-not (Test-Path $Script:LocalCachePath)) {
        New-Item -ItemType Directory -Path $Script:LocalCachePath -Force | Out-Null
    }
    
    if (-not (Test-Path $CsvPath)) {
        New-Item -ItemType Directory -Path $CsvPath -Force | Out-Null
    }
    
    if ($Verbose) {
        $logDir = Join-Path -Path $Script:LocalCachePath -ChildPath "Logs"
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $Script:LogFile = Join-Path -Path $logDir -ChildPath "inventory_$(Get-Date -Format 'yyyyMMdd').log"
    }
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    if ($Verbose -and $Script:LogFile) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
        Add-Content -Path $Script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# FUNKTIONEN - LOCK MANAGEMENT
# ============================================================================

function Test-LockFile {
    if (Test-Path $Script:LockFile) {
        $lockAge = ((Get-Date) - (Get-Item $Script:LockFile).LastWriteTime).TotalMinutes
        if ($lockAge -lt 5) {
            Write-Log "Inventory laeuft bereits, ueberspringe" "WARN"
            return $true
        }
        else {
            Remove-Item $Script:LockFile -ErrorAction SilentlyContinue
        }
    }
    
    New-Item -ItemType File -Path $Script:LockFile -Force | Out-Null
    return $false
}

function Remove-LockFile {
    Remove-Item $Script:LockFile -ErrorAction SilentlyContinue
}

# ============================================================================
# FUNKTIONEN - STANDORT-ERKENNUNG
# ============================================================================

function Get-LocationFromIP {
    try {
        $nics = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration `
            -Filter "IPEnabled=true" -ErrorAction SilentlyContinue
        
        if (-not $nics) {
            return @{
                "Location" = "Unknown"
                "PrimaryIP" = "N/A"
                "AllIPs" = @()
            }
        }
        
        $primaryIP = $null
        $allIPs = @()
        
        foreach ($nic in $nics) {
            if ($nic.IPAddress) {
                foreach ($ip in $nic.IPAddress) {
                    if ($ip -match "^\d+\.\d+\.\d+\.\d+$" -and $ip -ne "127.0.0.1") {
                        $allIPs += $ip
                        if (-not $primaryIP) {
                            $primaryIP = $ip
                        }
                    }
                }
            }
        }
        
        if (-not $primaryIP) {
            return @{
                "Location" = "Unknown"
                "PrimaryIP" = "N/A"
                "AllIPs" = @()
            }
        }
        
        $detectedLocation = "Unknown"
        
        foreach ($prefix in $Script:LocationMapping.Keys) {
            if ($primaryIP.StartsWith($prefix)) {
                $detectedLocation = $Script:LocationMapping[$prefix]
                break
            }
        }
        
        Write-Log "Standort erkannt: $detectedLocation (IP: $primaryIP)" "INFO"
        
        return @{
            "Location" = $detectedLocation
            "PrimaryIP" = $primaryIP
            "AllIPs" = $allIPs
        }
    }
    catch {
        Write-Log "Fehler bei Standort-Erkennung: $_" "ERROR"
        return @{
            "Location" = "Error"
            "PrimaryIP" = "N/A"
            "AllIPs" = @()
        }
    }
}

# ============================================================================
# FUNKTIONEN - HARDWARE-ERFASSUNG
# ============================================================================

function Get-ComputerBasics {
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        
        return @{
            "ComputerName" = $computerSystem.Name
            "Domain" = $computerSystem.Domain
            "DomainMember" = $computerSystem.PartOfDomain
            "Manufacturer" = $computerSystem.Manufacturer
            "Model" = $computerSystem.Model
            "Username" = $computerSystem.UserName
        }
    }
    catch {
        Write-Log "Fehler bei Computer-Basics: $_" "ERROR"
        return @{ "ComputerName" = $env:COMPUTERNAME }
    }
}

function Get-BIOSInfo {
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        
        if (-not $bios) {
            return @{}
        }
        
        return @{
            "BIOSManufacturer" = $bios.Manufacturer
            "BIOSVersion" = $bios.Version
            "BIOSReleaseDate" = $bios.ReleaseDate
            "SerialNumber" = $bios.SerialNumber
        }
    }
    catch {
        Write-Log "Fehler bei BIOS-Info: $_" "ERROR"
        return @{}
    }
}

function Get-CPUInfo {
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if (-not $cpu) {
            return @{}
        }
        
        return @{
            "CPUName" = $cpu.Name
            "CPUCores" = $cpu.NumberOfCores
            "CPUThreads" = $cpu.ThreadCount
            "CPUMaxClockMHz" = $cpu.MaxClockSpeed
            "CPUArchitecture" = $cpu.Architecture
        }
    }
    catch {
        Write-Log "Fehler bei CPU-Info: $_" "ERROR"
        return @{}
    }
}

function Get-RAMInfo {
    try {
        $physicalMemory = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue
        
        if (-not $physicalMemory) {
            return @{
                "RAMTotalGB" = 0
                "RAMModules" = 0
            }
        }
        
        $ramSum = ($physicalMemory | Measure-Object -Property Capacity -Sum).Sum
        $ramGB = [math]::Round($ramSum / 1GB, 2)
        
        return @{
            "RAMTotalGB" = $ramGB
            "RAMModules" = @($physicalMemory).Count
        }
    }
    catch {
        Write-Log "Fehler bei RAM-Info: $_" "ERROR"
        return @{
            "RAMTotalGB" = 0
            "RAMModules" = 0
        }
    }
}

function Get-OSInfo {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        
        if (-not $os) {
            return @{}
        }
        
        return @{
            "OSName" = $os.Caption
            "OSVersion" = $os.Version
            "OSBuild" = $os.BuildNumber
            "OSArchitecture" = $os.OSArchitecture
            "OSInstallDate" = $os.InstallDate
            "OSSystemDrive" = $os.SystemDrive
        }
    }
    catch {
        Write-Log "Fehler bei OS-Info: $_" "ERROR"
        return @{}
    }
}

function Get-StorageInfo {
    try {
        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
        
        if (-not $disks) {
            return @{
                "StorageCount" = 0
                "StorageTotalGB" = 0
                "StorageFreeGB" = 0
            }
        }
        
        $totalSize = ($disks | Measure-Object -Property Size -Sum).Sum
        $totalFree = ($disks | Measure-Object -Property FreeSpace -Sum).Sum
        
        return @{
            "StorageCount" = @($disks).Count
            "StorageTotalGB" = [math]::Round($totalSize / 1GB, 2)
            "StorageFreeGB" = [math]::Round($totalFree / 1GB, 2)
        }
    }
    catch {
        Write-Log "Fehler bei Storage-Info: $_" "ERROR"
        return @{
            "StorageCount" = 0
            "StorageTotalGB" = 0
            "StorageFreeGB" = 0
        }
    }
}

# ============================================================================
# FUNKTIONEN - SECURITY FEATURES
# ============================================================================

function Get-TPMInfo {
    try {
        $tpm = Get-CimInstance -ClassName Win32_Tpm `
            -Namespace "root\cimv2\security\microsofttpm" `
            -ErrorAction SilentlyContinue
        
        if ($tpm) {
            return @{
                "TPM20Present" = $true
                "TPMVersion" = $tpm.SpecVersion
                "TPMManufacturer" = $tpm.ManufacturerVersion
            }
        }
        
        return @{
            "TPM20Present" = $false
            "TPMVersion" = "Not Available"
            "TPMManufacturer" = ""
        }
    }
    catch {
        Write-Log "Fehler bei TPM-Check: $_" "ERROR"
        return @{
            "TPM20Present" = $false
            "TPMVersion" = "Unknown"
            "TPMManufacturer" = ""
        }
    }
}

function Get-SecureBootInfo {
    try {
        $secureBootStatus = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
        
        return @{
            "SecureBootEnabled" = $secureBootStatus
        }
    }
    catch {
        return @{
            "SecureBootEnabled" = $false
        }
    }
}

function Get-UEFIInfo {
    try {
        if (Test-Path "HKLM:\System\CurrentControlSet\Control\SecureBoot\State") {
            $uefiBoot = $true
        }
        else {
            $uefiBoot = $false
        }
        
        return @{
            "UEFIBoot" = $uefiBoot
        }
    }
    catch {
        return @{
            "UEFIBoot" = $false
        }
    }
}

function Get-BitLockerInfo {
    try {
        $bitLocker = Get-BitLockerVolume -ErrorAction SilentlyContinue
        
        if ($bitLocker) {
            $enabledVolumes = @($bitLocker | Where-Object { $_.ProtectionStatus -eq "On" }).Count
            return @{
                "BitLockerVolumes" = @($bitLocker).Count
                "BitLockerEnabledVolumes" = $enabledVolumes
                "BitLockerEnabled" = $enabledVolumes -gt 0
            }
        }
        
        return @{
            "BitLockerVolumes" = 0
            "BitLockerEnabledVolumes" = 0
            "BitLockerEnabled" = $false
        }
    }
    catch {
        return @{
            "BitLockerVolumes" = 0
            "BitLockerEnabledVolumes" = 0
            "BitLockerEnabled" = $false
        }
    }
}

# ============================================================================
# FUNKTIONEN - CLOUD & IDENTITY
# ============================================================================

function Get-ADStatus {
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        
        return @{
            "ADMember" = $computerSystem.PartOfDomain
            "ADDomain" = $computerSystem.Domain
        }
    }
    catch {
        return @{
            "ADMember" = $false
            "ADDomain" = ""
        }
    }
}

function Get-EntraIDStatus {
    try {
        $dsregOutput = & dsregcmd /status 2>$null
        
        $status = @{
            "AzureADJoined" = $false
            "HybridJoined" = $false
            "TenantID" = ""
            "DeviceID" = ""
            "AzureADJoinType" = "None"
        }
        
        foreach ($line in $dsregOutput) {
            if ($line -match "AzureAdJoined\s*:\s*YES") {
                $status["AzureADJoined"] = $true
                $status["AzureADJoinType"] = "Azure AD Joined"
            }
            if ($line -match "DomainJoined\s*:\s*YES" -and $status["AzureADJoined"]) {
                $status["HybridJoined"] = $true
                $status["AzureADJoinType"] = "Hybrid Join"
            }
            if ($line -match "TenantId\s*:\s*([a-f0-9-]+)") {
                $status["TenantID"] = $matches[1]
            }
            if ($line -match "DeviceId\s*:\s*([a-f0-9-]+)") {
                $status["DeviceID"] = $matches[1]
            }
        }
        
        return $status
    }
    catch {
        Write-Log "Fehler bei Entra ID Check: $_" "ERROR"
        return @{
            "AzureADJoined" = $false
            "HybridJoined" = $false
            "TenantID" = ""
            "DeviceID" = ""
            "AzureADJoinType" = "Unknown"
        }
    }
}

function Get-IntuneStatus {
    try {
        $intuneRegistered = $false
        
        $mdmPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
        if (Test-Path $mdmPath) {
            $enrollments = Get-ChildItem -Path $mdmPath -ErrorAction SilentlyContinue | `
                Where-Object { $_.PSChildName -notmatch "^{" }
            $intuneRegistered = $enrollments.Count -gt 0
        }
        
        if (-not $intuneRegistered) {
            $mdmWmi = Get-CimInstance -Namespace "root\cimv2\mdm\dmmap" `
                -ClassName "DMClient" -ErrorAction SilentlyContinue
            $intuneRegistered = $null -ne $mdmWmi
        }
        
        return @{
            "IntuneRegistered" = $intuneRegistered
        }
    }
    catch {
        Write-Log "Fehler bei Intune Check: $_" "ERROR"
        return @{
            "IntuneRegistered" = $false
        }
    }
}

# ============================================================================
# FUNKTIONEN - KOMPATIBILITAETSPRÜFUNG
# ============================================================================

function Test-EntraIDIntuneCompatibility {
    param(
        [hashtable]$HardwareInfo
    )
    
    $compatible = $true
    $issues = @()
    $recommendations = @()
    
    if ($HardwareInfo.OSBuild) {
        $buildNumber = [int]$HardwareInfo.OSBuild
        if ($buildNumber -lt $Script:Compatibility["MinWindowsBuild"]) {
            $compatible = $false
            $issues += "Windows Build zu alt: $buildNumber (mind. $($Script:Compatibility['MinWindowsBuild']))"
        }
    }
    
    if ($HardwareInfo.RAMTotalGB) {
        if ($HardwareInfo.RAMTotalGB -lt $Script:Compatibility["MinRAMGB"]) {
            $compatible = $false
            $issues += "Zu wenig RAM: $($HardwareInfo.RAMTotalGB)GB (mind. $($Script:Compatibility['MinRAMGB'])GB)"
        }
    }
    
    if ($HardwareInfo.OSArchitecture) {
        if ($Script:Compatibility["Require64Bit"] -and $HardwareInfo.OSArchitecture -notmatch "64") {
            $compatible = $false
            $issues += "32-Bit OS nicht unterstuetzt"
        }
    }
    
    if ($Script:Compatibility["RequireTPM20"]) {
        if (-not $HardwareInfo.TPM20Present) {
            $compatible = $false
            $issues += "TPM 2.0 nicht vorhanden"
        }
    }
    
    if (-not $HardwareInfo.SecureBootEnabled) {
        $recommendations += "Secure Boot wird empfohlen"
    }
    
    if (-not $HardwareInfo.UEFIBoot) {
        $recommendations += "UEFI-Firmware wird empfohlen"
    }
    
    return @{
        "Compatible" = $compatible
        "Issues" = $issues -join "; "
        "Recommendations" = $recommendations -join "; "
        "Status" = if ($compatible) { "JA - Kompatibel" } else { "NEIN - Nicht kompatibel" }
    }
}

# ============================================================================
# FUNKTIONEN - CSV EXPORT
# ============================================================================

function Export-ToCSV {
    param(
        [hashtable]$InventoryData
    )
    
    try {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $computerName = $InventoryData.Basics.ComputerName
        $filename = "inventory_${computerName}_${timestamp}.csv"
        $filepath = Join-Path -Path $CsvPath -ChildPath $filename
        
        $csvObject = [PSCustomObject]@{
            "Timestamp"                    = Get-Date -Format "o"
            "ComputerName"                 = $InventoryData.Basics.ComputerName
            "SerialNumber"                 = $InventoryData.BIOS.SerialNumber
            "Manufacturer"                 = $InventoryData.Basics.Manufacturer
            "Model"                        = $InventoryData.Basics.Model
            "Domain"                       = $InventoryData.Basics.Domain
            "ADMember"                     = $InventoryData.AD.ADMember
            
            "Standort"                     = $InventoryData.Location.Location
            "IP_Address"                   = $InventoryData.Location.PrimaryIP
            
            "OS_Name"                      = $InventoryData.OS.OSName
            "OS_Version"                   = $InventoryData.OS.OSVersion
            "OS_Build"                     = $InventoryData.OS.OSBuild
            "OS_Architecture"              = $InventoryData.OS.OSArchitecture
            
            "CPU"                          = $InventoryData.CPU.CPUName
            "CPU_Cores"                    = $InventoryData.CPU.CPUCores
            "CPU_Threads"                  = $InventoryData.CPU.CPUThreads
            "RAM_GB"                       = $InventoryData.RAM.RAMTotalGB
            "RAM_Modules"                  = $InventoryData.RAM.RAMModules
            "Storage_Count"                = $InventoryData.Storage.StorageCount
            "Storage_Total_GB"             = $InventoryData.Storage.StorageTotalGB
            "Storage_Free_GB"              = $InventoryData.Storage.StorageFreeGB
            
            "TPM20_Present"                = $InventoryData.Security.TPM20Present
            "SecureBoot_Enabled"           = $InventoryData.Security.SecureBootEnabled
            "UEFI_Boot"                    = $InventoryData.Security.UEFIBoot
            "BitLocker_Enabled"            = $InventoryData.Security.BitLockerEnabled
            
            "AD_Joined"                    = $InventoryData.AD.ADMember
            "AzureAD_Joined"               = $InventoryData.EntraID.AzureADJoined
            "AzureAD_JoinType"             = $InventoryData.EntraID.AzureADJoinType
            "Intune_Registered"            = $InventoryData.Intune.IntuneRegistered
            
            "EntraID_Intune_Compatible"    = $InventoryData.Compatibility.Status
            "Compatibility_Issues"         = $InventoryData.Compatibility.Issues
            "Compatibility_Recommendations" = $InventoryData.Compatibility.Recommendations
        }
        
        $csvObject | Export-Csv -Path $filepath -Encoding UTF8 -NoTypeInformation -Force
        
        Write-Log "CSV erfolgreich exportiert: $filepath" "SUCCESS"
        return $filepath
    }
    catch {
        Write-Log "Fehler beim CSV-Export: $_" "ERROR"
        return ""
    }
}

# ============================================================================
# HAUPTPROGRAMM
# ============================================================================

try {
    Initialize-Environment
    Write-Log "=== Inventory Collection gestartet ===" "INFO"
    
    if (Test-LockFile) {
        Write-Log "Inventory laeuft bereits, beende" "WARN"
        exit 0
    }
    
    Write-Log "Sammle Standort..." "INFO"
    $locationData = Get-LocationFromIP
    
    Write-Log "Sammle Computer-Basics..." "INFO"
    $basicsData = Get-ComputerBasics
    
    Write-Log "Sammle BIOS-Info..." "INFO"
    $biosData = Get-BIOSInfo
    
    Write-Log "Sammle CPU-Info..." "INFO"
    $cpuData = Get-CPUInfo
    
    Write-Log "Sammle RAM-Info..." "INFO"
    $ramData = Get-RAMInfo
    
    Write-Log "Sammle OS-Info..." "INFO"
    $osData = Get-OSInfo
    
    Write-Log "Sammle Speicher-Info..." "INFO"
    $storageData = Get-StorageInfo
    
    Write-Log "Pruefen Security Features..." "INFO"
    $tpmData = Get-TPMInfo
    $secureBootData = Get-SecureBootInfo
    $uefiData = Get-UEFIInfo
    $bitlockerData = Get-BitLockerInfo
    
    Write-Log "Pruefen Cloud/Identity Status..." "INFO"
    $adData = Get-ADStatus
    $entraIDData = Get-EntraIDStatus
    $intuneData = Get-IntuneStatus
    
    $hardwareInfo = @{}
    $hardwareInfo += $osData
    $hardwareInfo += $ramData
    $hardwareInfo += $cpuData
    $hardwareInfo += $tpmData
    $hardwareInfo += $secureBootData
    $hardwareInfo += $uefiData
    
    Write-Log "Pruefen Entra ID / Intune Kompatibilitaet..." "INFO"
    $compatibilityCheck = Test-EntraIDIntuneCompatibility -HardwareInfo $hardwareInfo
    
    $inventoryData = @{
        "Basics"        = $basicsData
        "BIOS"          = $biosData
        "CPU"           = $cpuData
        "RAM"           = $ramData
        "OS"            = $osData
        "Storage"       = $storageData
        "Security"      = $tpmData + $secureBootData + $uefiData + $bitlockerData
        "Location"      = $locationData
        "AD"            = $adData
        "EntraID"       = $entraIDData
        "Intune"        = $intuneData
        "Compatibility" = $compatibilityCheck
    }
    
    Write-Log "Exportiere zu CSV..." "INFO"
    $csvPath = Export-ToCSV -InventoryData $inventoryData
}
catch {
    Write-Log "Kritischer Fehler: $_" "ERROR"
    exit 1
}
finally {
    Remove-LockFile
    Write-Log "Inventory Collection beendet" "INFO"
}

exit 0
