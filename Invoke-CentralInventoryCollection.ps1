#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Zentrale Version für Startup/Login-Script oder GPO
    Sammelt Standort (via IP), Hardware und Entra ID/Intune Status
    Sendet Daten an zentralen Server (GLPI/REST API)

.DESCRIPTION
    Dieses Skript ist optimiert für:
    - Startup-Scripts (SYSTEM-Kontext)
    - Login-Scripts (Benutzer-Kontext)
    - GPO-Deployment
    - Zentrale Datensammlung
    
    Funktionen:
    - Automatische Standort-Ermittlung via IP-Adresse
    - Hardware-Inventar komplett
    - Entra ID / Intune / AD Status
    - Asynchroner Upload (blockiert nicht)
    - Offline-Cache bei Fehlern
    - Minimale Performance-Auswirkung

.PARAMETER ServerURL
    URL des zentralen Servers/GLPI (z.B. https://glpi.example.com/inventory)

.PARAMETER APIKey
    API-Schlüssel für Authentication

.PARAMETER Async
    Führt Upload asynchron aus (Standard: $true für Scripts)

.PARAMETER CacheDir
    Verzeichnis für Offline-Cache (Standard: C:\ProgramData\Inventory)

.EXAMPLE
    # Für Startup-Script (als SYSTEM):
    .\Invoke-CentralInventoryCollection.ps1 -ServerURL "https://glpi.example.com/inventory" -APIKey "your-api-key"

.EXAMPLE
    # Für Login-Script (als Benutzer):
    .\Invoke-CentralInventoryCollection.ps1 -ServerURL "https://glpi.example.com/inventory" -APIKey "your-api-key" -Async $true
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ServerURL = "",
    
    [Parameter(Mandatory=$false)]
    [string]$APIKey = "",
    
    [Parameter(Mandatory=$false)]
    [bool]$Async = $true,
    
    [Parameter(Mandatory=$false)]
    [string]$CacheDir = "C:\ProgramData\Inventory",
    
    [Parameter(Mandatory=$false)]
    [bool]$Verbose = $false
)

# ============================================================================
# KONFIGURATION
# ============================================================================

$Script:LogDir = Join-Path -Path $CacheDir -ChildPath "Logs"
$Script:CacheFile = Join-Path -Path $CacheDir -ChildPath "LastInventory.json"
$Script:OfflineCacheDir = Join-Path -Path $CacheDir -ChildPath "OfflineCache"
$Script:LockFile = Join-Path -Path $CacheDir -ChildPath "inventory.lock"

# Timeout für Netzwerk-Operationen (Sekunden)
$Script:NetworkTimeout = 10

# Minimales Intervall zwischen Uploads (Stunden)
$Script:MinUploadInterval = 24

# IP-zu-Standort Mapping (anpassen!)
$Script:LocationMapping = @{
    "192.168." = "Standort-A"
    "10.0." = "Standort-B"
    "172.16." = "Standort-C"
    "203.0.113." = "Homeoffice"
}

# ============================================================================
# FUNKTIONEN
# ============================================================================

function Initialize-InventoryEnvironment {
    <#
    .SYNOPSIS
        Initialisiert Verzeichnisse und Logging
    #>
    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }
    
    if (-not (Test-Path $Script:LogDir)) {
        New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    }
    
    if (-not (Test-Path $Script:OfflineCacheDir)) {
        New-Item -ItemType Directory -Path $Script:OfflineCacheDir -Force | Out-Null
    }
}

function Write-InventoryLog {
    <#
    .SYNOPSIS
        Schreibt Log-Einträge (minimal für Performance)
    #>
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    if ($Verbose) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logFile = Join-Path -Path $Script:LogDir -ChildPath "inventory_$(Get-Date -Format 'yyyyMMdd').log"
        Add-Content -Path $logFile -Value "[$timestamp] [$Level] $Message" -ErrorAction SilentlyContinue
    }
}

