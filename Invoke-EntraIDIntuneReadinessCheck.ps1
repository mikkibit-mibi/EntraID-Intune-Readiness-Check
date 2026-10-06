#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Überprüft die Entra ID und Intune Readiness eines Windows Computers
    und exportiert die Ergebnisse für GLPI.

.DESCRIPTION
    Dieses Skript führt eine umfassende Überprüfung durch:
    - Active Directory Mitgliedschaft
    - Entra ID / Azure AD Status
    - Intune MDM Registrierung
    - TPM 2.0 Verfügbarkeit
    - Secure Boot Status
    - BitLocker Status
    - Windows Version Kompatibilität
    - Hardware-Inventar
    - Netzwerk-Konfiguration

.PARAMETER GLPIServer
    Die URL des GLPI-Servers (z.B. https://glpi.example.com)

.PARAMETER GLPIToken
    Der API-Token für die Authentifizierung bei GLPI

.PARAMETER ExportPath
    Pfad für JSON/CSV Export (Standard: $env:TEMP)

.PARAMETER SendToGLPI
    Wenn $true, werden die Daten automatisch an GLPI übertragen

.EXAMPLE
    .\Invoke-EntraIDIntuneReadinessCheck.ps1 -ExportPath "C:\Temp" -SendToGLPI $false

.EXAMPLE
    .\Invoke-EntraIDIntuneReadinessCheck.ps1 -GLPIServer "https://glpi.example.com" -GLPIToken "token123" -SendToGLPI $true
#>

param(
    [string]$GLPIServer = "",
    [string]$GLPIToken = "",
    [string]$ExportPath = $env:TEMP,
    [bool]$SendToGLPI = $false
)

# ============================================================================
# FUNKTIONEN
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
}

function Get-ADStatus {
    <#
    .SYNOPSIS
        Prüft Active Directory Mitgliedschaft und Details
    #>
    Write-Log "Prüfe Active Directory Status..."
    
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $adDomain = $computerSystem.Domain
        $isDomainJoined = $computerSystem.PartOfDomain
        
        $adInfo = @{
            "IsDomainJoined"    = $isDomainJoined
            "Domain"            = $adDomain
            "ComputerName"      = $computerSystem.Name
            "Manufacturer"      = $computerSystem.Manufacturer
            "Model"             = $computerSystem.Model
            "Status"            = if ($isDomainJoined) { "✓ AD-Mitglied" } else { "✗ Nicht AD-Mitglied" }
        }
        
        Write-Log "AD Status: $($adInfo.Status)"
        return $adInfo
    }
    catch {
        Write-Log "Fehler beim Abrufen des AD-Status: $_" "ERROR"
        return @{ "Status" = "✗ Fehler"; "Error" = $_.Exception.Message }
    }
}

function Get-EntraIDStatus {
    <#
    .SYNOPSIS
        Prüft Entra ID / Azure AD Join Status
    #>
    Write-Log "Prüfe Entra ID Status..."
    
    try {
        $dsregOutput = & dsregcmd /status
        $entraID = $false
        $hybridJoin = $false
        $aadTenantID = ""
        $deviceID = ""
        
        foreach ($line in $dsregOutput) {
            if ($line -match "AzureAdJoined\s*:\s*YES") { $entraID = $true }
            if ($line -match "DomainJoined\s*:\s*YES") { $domainJoined = $true }
            if ($line -match "DomainJoined\s*:\s*YES" -and $entraID) { $hybridJoin = $true }
            if ($line -match "TenantId\s*:\s*([a-f0-9-]+)") { $aadTenantID = $matches[1] }
            if ($line -match "DeviceId\s*:\s*([a-f0-9-]+)") { $deviceID = $matches[1] }
        }
        
        $entraInfo = @{
            "IsAzureADJoined"   = $entraID
            "IsHybridJoined"    = $hybridJoin
            "TenantID"          = $aadTenantID
            "DeviceID"          = $deviceID
            "Status"            = if ($entraID) { "✓ Entra ID registriert" } else { "✗ Nicht Entra ID registriert" }
            "JoinType"          = if ($hybridJoin) { "Hybrid Join" } elseif ($entraID) { "Azure AD Join" } else { "Keine" }
        }
        
        Write-Log "Entra ID Status: $($entraInfo.Status)"
        return $entraInfo
    }
    catch {
        Write-Log "Fehler beim Abrufen des Entra ID-Status: $_" "ERROR"
        return @{ "Status" = "✗ Fehler"; "Error" = $_.Exception.Message }
    }
}

