# Dev2Live.ps1
# Main entry point for the Dev to Live File Copier

# --- Assembly Loading ---
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# --- Configuration Management ---
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$SettingsFile = Join-Path $ScriptPath "settings.json"

function Load-Settings {
    if (Test-Path $SettingsFile) {
        try {
            $json = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            if ($json.SourcePath) { $WPF_TxtSourcePath.Text = $json.SourcePath }
            if ($json.RemoteHost) { $WPF_TxtRemoteHost.Text = $json.RemoteHost }
            if ($json.RemoteUser) { $WPF_TxtRemoteUser.Text = $json.RemoteUser }
            if ($json.KeyPath)    { $WPF_TxtKeyPath.Text    = $json.KeyPath }
            if ($json.RemoteDest) { $WPF_TxtRemoteDest.Text = $json.RemoteDest }
        } catch {
            Log-Message "Error loading settings: $_"
        }
    }
}

function Save-Settings {
    $settings = @{
        SourcePath = $WPF_TxtSourcePath.Text
        RemoteHost = $WPF_TxtRemoteHost.Text
        RemoteUser = $WPF_TxtRemoteUser.Text
        KeyPath    = $WPF_TxtKeyPath.Text
        RemoteDest = $WPF_TxtRemoteDest.Text
    }
    $settings | ConvertTo-Json | Set-Content $SettingsFile
}

# --- Logging Helper ---
function Log-Message([string]$Message) {
    $timestamp = Get-Date -Format "HH:mm:ss"
    $WPF_TxtLog.AppendText("[$timestamp] $Message`n")
    $WPF_TxtLog.ScrollToEnd()
}

# --- Deployment Logic ---
function Start-Deployment {
    # Validate Inputs
    $source = $WPF_TxtSourcePath.Text
    $hostName = $WPF_TxtRemoteHost.Text
    $user = $WPF_TxtRemoteUser.Text
    $key = $WPF_TxtKeyPath.Text
    $dest = $WPF_TxtRemoteDest.Text

    if (-not (Test-Path $source)) {
        [System.Windows.MessageBox]::Show("Source path does not exist!", "Error", "OK", "Error")
        return
    }
    if ([string]::IsNullOrWhiteSpace($hostName) -or [string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($dest)) {
        [System.Windows.MessageBox]::Show("Please fill in all remote details.", "Error", "OK", "Warning")
        return
    }
    if (-not (Test-Path $key)) {
        [System.Windows.MessageBox]::Show("SSH Key file not found.", "Error", "OK", "Warning")
        return
    }

    # Confirm
    $confirm = [System.Windows.MessageBox]::Show("This will DELETE ALL FILES in '$dest' on '$hostName' and replace them with files from '$source'.`n`nAre you sure?", "Confirm Deployment", "YesNo", "Warning")
    if ($confirm -ne 'Yes') { return }

    Save-Settings
    Log-Message "Starting deployment..."
    $WPF_BtnDeploy.IsEnabled = $false
    
    # Run in background runspace or just process loop to avoid freezing UI (Simple approach: Process with DoEvents or Jobs)
    # Ideally use Start-ThreadJob but native PS5/Events compatible:
    
    try {
        # 1. Clear Remote Directory using SSH
        Log-Message "Clearing remote directory: $dest"
        # Using strict host key checking=no for ease of use in internal dev envs, usually safe for this context but usage dependent
        $sshArgs = @("-i", $key, "-o", "StrictHostKeyChecking=no", "$user@$hostName", "rm -rf $dest/*")
        
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = "ssh.exe"
        $pinfo.Arguments = $sshArgs -join " "
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        
        $p = [System.Diagnostics.Process]::Start($pinfo)
        $p.WaitForExit()
        
        $err = $p.StandardError.ReadToEnd()
        if ($p.ExitCode -ne 0) {
            throw "SSH Error: $err"
        }

        # 2. Copy Files using SCP
        Log-Message "Copying files from $source..."
        # scp -r -i key source/* user@host:dest/
        # Note: wildcards in scp can be tricky on windows shell.
        # Better to copy folder content. If source is C:\Dist, we want contents of Dist to go to /var/www/html/
        
        $scpArgs = @("-r", "-i", $key, "-o", "StrictHostKeyChecking=no", "$source/*", "$user@$hostName`:$dest")

        $pinfo.FileName = "scp.exe"
        $pinfo.Arguments = $scpArgs -join " "
        
        $p = [System.Diagnostics.Process]::Start($pinfo)
        $p.WaitForExit()
        
        $err = $p.StandardError.ReadToEnd()
        if ($p.ExitCode -ne 0) {
            throw "SCP Error: $err"
        }

        Log-Message "Deployment Complete Successfully!"
        [System.Windows.MessageBox]::Show("Deployment Complete!", "Success", "OK", "Information")

    } catch {
        Log-Message "FAILED: $_"
        [System.Windows.MessageBox]::Show("Deployment Failed.`n$_", "Error", "OK", "Error")
    } finally {
        $WPF_BtnDeploy.IsEnabled = $true
    }
}

# --- Build UI ---
$XamlPath = Join-Path $ScriptPath "MainWindow.xaml"
if (-not (Test-Path $XamlPath)) {
    Write-Error "MainWindow.xaml not found in $ScriptPath"
    exit
}

$inputXml = Get-Content $XamlPath -Raw
$inputXml = $inputXml -replace 'x:Name="([^"]*)"', 'Name="$1"' # Fix some PS XAML parsing quirks if any
$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($inputXml))
$Window = [System.Windows.Markup.XamlReader]::Load($reader)

# --- Find Controls ---
# Helper to find control by name in the window
function Get-Ctrl($Name) {
    $ctrl = $Window.FindName($Name)
    if ($null -eq $ctrl) { Write-Warning "Control $Name not found" }
    return $ctrl
}

$WPF_TxtSourcePath = Get-Ctrl "TxtSourcePath"
$WPF_BtnBrowseSource = Get-Ctrl "BtnBrowseSource"
$WPF_TxtRemoteHost = Get-Ctrl "TxtRemoteHost"
$WPF_TxtRemoteUser = Get-Ctrl "TxtRemoteUser"
$WPF_TxtKeyPath = Get-Ctrl "TxtKeyPath"
$WPF_BtnBrowseKey = Get-Ctrl "BtnBrowseKey"
$WPF_TxtRemoteDest = Get-Ctrl "TxtRemoteDest"
$WPF_BtnDeploy = Get-Ctrl "BtnDeploy"
$WPF_TxtLog = Get-Ctrl "TxtLog"

# --- Event Handlers ---
$WPF_BtnBrowseSource.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dialog.ShowDialog() -eq "OK") {
        $WPF_TxtSourcePath.Text = $dialog.SelectedPath
    }
})

$WPF_BtnBrowseKey.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Key Files|*.*"
    if ($dialog.ShowDialog() -eq "OK") {
        $WPF_TxtKeyPath.Text = $dialog.FileName
    }
})

$WPF_BtnDeploy.Add_Click({
    Start-Deployment
})

# --- Init ---
Load-Settings
$Window.ShowDialog() | Out-Null
