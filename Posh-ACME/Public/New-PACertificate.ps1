function New-PACertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)]
        [string[]]$Domain,
        [string[]]$Contact,
        [ValidateScript({Test-ValidKeyLength $_ -ThrowOnFail})]
        [string]$CertKeyLength='2048',
        [switch]$NewCertKey,
        [switch]$AcceptTOS,
        [ValidateScript({Test-ValidKeyLength $_ -ThrowOnFail})]
        [string]$AccountKeyLength='ec-256',
        [ValidateScript({Test-ValidDirUrl $_ -ThrowOnFail})]
        [Alias('location')]
        [string]$DirectoryUrl='LE_PROD',
        [ValidateScript({Test-ValidDnsPlugin $_ -ThrowOnFail})]
        [string[]]$DnsPlugin,
        [hashtable]$PluginArgs,
        [switch]$OCSPMustStaple,
        [switch]$Force,
        [int]$DNSSleep=120,
        [int]$ValidationTimeout=60,
        [int]$CertIssueTimeout=60
    )

    # Make sure we have a server set. But don't override the current
    # one unless explicitly specified.
    $dir = Get-PAServer
    if (!$dir -or ('DirectoryUrl' -in $PSBoundParameters.Keys)) {
        Set-PAServer $DirectoryUrl
    } else {
        # refresh the directory info (which should also get a fresh nonce)
        Update-PAServer
    }
    Write-Verbose "Using directory $($dir.location)"

    # Make sure we have an account set. If Contact and/or AccountKeyLength
    # were specified and don't match the current one but do match a different,
    # one, switch to that. If the specified details don't match any existing
    # accounts, create a new one.
    $acct = Get-PAAccount
    $accts = @(Get-PAAccount -List -Refresh -Status 'valid' @PSBoundParameters)
    if (!$accts -or $accts.Count -eq 0) {
        # no matches for the set of filters, so create new
        Write-Verbose "Creating a new $AccountKeyLength account with contact: $($Contact -join ', ')"
        $acct = New-PAAccount @PSBoundParameters
    } elseif ($accts.Count -gt 0 -and (!$acct -or $acct.id -notin $accts.id)) {
        # we got matches, but there's no current account or the current one doesn't match
        # so set the first match as current
        $acct = $accts[0]
        Set-PAAccount $acct.id
    }
    Write-Verbose "Using account $($acct.id)"

    # Check for an existing order from the MainDomain for this call and create a new
    # one if:
    # - -Force was used
    # - it doesn't exist
    # - is invalid
    # - is valid and within the renewal window
    # - is pending, but expired
    # - has different KeyLength
    # - has different SANs
    $order = $null
    try { $order = Get-PAOrder $Domain[0] -Refresh } catch {}
    $SANs = @($Domain | Where-Object { $_ -ne $Domain[0] }) | Sort-Object
    if ($Force -or !$order -or
        $order.status -eq 'invalid' -or
        ($order.status -eq 'valid' -and (Get-Date) -ge (Get-Date $order.RenewAfter)) -or
        ($order.status -eq 'pending' -and (Get-Date) -gt (Get-Date $order.expires)) -or
        $CertKeyLength -ne $order.KeyLength -or
        ($SANs -join ',') -ne (($order.SANs | Sort-Object) -join ',') ) {

        Write-Verbose "Creating a new order for $($Domain -join ', ')"
        $order = New-PAOrder $Domain $CertKeyLength -Force
    } else {
        $order | Set-PAOrder
    }
    Write-Verbose "Using order for $($order.MainDomain) with status $($order.status)"

    # deal with "pending" orders that may have authorization challenges to prove
    if ($order.status -eq 'pending') {
        Submit-ChallengeValidation @PSBoundParameters

        # refresh the order status
        $order = Get-PAOrder -Refresh
    }

    # if we've reached this point, it should mean that we're ready to finalize the
    # order. The order status is supposed to be 'ready', but that ready status is a
    # recent addition to the ACME spec and LetsEncrypt hasn't implemented it yet.
    # So for now, we have to check the status of the order's authorizations to make
    # sure it's ready for finalization.
    $auths = $order | Get-PAAuthorizations
    if ($order.status -eq 'ready' -or
        ($order.status -eq 'pending' -and !($auths | Where-Object { $_.status -ne 'valid' })) ) {

        # make the finalize call
        Write-Verbose "Finalizing the order."
        Submit-OrderFinalize @PSBoundParameters

        # refresh the order status
        $order = Get-PAOrder -Refresh
    }

    # The order should now be finalized and the status should be valid. The only
    # thing left to do is download the cert and chain and write the results to
    # disk
    if ($order.status -eq 'valid') {
        if ([string]::IsNullOrWhiteSpace($order.certificate)) {
            throw "Order status is valid, but no certificate URL was found."
        }

        # build output paths
        $certFile      = Join-Path $script:OrderFolder 'cert.cer'
        $keyFile       = Join-Path $script:OrderFolder 'cert.key'
        $chainFile     = Join-Path $script:OrderFolder 'chain.cer'
        $fullchainFile = Join-Path $script:OrderFolder 'fullchain.cer'
        $pfxFile       = Join-Path $script:OrderFolder 'cert.pfx'

        # Download the cert chain, split it up, and generate a PFX
        Invoke-WebRequest $order.certificate -OutFile $fullchainFile
        Split-CertChain $fullchainFile $certFile $chainFile
        Export-CertPfx $certFile $keyFile $pfxFile

        Write-Verbose "Wrote certificate files to $($script:OrderFolder)"
    }





    <#
    .SYNOPSIS
        Request a new certificate

    .DESCRIPTION
        This is the primary function for this module and is capable executing the entire ACME certificate request process from start to finish without any prerequisite steps. However, utilizing the module's other functions can enable more complicated workflows and reduce the number of parameters you need to supply to this function.

    .PARAMETER Domain
        One or more domain names to include in this order/certificate. The first one in the list will be considered the "MainDomain" and be set as the subject of the finalized certificate.

    .PARAMETER Contact
        One or more email addresses to associate with this certificate. These addresses will be used by the ACME server to send certificate expiration notifications or other important account notices.

    .PARAMETER CertKeyLength
        The type and size of private key to use for the certificate. For RSA keys, specify a number between 2048-4096 (divisible by 128). For ECC keys, specify either 'ec-256' or 'ec-384'. Defaults to '2048'.

    .PARAMETER NewCertKey
        If specified, a new private key will be generated for the certificate. Otherwise, a new key will only be generated if one doesn't already exist for the primary domain or the key type or length have changed from the previous order.

    .PARAMETER AcceptTOS
        This switch is required when creating a new account as part of a certificate request. It implies you have read and accepted the Terms of Service for the ACME server you are connected to. The first time you connect to an ACME server, a link to the Terms of Service should have been displayed.

    .PARAMETER AccountKeyLength
        The type and size of private key to use for the account associated with this certificate. For RSA keys, specify a number between 2048-4096 (divisible by 128). For ECC keys, specify either 'ec-256' or 'ec-384'. Defaults to 'ec-256'.

    .PARAMETER DirectoryUrl
        Either the URL to an ACME server's "directory" endpoint or one of the supported short names. Currently supported short names include LE_PROD (LetsEncrypt Production v2) and LE_STAGE (LetsEncrypt Staging v2). Defaults to 'LE_PROD'.

    .PARAMETER DnsPlugin
        One or more DNS plugin names to use for this order's DNS challenges. If no plugin is specified, the "Manual" plugin will be used. If the same plugin is used for all domains in the order, you can just specify it once. Otherwise, you should specify as many plugin names as there are domains in the order and in the same sequence as the ACME order.

    .PARAMETER PluginArgs
        A hashtable containing the plugin arguments to use with the specified DnsPlugin list. So if a plugin has a -MyText string and -MyNumber integer parameter, you could specify them as @{MyText='text';MyNumber=1234}.

    .PARAMETER OCSPMustStaple
        If specified, the certificate generated for this order will have the OCSP Must-Staple flag set.

    .PARAMETER Force
        If specified, a new certificate order will always be created regardless of the status of a previous order for the same primary domain. Otherwise, the previous order still in progress will be used instead.

    .PARAMETER DnsSleep
        Number of seconds to wait for DNS changes to propagate before asking the ACME server to validate DNS challenges. Default is 120.

    .PARAMETER ValidationTimeout
        Number of seconds to wait for the ACME server to validate the challenges after asking it to do so. Default is 60. If the timeout is exceeded, an error will be thrown.

    .PARAMETER CertIssueTimeout
        Number of seconds to wait for the server to finish the order before giving up and throwing an error.

    .EXAMPLE
        New-PACertificate site1.example.com -AcceptTOS

        This is the minimum parameters needed to generate a certificate for the specified site if you haven't already setup an ACME account. It will prompt you to add the required DNS TXT record manually. Once you have an account created, you can omit the -AcceptTOS parameter.

    .EXAMPLE
        New-PACertificate 'site1.example.com','site2.example.com' -Contact admin@example.com

        Request a SAN certificate with multiple names and have notifications sent to the specified email address.

    .EXAMPLE
        New-PACertificate '*.example.com','example.com'

        Request a wildcard certificate that includes the root domain as a SAN.

    .LINK
        Project: https://github.com/rmbolger/Posh-ACME

    .LINK
        Submit-Renewal

    .LINK
        Get-DnsPlugins

    #>
}