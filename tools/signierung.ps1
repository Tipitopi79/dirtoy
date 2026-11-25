# Bibliothek fuer Schluessel erzeugen und Signieren (wird von neuer-schluessel.ps1, signieren.ps1 und den Tests geladen).
# Setzt voraus, dass src\core\15-signatur.ps1 schon geladen ist.
Add-Type -AssemblyName System.Security

# Erzeugt ein RSA-3072-Schluesselpaar als selbstsigniertes Zertifikat und speichert es passwortgeschuetzt als PFX.
# Rueckgabe: oeffentliches Zertifikat als Base64 (das ist der Wert fuer $script:signingCert).
function New-SigningKey([string]$pfxPath, [securestring]$pass) {
    if (Test-Path -LiteralPath $pfxPath) { throw "Es gibt schon einen Schluessel: $pfxPath" }
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 3072
    $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest 'CN=DirToy Update-Signatur', $rsa, ([System.Security.Cryptography.HashAlgorithmName]::SHA256), ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(30))
    $dir = Split-Path -Parent $pfxPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    [System.IO.File]::WriteAllBytes($pfxPath, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $pass))
    return [Convert]::ToBase64String($cert.RawData)
}

# Signiert $data mit dem Schluessel aus der PFX-Datei. Rueckgabe: Signatur als Base64.
function New-UpdateSignature([byte[]]$data, [string]$pfxPath, [securestring]$pass) {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $pfxPath, $pass
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    if (-not $rsa) { throw 'Die PFX-Datei enthaelt keinen privaten Schluessel.' }
    try {
        $sig = $rsa.SignData((Convert-ForSignature $data), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        return [Convert]::ToBase64String($sig)
    } finally { $rsa.Dispose() }
}

# Passphrase abfragen (wird nie als Klartext gespeichert oder ausgegeben)
function Read-Passphrase([string]$prompt) { return (Read-Host -AsSecureString $prompt) }
function ConvertTo-PlainText([securestring]$s) {
    $p = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}