function Test-LockFile {
    <#
    .SYNOPSIS
        Prüft ob bereits ein Inventory läuft
        Verhindert Mehrfach-Ausführung
    #>
    if (Test-Path $Script:LockFile) {
        $lockAge = ((Get-Date) - (Get-Item $Script:LockFile).LastWriteTime).TotalMinutes
        if ($lockAge -lt 5) {  # Lockfile älter als 5 Minuten = outdated
            Write-InventoryLog "Inventory läuft bereits, überspringe Ausführung" "WARN"
            return $true
        }
        else {
            Remove-Item $Script:LockFile -ErrorAction SilentlyContinue
        }
    }
    
    # Erstelle Lock-File
    New-Item -ItemType File -Path $Script:LockFile -Force | Out-Null
    return $false
}

function Remove-LockFile {
    Remove-Item $Script:LockFile -ErrorAction SilentlyContinue
}

function Test-UploadInterval {
    <#
    .SYNOPSIS
        Prüft ob genug Zeit seit letztem Upload vergangen ist
    #>
    if (Test-Path $Script:CacheFile) {
        $lastUpload = (Get-Item $Script:CacheFile).LastWriteTime
        $hoursSinceUpload = ((Get-Date) - $lastUpload).TotalHours
        
        if ($hoursSinceUpload -lt $Script:MinUploadInterval) {
            Write-InventoryLog "Upload-Intervall nicht erreicht ($hoursSinceUpload von $($Script:MinUploadInterval) Stunden)" "INFO"
            return $false
        }
    }
    return $true
}

function Get-LocationFromIP {
    <#
    .SYNOPSIS
        Ermittelt Standort basierend auf IP-Adresse
    #>
    try {
        # Hole Primary IP-Adresse
        $ipAddresses = @()
        $nics = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=true" -ErrorAction SilentlyContinue
        
        foreach ($nic in $nics) {
            if ($nic.IPAddress) {
                $ipAddresses += $nic.IPAddress[0]
            }
        }
        
        $primaryIP = $ipAddresses | Select-Object -First 1
        
        if (-not $primaryIP) {
            return @{
                "IP" = "Unknown"
                "Location" = "Unknown"
                "LocationDetected" = $false
            }
        }
        
        # Suche Standort basierend auf IP-Prefix
        $detectedLocation = "Unknown"
        $locationDetected = $false
        
        foreach ($prefix in $Script:LocationMapping.Keys) {
            if ($primaryIP.StartsWith($prefix)) {
                $detectedLocation = $Script:LocationMapping[$prefix]
                $locationDetected = $true
                break
            }
        }
        
        Write-InventoryLog "Standort erkannt: $detectedLocation (IP: $primaryIP)" "INFO"
        
        return @{
            "IP" = $primaryIP
            "Location" = $detectedLocation
            "LocationDetected" = $locationDetected
            "AllIPs" = $ipAddresses
        }
    }
    catch {
        Write-InventoryLog "Fehler bei Standort-Erkennung: $_" "ERROR"
        return @{
            "IP" = "Error"
            "Location" = "Unknown"
            "LocationDetected" = $false
            "Error" = $_.Exception.Message
        }
    }
}