function Get-IntuneStatus {
    <#
    .SYNOPSIS
        Prüft Intune MDM Registrierung
    #>
    Write-Log "Prüfe Intune MDM Status..."
    
    try {
        $intuneRegistered = $false
        $intuneUserID = ""
        $intuneDeviceID = ""
        
        # Prüfe Registry für Intune/MDM
        $mdmPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
        $intuneEnrollment = Get-ChildItem -Path $mdmPath -ErrorAction SilentlyContinue | 
            Where-Object { $_.PSChildName -notmatch "^{" }
        
        if ($intuneEnrollment) {
            $intuneRegistered = $true
            $intuneUserID = $intuneEnrollment.PSChildName
        }
        
        # Prüfe auch WMI für MDM-Info
        $mdmWmi = Get-CimInstance -Namespace "root\cimv2\mdm\dmmap" -ClassName "DMClient" -ErrorAction SilentlyContinue
        if ($mdmWmi) {
            $intuneRegistered = $true
            $intuneDeviceID = $mdmWmi.DeviceID
        }
        
        $intuneInfo = @{
            "IsIntuneRegistered" = $intuneRegistered
            "EnrollmentID"       = $intuneUserID
            "DeviceID"           = $intuneDeviceID
            "Status"             = if ($intuneRegistered) { "✓ Bei Intune registriert" } else { "✗ Nicht bei Intune registriert" }
        }
        
        Write-Log "Intune Status: $($intuneInfo.Status)"
        return $intuneInfo
    }
    catch {
        Write-Log "Fehler beim Abrufen des Intune-Status: $_" "ERROR"
        return @{ "Status" = "✗ Fehler"; "Error" = $_.Exception.Message }
    }
}

function Get-SecurityFeatures {
    <#
    .SYNOPSIS
        Prüft Sicherheitsfeatures (TPM, Secure Boot, BitLocker)
    #>
    Write-Log "Prüfe Sicherheitsfeatures..."
    
    try {
        $securityFeatures = @{}
        
        # TPM 2.0 prüfen
        try {
            $tpm = Get-CimInstance -ClassName "Win32_Tpm" -Namespace "root\cimv2\security\microsofttpm" -ErrorAction Stop
            $securityFeatures["TPM20Available"] = $true
            $securityFeatures["TPMVersion"] = $tpm.SpecVersion
            $securityFeatures["TPMManufacturer"] = $tpm.ManufacturerVersion
        }
        catch {
            $securityFeatures["TPM20Available"] = $false
            $securityFeatures["TPMVersion"] = "Nicht verfügbar"
        }
        
        # Secure Boot prüfen
        try {
            $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
            $securityFeatures["SecureBootEnabled"] = $secureBoot
        }
        catch {
            $securityFeatures["SecureBootEnabled"] = $false
        }
        
        # BitLocker prüfen
        try {
            $bitLocker = Get-BitLockerVolume -ErrorAction Stop
            $securityFeatures["BitLockerEnabled"] = ($bitLocker | Where-Object { $_.ProtectionStatus -eq "On" }).Count -gt 0
            $securityFeatures["BitLockerVolumes"] = $bitLocker.Count
        }
        catch {
            $securityFeatures["BitLockerEnabled"] = $false
            $securityFeatures["BitLockerVolumes"] = 0
        }
        
        $securityFeatures["TPMStatus"] = if ($securityFeatures["TPM20Available"]) { "✓ TPM 2.0 vorhanden" } else { "✗ TPM 2.0 nicht vorhanden" }
        $securityFeatures["SecureBootStatus"] = if ($securityFeatures["SecureBootEnabled"]) { "✓ Secure Boot aktiv" } else { "✗ Secure Boot nicht aktiv" }
        $securityFeatures["BitLockerStatus"] = if ($securityFeatures["BitLockerEnabled"]) { "✓ BitLocker aktiv" } else { "✗ BitLocker nicht aktiv" }
        
        Write-Log "Sicherheitsfeatures geprüft"
        return $securityFeatures
    }
    catch {
        Write-Log "Fehler beim Abrufen der Sicherheitsfeatures: $_" "ERROR"
        return @{ "Status" = "✗ Fehler"; "Error" = $_.Exception.Message }
    }
}

