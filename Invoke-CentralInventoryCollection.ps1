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
    
    Kompatibilitätsprüfung:
    - TPM 2.0 erforderlich
    - Secure Boot erforderlich
    - Windows 10/11 (Build >= 14393)
    - 4GB+ RAM
    - 64-bit Architektur

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
    # Für GPO (als SYSTEM):
    .\Invoke-InventoryCollection.ps1 -CsvPath "\\fileserver\inventory\"

.EXAMPLE
    # Für Debugging:
    .\Invoke-InventoryCollection.ps1 -LocalOnly $true -Verbose $true
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$CsvPath = "",
    
    [Parameter(Mandatory=$false)]
    [bool]$LocalOnly = $false,
    
    [Parameter(Mandatory=$false)]
    [bool]$Verbose = $false
)

# ============================================================================
# KONFIGURATION
# ============================================================================

# Standard-Pfade
if ([string]::IsNullOrEmpty($CsvPath)) {
    $CsvPath = "C:\Temp\Inventory"
}

$Script:LocalCachePath = "C:\ProgramData\Inventory"
$Script:LogFile = ""
$Script:LockFile = Join-Path -Path $Script:LocalCachePath -ChildPath "inventory.lock"

# Standort-Mapping (IP-Präfix -> Standort)
# Anpassen Sie diese Zuordnung an Ihre Netzwerk-Struktur!
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
    "MinWindowsBuild" = 14393        # Windows 10
    "MinRAMGB" = 4
    "RequireTPM20" = $true
    "RequireSecureBoot" = $false      # Oft deaktiviert, aber empfohlen
    "RequireUEFI" = $false
    "Require64Bit" = $true
}

# ============================================================================
# FUNKTIONEN - LOGGING
# ============================================================================