function Get-SystemHardware {
    <#
    .SYNOPSIS
        Sammelt Hardware-Informationen
    #>
    try {
        $hardware = @{}
        
        # Basis-Infos
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $hardware["ComputerName"] = $computerSystem.Name
        $hardware["Domain"] = $computerSystem.Domain
        $hardware["Manufacturer"] = $computerSystem.Manufacturer
        $hardware["Model"] = $computerSystem.Model
        $hardware["DomainMember"] = $computerSystem.PartOfDomain
        
        # BIOS / Serial
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        if ($bios) {
            $hardware["SerialNumber"] = $bios.SerialNumber
            $hardware["BIOSVersion"] = $bios.Version
            $hardware["BIOSManufacturer"] = $bios.Manufacturer
        }
        
        # CPU
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cpu) {
            $hardware["CPU"] = $cpu.Name
            $hardware["CPUCores"] = $cpu.NumberOfCores
            $hardware["CPUThreads"] = $cpu.ThreadCount
        }
        
        # RAM
        $ram = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum
        $hardware["RAMGb"] = [math]::Round($ram.Sum / 1GB, 2)
        
        # OS
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $hardware["OSName"] = $os.Caption
            $hardware["OSVersion"] = $os.Version
            $hardware["OSBuild"] = $os.BuildNumber
            $hardware["OSArchitecture"] = $os.OSArchitecture
            $hardware["InstallDate"] = $os.InstallDate
        }
        
        # Disk
        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
        $hardware["DiskInfo"] = @()
        foreach ($disk in $disks) {
            $hardware["DiskInfo"] += @{
                "Drive" = $disk.Name
                "TotalGB" = [math]::Round($disk.Size / 1GB, 2)
                "FreeGB" = [math]::Round($disk.FreeSpace / 1GB, 2)
            }
        }
        
        # TPM
        try {
            $tpm = Get-CimInstance -ClassName Win32_Tpm -Namespace "root\cimv2\security\microsofttpm" -ErrorAction SilentlyContinue
            $hardware["TPM20"] = $null -ne $tpm
        }
        catch {
            $hardware["TPM20"] = $false
        }
        
        # Secure Boot
        try {
            $hardware["SecureBoot"] = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
        }
        catch {
            $hardware["SecureBoot"] = $false
        }
        
        return $hardware
    }
    catch {
        Write-InventoryLog "Fehler bei Hardware-Erfassung: $_" "ERROR"
        return @{ "Error" = $_.Exception.Message }
    }
}

function Get-EntraIDIntuneStatus {
    <#
    .SYNOPSIS
        Prüft Entra ID und Intune Status
    #>
    try {
        $status = @{
            "IsAzureADJoined" = $false
            "IsHybridJoined" = $false
            "IsIntuneRegistered" = $false
        }
        
        # Prüfe dsregcmd (nur Windows 10+)
        $dsregOutput = & dsregcmd /status 2>$null
        
        foreach ($line in $dsregOutput) {
            if ($line -match "AzureAdJoined\s*:\s*YES") { $status["IsAzureADJoined"] = $true }
            if ($line -match "DomainJoined\s*:\s*YES" -and $status["IsAzureADJoined"]) { $status["IsHybridJoined"] = $true }
            if ($line -match "TenantId\s*:\s*([a-f0-9-]+)") { $status["TenantID"] = $matches[1] }
            if ($line -match "DeviceId\s*:\s*([a-f0-9-]+)") { $status["DeviceID"] = $matches[1] }
        }
        
        # Prüfe Intune MDM
        $mdmPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
        if (Test-Path $mdmPath) {
            $enrollments = Get-ChildItem -Path $mdmPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -notmatch "^{" }
            $status["IsIntuneRegistered"] = $enrollments.Count -gt 0
        }
        
        return $status
    }
    catch {
        Write-InventoryLog "Fehler bei Entra ID/Intune Check: $_" "ERROR"
        return @{ "Error" = $_.Exception.Message }
    }
}

