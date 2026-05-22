param(
    [Parameter(Mandatory = $true)]
    [string]$P12Path,

    [Parameter(Mandatory = $true)]
    [string]$ProvisionProfilePath,

    [securestring]$P12Password,

    [string]$DevelopmentTeam,

    [string]$BundleId,

    [ValidateSet("development", "ad-hoc")]
    [string]$ExportMethod = "ad-hoc",

    [string]$Repo = "Anezium/Rokid-Lyrics-iOS"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI 'gh' is not available in PATH."
}

$resolvedP12 = (Resolve-Path -LiteralPath $P12Path).ProviderPath
$resolvedProfile = (Resolve-Path -LiteralPath $ProvisionProfilePath).ProviderPath
$keychainPassword = [guid]::NewGuid().ToString("N")

function ConvertTo-PlainText {
    param([securestring]$SecureValue)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Set-GitHubSecretValue {
    param(
        [string]$Name,
        [string]$Value
    )

    $processInfo = [Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = "gh"
    $processInfo.Arguments = "secret set `"$Name`" --repo `"$Repo`""
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false

    $process = [Diagnostics.Process]::Start($processInfo)
    $process.StandardInput.Write($Value)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        throw "Failed to set GitHub secret '$Name': $stderr"
    }

    if ($stdout.Trim()) {
        Write-Host $stdout.Trim()
    }
}

function Get-MobileProvisionMetadata {
    param([string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    $start = $text.IndexOf("<?xml")
    $end = $text.IndexOf("</plist>")

    if ($start -lt 0 -or $end -lt $start) {
        return @{}
    }

    $plist = $text.Substring($start, $end - $start + "</plist>".Length)
    $applicationIdentifier = [regex]::Match(
        $plist,
        "<key>application-identifier</key>\s*<string>([^<]+)</string>"
    ).Groups[1].Value
    $teamIdentifier = [regex]::Match(
        $plist,
        "<key>TeamIdentifier</key>\s*<array>\s*<string>([^<]+)</string>"
    ).Groups[1].Value

    $profileBundleId = $null
    if ($applicationIdentifier -match "^[^.]+\.([^\s]+)$") {
        $profileBundleId = $Matches[1]
    }

    @{
        ApplicationIdentifier = $applicationIdentifier
        TeamIdentifier = $teamIdentifier
        BundleId = $profileBundleId
    }
}

if (-not $P12Password) {
    $P12Password = Read-Host "P12 password" -AsSecureString
}

$profileMetadata = Get-MobileProvisionMetadata -Path $resolvedProfile

if (-not $DevelopmentTeam -and $profileMetadata.TeamIdentifier) {
    $DevelopmentTeam = $profileMetadata.TeamIdentifier
}

if (-not $BundleId) {
    if ($profileMetadata.BundleId -and $profileMetadata.BundleId -ne "*") {
        $BundleId = $profileMetadata.BundleId
    }
    else {
        $BundleId = "com.anezium.rokidlyrics"
    }
}

if (-not $DevelopmentTeam) {
    throw "DevelopmentTeam was not provided and could not be read from the provisioning profile."
}

$certificateBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($resolvedP12))
$profileBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($resolvedProfile))
$plainP12Password = ConvertTo-PlainText -SecureValue $P12Password

Set-GitHubSecretValue -Name "BUILD_CERTIFICATE_BASE64" -Value $certificateBase64
Set-GitHubSecretValue -Name "P12_PASSWORD" -Value $plainP12Password
Set-GitHubSecretValue -Name "PROVISION_PROFILE_BASE64" -Value $profileBase64
Set-GitHubSecretValue -Name "KEYCHAIN_PASSWORD" -Value $keychainPassword
Set-GitHubSecretValue -Name "DEVELOPMENT_TEAM" -Value $DevelopmentTeam
Set-GitHubSecretValue -Name "BUNDLE_ID" -Value $BundleId
Set-GitHubSecretValue -Name "EXPORT_METHOD" -Value $ExportMethod

Write-Host "Signing secrets updated for $Repo."
Write-Host "Team ID: $DevelopmentTeam"
Write-Host "Bundle ID: $BundleId"
Write-Host "Export method: $ExportMethod"