function Get-WindowsVersion {
    <#
    .SYNOPSIS
        Prüft Windows Version und Kompatibilität
    #>
    Write-Log "Prüfe Windows Version..."
    
    try {
        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
        $winVersion = [System.Environment]::OSVersion.Version
        
        $versionInfo = @{
            "OSName"             = $osInfo.Caption
            "OSVersion"          = $osInfo.Version
            "OSBuildNumber"      = $osInfo.BuildNumber
            "InstallDate"        = $osInfo.InstallDate
            "SystemDrive"        = $osInfo.SystemDrive
            "Architecture"       = $osInfo.OSArchitecture
        }
        
        # Prüfe Intune/Entra ID Kompatibilität
        $majorVersion = [int]$osInfo.Version.Split('.')[0]
        $buildNumber = [int]$osInfo.BuildNumber
        
        $intuneCompatible = ($majorVersion -ge 10) -and ($buildNumber -ge 10240)
        $versionInfo["IntuneCompatible"] = $intuneCompatible
        $versionInfo["IntuneCompatibleStatus"] = if ($intuneCompatible) { "✓ Intune-kompatibel" } else { "✗ Nicht Intune-kompatibel" }
        
        Write-Log "Windows Version: $($versionInfo.OSName) Build $($versionInfo.OSBuildNumber)"
        return $versionInfo
    }
    catch {
        Write-Log "Fehler beim Abrufen der Windows Version: $_" "ERROR"
        return @{ "Status" = "✗ Fehler"; "Error" = $_.Exception.Message }
    }
}

function Get-HardwareInventory {
    <#
    .SYNOPSIS
        Sammelt Hardware-Inventardaten
    #>
    Write-Log "Sammle Hardware-Inventar..."
    
    try {
        $hardware = @{}
        
        # CPU
        $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $hardware["CPU"] = @{
            "Name" = $cpu.Name
            "Cores" = $cpu.NumberOfCores
            "Threads" = $cpu.ThreadCount
            "MaxClockSpeed" = "$($cpu.MaxClockSpeed) MHz"
            "Architecture" = $cpu.Architecture
        }
        
        # RAM
        $ram = Get-CimInstance -ClassName Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
        $hardware["RAM"] = @{
            "TotalGB" = [math]::Round($ram.Sum / 1GB, 2)
            "Modules" = $ram.Count
        }
        
        # Festplatte
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
        $hardware["Storage"] = @()
        foreach ($d in $disk) {
            $hardware["Storage"] += @{
                "Drive" = $d.Name
                "TotalGB" = [math]::Round($d.Size / 1GB, 2)
                "FreeGB" = [math]::Round($d.FreeSpace / 1GB, 2)
                "UsedPercent" = [math]::Round((($d.Size - $d.FreeSpace) / $d.Size) * 100, 2)
            }
        }
        
        # Netzwerk
        $nic = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true } | Select-Object -First 1
        $hardware["Network"] = @{
            "Adapter" = $nic.Description
            "IPAddress" = $nic.IPAddress[0]
            "MACAddress" = $nic.MACAddress
            "DHCPEnabled" = $nic.DHCPEnabled
            "DNSServers" = $nic.DNSServerSearchOrder
        }
        
        # BIOS
        $bios = Get-CimInstance -ClassName Win32_BIOS
        $hardware["BIOS"] = @{
            "Manufacturer" = $bios.Manufacturer
            "Version" = $bios.Version
            "ReleaseDate" = $bios.ReleaseDate
            "SerialNumber" = $bios.SerialNumber
        }
        
        Write-Log "Hardware-Inventar gesammelt"
        return $hardware
    }
    catch {
        Write-Log "Fehler beim Sammeln des Hardware-Inventars: $_" "ERROR"
        return @{ "Error" = $_.Exception.Message }
    }
}

function Get-InstalledSoftware {
    <#
    .SYNOPSIS
        Sammelt installierte Software
    #>
    Write-Log "Sammle installierte Software..."
    
    try {
        $software = @()
        
        # Prüfe Registry für installierte Programme
        $regPaths = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        )
        
        foreach ($path in $regPaths) {
            if (Test-Path $path) {
                $apps = Get-ChildItem -Path $path
                foreach ($app in $apps) {
                    $name = $app.GetValue("DisplayName")
                    $version = $app.GetValue("DisplayVersion")
                    $publisher = $app.GetValue("Publisher")
                    
                    if ($name) {
                        $software += @{
                            "Name" = $name
                            "Version" = $version
                            "Publisher" = $publisher
                        }
                    }
                }
            }
        }
        
        Write-Log "Installierte Software gesammelt: $($software.Count) Programme"
        return $software | Sort-Object -Property Name -Unique | Select-Object -First 50  # Top 50
    }
    catch {
        Write-Log "Fehler beim Sammeln der installierten Software: $_" "ERROR"
        return @()
    }
}