function New-InventoryPayload {
    <#
    .SYNOPSIS
        Erstellt das finale Payload-Objekt für den Server
    #>
    param(
        [hashtable]$Location,
        [hashtable]$Hardware,
        [hashtable]$EntraIntuneStatus
    )
    
    $payload = @{
        "timestamp" = Get-Date -Format "o"
        "scriptVersion" = "2.0.0"
        "executionContext" = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        "isSystem" = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name -eq "NT AUTHORITY\SYSTEM"
        
        # Standort-Infos
        "location" = $Location.Location
        "ip" = $Location.IP
        "locationDetected" = $Location.LocationDetected
        
        # Hardware
        "computerName" = $Hardware["ComputerName"]
        "domain" = $Hardware["Domain"]
        "manufacturer" = $Hardware["Manufacturer"]
        "model" = $Hardware["Model"]
        "serialNumber" = $Hardware["SerialNumber"]
        "bios" = @{
            "version" = $Hardware["BIOSVersion"]
            "manufacturer" = $Hardware["BIOSManufacturer"]
        }
        "cpu" = $Hardware["CPU"]
        "cpuCores" = $Hardware["CPUCores"]
        "cpuThreads" = $Hardware["CPUThreads"]
        "ramGB" = $Hardware["RAMGb"]
        "disks" = $Hardware["DiskInfo"]
        "os" = @{
            "name" = $Hardware["OSName"]
            "version" = $Hardware["OSVersion"]
            "build" = $Hardware["OSBuild"]
            "architecture" = $Hardware["OSArchitecture"]
            "installDate" = $Hardware["InstallDate"]
        }
        
        # Security
        "tpm20" = $Hardware["TPM20"]
        "secureBoot" = $Hardware["SecureBoot"]
        
        # Cloud
        "entraID" = @{
            "isAzureADJoined" = $EntraIntuneStatus.IsAzureADJoined
            "isHybridJoined" = $EntraIntuneStatus.IsHybridJoined
            "tenantID" = $EntraIntuneStatus.TenantID
            "deviceID" = $EntraIntuneStatus.DeviceID
        }
        "intune" = @{
            "isRegistered" = $EntraIntuneStatus.IsIntuneRegistered
        }
    }
    
    return $payload
}

function Send-InventoryToServer {
    <#
    .SYNOPSIS
        Sendet Inventar-Daten an zentralen Server
    #>
    param(
        [hashtable]$Payload,
        [bool]$Async = $true
    )
    
    if (-not $ServerURL -or -not $APIKey) {
        Write-InventoryLog "Server-Konfiguration nicht gesetzt, verwende Offline-Cache" "WARN"
        Save-OfflineCache -Payload $Payload
        return $false
    }
    
    $scriptBlock = {
        param($URL, $Key, $Data, $Timeout)
        
        try {
            $headers = @{
                "Content-Type" = "application/json"
                "Authorization" = "Bearer $Key"
                "User-Agent" = "Inventory-Agent/2.0"
            }
            
            $body = $Data | ConvertTo-Json -Depth 10 -Compress
            
            $response = Invoke-RestMethod `
                -Uri $URL `
                -Method Post `
                -Headers $headers `
                -Body $body `
                -TimeoutSec $Timeout `
                -ErrorAction Stop
            
            return @{
                "Success" = $true
                "Response" = $response
            }
        }
        catch {
            return @{
                "Success" = $false
                "Error" = $_.Exception.Message
            }
        }
    }
    
    if ($Async) {
        # Starte asynchronen Job
        $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $ServerURL, $APIKey, $Payload, $Script:NetworkTimeout
        Write-InventoryLog "Asynchroner Upload gestartet (Job: $($job.Id))" "INFO"
        return $true
    }
    else {
        # Synchroner Upload
        try {
            $result = & $scriptBlock -URL $ServerURL -Key $APIKey -Data $Payload -Timeout $Script:NetworkTimeout
            
            if ($result.Success) {
                Write-InventoryLog "Erfolgreich an Server übertragen" "SUCCESS"
                return $true
            }
            else {
                Write-InventoryLog "Server-Upload fehlgeschlagen: $($result.Error)" "ERROR"
                Save-OfflineCache -Payload $Payload
                return $false
            }
        }
        catch {
            Write-InventoryLog "Fehler beim Upload: $_" "ERROR"
            Save-OfflineCache -Payload $Payload
            return $false
        }
    }
}

function Save-OfflineCache {
    <#
    .SYNOPSIS
        Speichert Daten für späteren Upload
    #>
    param(
        [hashtable]$Payload
    )
    
    try {
        $filename = "inventory_$(Get-Date -Format 'yyyyMMdd_HHmmss_fff').json"
        $filepath = Join-Path -Path $Script:OfflineCacheDir -ChildPath $filename
        
        $Payload | ConvertTo-Json -Depth 10 | Out-File -FilePath $filepath -Encoding UTF8 -ErrorAction Stop
        
        Write-InventoryLog "Offline-Cache gespeichert: $filepath" "INFO"
    }
    catch {
        Write-InventoryLog "Fehler beim Speichern des Offline-Cache: $_" "ERROR"
    }
}