function Initialize-Environment {
    <#
    .SYNOPSIS
        Initialisiert Verzeichnisse und Logging
    #>
    # Erstelle lokale Cache-Verzeichnisse
    if (-not (Test-Path $Script:LocalCachePath)) {
        New-Item -ItemType Directory -Path $Script:LocalCachePath -Force | Out-Null
    }
    
    # Erstelle CSV-Ausgabe-Verzeichnis
    if (-not (Test-Path $CsvPath)) {
        New-Item -ItemType Directory -Path $CsvPath -Force | Out-Null
    }
    
    # Setup Log-Datei
    if ($Verbose) {
        $logDir = Join-Path -Path $Script:LocalCachePath -ChildPath "Logs"
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $Script:LogFile = Join-Path -Path $logDir -ChildPath "inventory_$(Get-Date -Format 'yyyyMMdd').log"
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Schreibt Log-Einträge
    #>
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
    <#
    .SYNOPSIS
        Prüft ob bereits ein Inventory läuft
    #>
    if (Test-Path $Script:LockFile) {
        $lockAge = ((Get-Date) - (Get-Item $Script:LockFile).LastWriteTime).TotalMinutes
        if ($lockAge -lt 5) {
            Write-Log "Inventory läuft bereits, überspringe" "WARN"
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
    <#
    .SYNOPSIS
        Bestimmt Standort basierend auf IP-Adresse
    #>
    try {
        # Hole alle aktiven Netzwerk-Adapter mit IP
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
        
        # Sammle alle IPs
        foreach ($nic in $nics) {
            if ($nic.IPAddress) {
                foreach ($ip in $nic.IPAddress) {
                    # Ignoriere IPv6 und loopback
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
        
        # Bestimme Standort basierend auf IP-Präfix
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
            "Error" = $_.Exception.Message
        }
    }
}

# ============================================================================
# FUNKTIONEN - HARDWARE-ERFASSUNG
# ============================================================================

function Get-ComputerBasics {
    <#
    .SYNOPSIS
        Sammelt Basis-Computerinformationen
    #>
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
    <#
    .SYNOPSIS
        Sammelt BIOS/Firmware Informationen
    #>
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
    <#
    .SYNOPSIS
        Sammelt CPU-Informationen
    #>
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
    <#
    .SYNOPSIS
        Sammelt RAM-Informationen
    #>
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
    <#
    .SYNOPSIS
        Sammelt Betriebssystem-Informationen
    #>
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
    <#
    .SYNOPSIS
        Sammelt Speicher-Informationen
    #>
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
    <#
    .SYNOPSIS
        Prüft TPM 2.0 Verfügbarkeit und Status
    #>
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
    <#
    .SYNOPSIS
        Prüft Secure Boot Status
    #>
    try {
        $secureBootStatus = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
        
        return @{
            "SecureBootEnabled" = $secureBootStatus
        }
    }
    catch {
        # Secure Boot ist wahrscheinlich deaktiviert oder nicht unterstützt
        return @{
            "SecureBootEnabled" = $false
        }
    }
}

function Get-UEFIInfo {
    <#
    .SYNOPSIS
        Prüft UEFI Firmware
    #>
    try {
        $firmware = Get-CimInstance -ClassName Win32_SystemFirmware -ErrorAction SilentlyContinue
        
        # Alternative: Registry-Check
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
    <#
    .SYNOPSIS
        Prüft BitLocker Status
    #>
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
    <#
    .SYNOPSIS
        Prüft Active Directory Status
    #>
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
    <#
    .SYNOPSIS
        Prüft Entra ID / Azure AD Join Status
    #>
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
    <#
    .SYNOPSIS
        Prüft Intune MDM Registrierung
    #>
    try {
        $intuneRegistered = $false
        
        # Prüfe Registry
        $mdmPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
        if (Test-Path $mdmPath) {
            $enrollments = Get-ChildItem -Path $mdmPath -ErrorAction SilentlyContinue | `
                Where-Object { $_.PSChildName -notmatch "^{" }
            $intuneRegistered = $enrollments.Count -gt 0
        }
        
        # Alternative: WMI
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
# FUNKTIONEN - KOMPATIBILITÄTSPRÜFUNG
# ============================================================================

function Test-EntraIDIntuneCompatibility {
    <#
    .SYNOPSIS
        Prüft Kompatibilität für Entra ID / Intune
        Gibt detaillierten Status mit Fehlern zurück
    #>
    param(
        [hashtable]$HardwareInfo
    )
    
    $compatible = $true
    $issues = @()
    $recommendations = @()
    
    # Prüfe Windows Build
    if ($HardwareInfo.OSBuild) {
        $buildNumber = [int]$HardwareInfo.OSBuild
        if ($buildNumber -lt $Script:Compatibility["MinWindowsBuild"]) {
            $compatible = $false
            $issues += "Windows Build zu alt: $buildNumber (mind. $($Script:Compatibility['MinWindowsBuild']))"
        }
    }
    
    # Prüfe RAM
    if ($HardwareInfo.RAMTotalGB) {
        if ($HardwareInfo.RAMTotalGB -lt $Script:Compatibility["MinRAMGB"]) {
            $compatible = $false
            $issues += "Zu wenig RAM: $($HardwareInfo.RAMTotalGB)GB (mind. $($Script:Compatibility['MinRAMGB'])GB)"
        }
    }
    
    # Prüfe Architektur
    if ($HardwareInfo.OSArchitecture) {
        if ($Script:Compatibility["Require64Bit"] -and $HardwareInfo.OSArchitecture -notmatch "64") {
            $compatible = $false
            $issues += "32-Bit OS nicht unterstützt"
        }
    }
    
    # Prüfe TPM 2.0
    if ($Script:Compatibility["RequireTPM20"]) {
        if (-not $HardwareInfo.TPM20Present) {
            $compatible = $false
            $issues += "TPM 2.0 nicht vorhanden"
        }
    }
    
    # Warnungen für empfohlene Features
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
        "Status" = if ($compatible) { "✓ Kompatibel" } else { "✗ Nicht kompatibel" }
    }
}

# ============================================================================
# FUNKTIONEN - CSV EXPORT
# ============================================================================

function Export-ToCSV {
    <#
    .SYNOPSIS
        Exportiert alle gesammelten Daten als CSV
    #>
    param(
        [hashtable]$InventoryData
    )
    
    try {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $computerName = $InventoryData.Basics.ComputerName
        $filename = "inventory_${computerName}_${timestamp}.csv"
        $filepath = Join-Path -Path $CsvPath -ChildPath $filename
        
        # Flache CSV-Struktur für einfache Auswertung
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
    # Initialisierung
    Initialize-Environment
    Write-Log "=== Inventory Collection gestartet ===" "INFO"
    
    # Prüfe Lock-File
    if (Test-LockFile) {
        Write-Log "Inventory läuft bereits, beende" "WARN"
        exit 0
    }
    
    # Sammle Daten
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
    
    Write-Log "Prüfe Security Features..." "INFO"
    $tpmData = Get-TPMInfo
    $secureBootData = Get-SecureBootInfo
    $uefiData = Get-UEFIInfo
    $bitlockerData = Get-BitLockerInfo
    
    Write-Log "Prüfe Cloud/Identity Status..." "INFO"
    $adData = Get-ADStatus
    $entraIDData = Get-EntraIDStatus
    $intuneData = Get-IntuneStatus
    
    # Kombiniere Hardware-Daten
    $hardwareInfo = @{}
    $hardwareInfo += $osData
    $hardwareInfo += $ramData
    $hardwareInfo += $cpuData
    $hardwareInfo += $tpmData
    $hardwareInfo += $secureBootData
    $hardwareInfo += $uefiData
    
    # Prüfe Kompatibilität
    Write-Log "Prüfe Entra ID / Intune Kompatibilität..." "INFO"
    $compatibilityCheck = Test-EntraIDIntuneCompatibility -HardwareInfo $hardwareInfo
    
    # Kombiniere alles
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
    
    # Exportiere zu CSV
    Write-Log "Exportiere zu CSV..." "INFO"
    $csvPath = Export-ToCSV -InventoryData $inventoryData
    
    # Konsolen-Ausgabe
    if ($Verbose) {
        Write-Host ""
        Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║  INVENTORY COLLECTION ABGESCHLOSSEN" -ForegroundColor Green
        Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
        Write-Host "💻 Computer: $($inventoryData.Basics.ComputerName)" -ForegroundColor Cyan
        Write-Host "📍 Standort: $($inventoryData.Location.Location)" -ForegroundColor Cyan
        Write-Host "🌐 IP: $($inventoryData.Location.PrimaryIP)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "📊 Hardware:" -ForegroundColor Yellow
        Write-Host "  OS: $($inventoryData.OS.OSName) Build $($inventoryData.OS.OSBuild)"
        Write-Host "  CPU: $($inventoryData.CPU.CPUName) ($($inventoryData.CPU.CPUCores) Cores)"
        Write-Host "  RAM: $($inventoryData.RAM.RAMTotalGB)GB"
        Write-Host ""
        Write-Host "☁️ Cloud Status:" -ForegroundColor Yellow
        Write-Host "  AD: $(if ($inventoryData.AD.ADMember) { '✓' } else { '✗' }) $($inventoryData.AD.ADDomain)"
        Write-Host "  Entra ID: $(if ($inventoryData.EntraID.AzureADJoined) { '✓' } else { '✗' }) $($inventoryData.EntraID.AzureADJoinType)"
        Write-Host "  Intune: $(if ($inventoryData.Intune.IntuneRegistered) { '✓' } else { '✗' })"
        Write-Host ""
        Write-Host "🔒 Sicherheit:" -ForegroundColor Yellow
        Write-Host "  TPM 2.0: $(if ($inventoryData.Security.TPM20Present) { '✓' } else { '✗' })"
        Write-Host "  Secure Boot: $(if ($inventoryData.Security.SecureBootEnabled) { '✓' } else { '✗' })"
        Write-Host "  BitLocker: $(if ($inventoryData.Security.BitLockerEnabled) { '✓' } else { '✗' })"
        Write-Host ""
        Write-Host "✅ Entra ID / Intune: $($inventoryData.Compatibility.Status)" -ForegroundColor $(if ($inventoryData.Compatibility.Compatible) { "Green" } else { "Red" })
        if ($inventoryData.Compatibility.Issues) {
            Write-Host "  ❌ Probleme: $($inventoryData.Compatibility.Issues)" -ForegroundColor Red
        }
        if ($inventoryData.Compatibility.Recommendations) {
            Write-Host "  ⚠️  Empfehlungen: $($inventoryData.Compatibility.Recommendations)" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "💾 CSV exportiert: $csvPath" -ForegroundColor Green
        Write-Host ""
    }
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