function New-GLPIInventoryObject {
    <#
    .SYNOPSIS
        Erstellt ein GLPI-kompatibles Inventar-Objekt
    #>
    param(
        [hashtable]$ADStatus,
        [hashtable]$EntraIDStatus,
        [hashtable]$IntuneStatus,
        [hashtable]$SecurityFeatures,
        [hashtable]$WindowsVersion,
        [hashtable]$Hardware,
        [array]$Software
    )
    
    $readinessScore = 0
    $readinessDetails = @()
    
    # Berechne Readiness-Score
    if ($ADStatus.IsDomainJoined) { $readinessScore += 20; $readinessDetails += "✓ AD-Mitglied" }
    if ($EntraIDStatus.IsAzureADJoined) { $readinessScore += 20; $readinessDetails += "✓ Entra ID registriert" }
    if ($IntuneStatus.IsIntuneRegistered) { $readinessScore += 15; $readinessDetails += "✓ Intune registriert" }
    if ($SecurityFeatures.TPM20Available) { $readinessScore += 15; $readinessDetails += "✓ TPM 2.0 vorhanden" }
    if ($SecurityFeatures.SecureBootEnabled) { $readinessScore += 10; $readinessDetails += "✓ Secure Boot aktiv" }
    if ($WindowsVersion.IntuneCompatible) { $readinessScore += 20; $readinessDetails += "✓ Windows-Version kompatibel" }
    
    $glpiObject = @{
        "timestamp"          = Get-Date -Format "o"
        "computer_name"      = $env:COMPUTERNAME
        "serial_number"      = $Hardware.BIOS.SerialNumber
        "manufacturer"       = $Hardware.BIOS.Manufacturer
        "model"              = $env:COMPUTERNAME
        
        "readiness_score"    = $readinessScore
        "readiness_details"  = $readinessDetails -join "; "
        "readiness_status"   = switch ($readinessScore) {
            { $_ -ge 80 } { "✓ Sehr gut geeignet" }
            { $_ -ge 60 } { "⚠ Gut geeignet" }
            { $_ -ge 40 } { "⚠ Bedingt geeignet" }
            default       { "✗ Nicht geeignet" }
        }
        
        "ad_status"          = $ADStatus.Status
        "ad_domain"          = $ADStatus.Domain
        "entra_id_status"    = $EntraIDStatus.Status
        "entra_id_join_type" = $EntraIDStatus.JoinType
        "intune_status"      = $IntuneStatus.Status
        
        "tpm_status"         = $SecurityFeatures.TPMStatus
        "secure_boot_status" = $SecurityFeatures.SecureBootStatus
        "bitlocker_status"   = $SecurityFeatures.BitLockerStatus
        
        "os_name"            = $WindowsVersion.OSName
        "os_version"         = $WindowsVersion.OSVersion
        "os_build"           = $WindowsVersion.OSBuildNumber
        "os_architecture"    = $WindowsVersion.Architecture
        "os_compatible"      = $WindowsVersion.IntuneCompatibleStatus
        
        "cpu_name"           = $Hardware.CPU.Name
        "cpu_cores"          = $Hardware.CPU.Cores
        "cpu_threads"        = $Hardware.CPU.Threads
        "ram_gb"             = $Hardware.RAM.TotalGB
        "storage"            = $Hardware.Storage
        "network"            = $Hardware.Network
        
        "software_count"     = $Software.Count
        "software_list"      = $Software | Select-Object -First 10  # Top 10
    }
    
    return $glpiObject
}

function Send-ToGLPI {
    <#
    .SYNOPSIS
        Sendet die Inventardaten an GLPI via REST API
    #>
    param(
        [string]$Server,
        [string]$Token,
        [hashtable]$InventoryData
    )
    
    Write-Log "Sende Daten an GLPI Server: $Server"
    
    if (-not $Server -or -not $Token) {
        Write-Log "GLPI Server oder Token nicht konfiguriert. Überspringen." "WARN"
        return $false
    }
    
    try {
        $headers = @{
            "Content-Type" = "application/json"
            "Authorization" = "Bearer $Token"
        }
        
        $body = $InventoryData | ConvertTo-Json -Depth 5
        
        $uri = "$Server/apirest.php/Computer"
        
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
        
        Write-Log "Erfolgreich an GLPI übertragen: $($response | ConvertTo-Json)" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Fehler beim Senden an GLPI: $_" "ERROR"
        return $false
    }
}