function Send-CachedInventory {
    <#
    .SYNOPSIS
        Sendet gecachte Daten an Server
        Wird regelmäßig von einem anderen Script aufgerufen
    #>
    if (-not (Test-Path $Script:OfflineCacheDir)) {
        return
    }
    
    $cacheFiles = Get-ChildItem -Path $Script:OfflineCacheDir -Filter "*.json" -ErrorAction SilentlyContinue
    
    foreach ($file in $cacheFiles) {
        try {
            $payload = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json -AsHashtable
            
            $headers = @{
                "Content-Type" = "application/json"
                "Authorization" = "Bearer $APIKey"
                "User-Agent" = "Inventory-Agent/2.0"
            }
            
            $body = $payload | ConvertTo-Json -Depth 10 -Compress
            
            $response = Invoke-RestMethod `
                -Uri $ServerURL `
                -Method Post `
                -Headers $headers `
                -Body $body `
                -TimeoutSec $Script:NetworkTimeout `
                -ErrorAction Stop
            
            Remove-Item -Path $file.FullName -Force
            Write-InventoryLog "Gecachte Daten erfolgreich übertragen: $($file.Name)" "SUCCESS"
        }
        catch {
            Write-InventoryLog "Fehler beim Übertragen von $($file.Name): $_" "ERROR"
        }
    }
}

function Save-LastInventoryInfo {
    <#
    .SYNOPSIS
        Speichert Inventar-Info für Tracking
    #>
    param(
        [hashtable]$Payload
    )
    
    try {
        $info = @{
            "timestamp" = $Payload.timestamp
            "computerName" = $Payload.computerName
            "ip" = $Payload.ip
            "location" = $Payload.location
            "uploadedAt" = Get-Date -Format "o"
        }
        
        $info | ConvertTo-Json | Out-File -FilePath $Script:CacheFile -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
        # Fehler beim Speichern ignorieren
    }
}

# ============================================================================
# HAUPTPROGRAMM
# ============================================================================

try {
    Initialize-InventoryEnvironment
    
    # Prüfe ob bereits ein Inventory läuft
    if (Test-LockFile) {
        exit 0
    }
    
    Write-InventoryLog "=== Inventory Collection gestartet ===" "INFO"
    
    # Prüfe Upload-Intervall
    if (-not (Test-UploadInterval)) {
        Write-InventoryLog "Zu häufige Ausführung, überspringe" "INFO"
        Remove-LockFile
        exit 0
    }
    
    # Sammle Daten
    Write-InventoryLog "Sammle Standort-Informationen..." "INFO"
    $location = Get-LocationFromIP
    
    Write-InventoryLog "Sammle Hardware-Informationen..." "INFO"
    $hardware = Get-SystemHardware
    
    Write-InventoryLog "Prüfe Entra ID / Intune Status..." "INFO"
    $entraIntuneStatus = Get-EntraIDIntuneStatus
    
    # Erstelle Payload
    $payload = New-InventoryPayload -Location $location -Hardware $hardware -EntraIntuneStatus $entraIntuneStatus
    
    # Sende an Server
    Write-InventoryLog "Sende Daten an Server..." "INFO"
    $sendSuccess = Send-InventoryToServer -Payload $payload -Async $Async
    
    # Speichere letzte Infos
    Save-LastInventoryInfo -Payload $payload
    
    # Versuche gecachte Daten zu senden
    Send-CachedInventory
    
    Write-InventoryLog "Inventory Collection abgeschlossen" "SUCCESS"
}
catch {
    Write-InventoryLog "Kritischer Fehler: $_" "ERROR"
}
finally {
    Remove-LockFile
}

# Exit ohne Fehler (verhindert dass Script bei Fehler Login blockiert)
exit 0
