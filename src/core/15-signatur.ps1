# Pruefung der Update-Signatur. Der Schluessel ($script:signingCert, Datei 16-signierschluessel.ps1) ist fest eingebaut;
# der private Teil liegt nur beim Entwickler (siehe tools\neuer-schluessel.ps1), nicht bei GitHub.

# Zeilenenden vereinheitlichen (CRLF -> LF), damit die Signatur unabhaengig von Git-Zeilenenden gilt.
# Latin1 bildet jedes Byte 1:1 auf ein Zeichen ab, es geht also nichts verloren.
function Convert-ForSignature([byte[]]$bytes) {
    $enc = [System.Text.Encoding]::GetEncoding(28591)
    return ,$enc.GetBytes($enc.GetString($bytes).Replace("`r`n", "`n"))
}

# $true nur, wenn $sigB64 (Base64, RSA-SHA256/PKCS1) eine gueltige Signatur von $data mit dem eingebauten Schluessel ist.
function Test-UpdateSignature([byte[]]$data, [string]$sigB64) {
    if (-not $script:signingCert) { throw 'Es ist kein Signaturschluessel eingebaut, Updates koennen nicht geprueft werden.' }
    try { $sig = [Convert]::FromBase64String(([string]$sigB64).Trim()) } catch { return $false }
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,[Convert]::FromBase64String($script:signingCert))
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
    try {
        return [bool]$rsa.VerifyData((Convert-ForSignature $data), $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } catch { return $false } finally { $rsa.Dispose() }
}