function Export-ToJSON {
    <#
    .SYNOPSIS
        Exportiert die Daten als JSON
    #>
    param(
        [hashtable]$Data,
        [string]$ExportPath
    )
    
    try {
        $filename = "Readiness_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $filepath = Join-Path -Path $ExportPath -ChildPath $filename
        
        $Data | ConvertTo-Json -Depth 10 | Out-File -FilePath $filepath -Encoding UTF8
        
        Write-Log "JSON exportiert: $filepath" "SUCCESS"
        return $filepath
    }
    catch {
        Write-Log "Fehler beim JSON-Export: $_" "ERROR"
        return ""
    }
}

function Export-ToCSV {
    <#
    .SYNOPSIS
        Exportiert die Daten als CSV
    #>
    param(
        [hashtable]$Data,
        [string]$ExportPath
    )
    
    try {
        $filename = "Readiness_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        $filepath = Join-Path -Path $ExportPath -ChildPath $filename
        
        # Konvertiere Hashtable in PSCustomObject für CSV-Export
        $csvData = [PSCustomObject]@{
            "Computername"           = $Data.computer_name
            "Seriennummer"           = $Data.serial_number
            "Readiness Score"        = $Data.readiness_score
            "Readiness Status"       = $Data.readiness_status
            "AD Status"              = $Data.ad_status
            "Entra ID Status"        = $Data.entra_id_status
            "Intune Status"          = $Data.intune_status
            "TPM Status"             = $Data.tpm_status
            "Secure Boot Status"     = $Data.secure_boot_status
            "BitLocker Status"       = $Data.bitlocker_status
            "Windows Version"        = $Data.os_name
            "OS Build"               = $Data.os_build
            "CPU"                    = $Data.cpu_name
            "Kerne"                  = $Data.cpu_cores
            "RAM (GB)"               = $Data.ram_gb
            "Timestamp"              = $Data.timestamp
        }
        
        $csvData | Export-Csv -Path $filepath -Encoding UTF8 -NoTypeInformation
        
        Write-Log "CSV exportiert: $filepath" "SUCCESS"
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

# Setup Logging
$logFile = Join-Path -Path $ExportPath -ChildPath "Readiness_Check_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Write-Log "=== Entra ID & Intune Readiness Check gestartet ===" "INFO"

# Sammle alle Daten
$adStatus = Get-ADStatus
$entraIDStatus = Get-EntraIDStatus
$intuneStatus = Get-IntuneStatus
$securityFeatures = Get-SecurityFeatures
$windowsVersion = Get-WindowsVersion
$hardware = Get-HardwareInventory
$software = Get-InstalledSoftware

# Erstelle GLPI-Objekt
$glpiObject = New-GLPIInventoryObject -ADStatus $adStatus -EntraIDStatus $entraIDStatus -IntuneStatus $intuneStatus `
    -SecurityFeatures $securityFeatures -WindowsVersion $windowsVersion -Hardware $hardware -Software $software

# Exportiere Daten
$jsonPath = Export-ToJSON -Data $glpiObject -ExportPath $ExportPath
$csvPath = Export-ToCSV -Data $glpiObject -ExportPath $ExportPath

# Sende an GLPI falls aktiviert
if ($SendToGLPI) {
    Send-ToGLPI -Server $GLPIServer -Token $GLPIToken -InventoryData $glpiObject
}

# Zeige Zusammenfassung
Write-Host "`n" -ForegroundColor Green
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  READINESS CHECK ZUSAMMENFASSUNG" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "📊 Readiness Score: $($glpiObject.readiness_score)/100" -ForegroundColor Cyan
Write-Host "📋 Status: $($glpiObject.readiness_status)" -ForegroundColor Cyan
Write-Host ""
Write-Host "🔍 Details:" -ForegroundColor Yellow
$glpiObject.readiness_details | ForEach-Object { Write-Host "  $_" }
Write-Host ""
Write-Host "💾 Exportierte Dateien:" -ForegroundColor Yellow
Write-Host "  JSON: $jsonPath"
Write-Host "  CSV:  $csvPath"
Write-Host ""
Write-Host "✓ Prüfung abgeschlossen. Log-Datei: $logFile" -ForegroundColor Green

# Gebe Objekt aus für weitere Verarbeitung
return $glpiObject
