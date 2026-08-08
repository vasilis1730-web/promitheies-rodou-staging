param(
    [int]$Port = 8080
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Root = [System.IO.Path]::GetFullPath($PSScriptRoot)
$Separator = [System.IO.Path]::DirectorySeparatorChar
$RootPrefix = $Root.TrimEnd($Separator, [System.IO.Path]::AltDirectorySeparatorChar) + $Separator
$Loopback = [System.Net.IPAddress]::Parse('127.0.0.1')
$Listener = [System.Net.Sockets.TcpListener]::new($Loopback, $Port)

function Get-ContentType {
    param([string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.js'   { return 'text/javascript; charset=utf-8' }
        '.mjs'  { return 'text/javascript; charset=utf-8' }
        '.css'  { return 'text/css; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.png'  { return 'image/png' }
        '.svg'  { return 'image/svg+xml' }
        default { return 'application/octet-stream' }
    }
}

function Write-HttpResponse {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$Status,
        [string]$Reason,
        [string]$ContentType,
        [byte[]]$Body,
        [bool]$HeadOnly = $false
    )

    $Header = "HTTP/1.1 $Status $Reason`r`n" +
        "Content-Type: $ContentType`r`n" +
        "Content-Length: $($Body.Length)`r`n" +
        "Cache-Control: no-store`r`n" +
        "X-Content-Type-Options: nosniff`r`n" +
        "Connection: close`r`n`r`n"
    $HeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($Header)
    $Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)
    if (-not $HeadOnly -and $Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }
    $Stream.Flush()
}

try {
    $Listener.Start()
} catch {
    Write-Host ''
    Write-Host "ERROR: Port $Port is already in use or cannot be opened."
    Write-Host 'Close any older local server window and run start-local.bat again.'
    Write-Host ''
    Read-Host 'Press Enter to close'
    exit 1
}

$Url = "http://127.0.0.1:$Port/index.html"
Write-Host "The application is running at $Url"
Write-Host 'Close this window or press Ctrl+C to stop the local server.'

try {
    Start-Process $Url | Out-Null
} catch {
    Write-Host "Open this address manually: $Url"
}

try {
    while ($true) {
        $Client = $null
        $Stream = $null
        $Reader = $null
        try {
            $Client = $Listener.AcceptTcpClient()
            $Client.ReceiveTimeout = 5000
            $Client.SendTimeout = 5000
            $Stream = $Client.GetStream()
            $Reader = [System.IO.StreamReader]::new(
                $Stream,
                [System.Text.Encoding]::ASCII,
                $false,
                8192,
                $true
            )

            $RequestLine = $Reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($RequestLine)) {
                continue
            }

            do {
                $HeaderLine = $Reader.ReadLine()
            } while ($null -ne $HeaderLine -and $HeaderLine.Length -gt 0)

            $Parts = $RequestLine.Split(' ')
            if ($Parts.Length -lt 2) {
                $Body = [System.Text.Encoding]::UTF8.GetBytes('Bad Request')
                Write-HttpResponse $Stream 400 'Bad Request' 'text/plain; charset=utf-8' $Body
                continue
            }

            $Method = $Parts[0].ToUpperInvariant()
            if ($Method -ne 'GET' -and $Method -ne 'HEAD') {
                $Body = [System.Text.Encoding]::UTF8.GetBytes('Method Not Allowed')
                Write-HttpResponse $Stream 405 'Method Not Allowed' 'text/plain; charset=utf-8' $Body
                continue
            }

            try {
                $RequestUri = [System.Uri]::new("http://127.0.0.1:$Port$($Parts[1])")
                $PathValue = [System.Uri]::UnescapeDataString($RequestUri.AbsolutePath)
            } catch {
                $Body = [System.Text.Encoding]::UTF8.GetBytes('Bad Request')
                Write-HttpResponse $Stream 400 'Bad Request' 'text/plain; charset=utf-8' $Body ($Method -eq 'HEAD')
                continue
            }

            if ($PathValue -eq '/') {
                $PathValue = '/index.html'
            }

            $RelativePath = $PathValue.TrimStart('/').Replace('/', $Separator)
            $FullPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Root, $RelativePath))
            if (-not $FullPath.StartsWith($RootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $Body = [System.Text.Encoding]::UTF8.GetBytes('Bad Request')
                Write-HttpResponse $Stream 400 'Bad Request' 'text/plain; charset=utf-8' $Body ($Method -eq 'HEAD')
                continue
            }

            if (-not [System.IO.File]::Exists($FullPath)) {
                $Body = [System.Text.Encoding]::UTF8.GetBytes('Not Found')
                Write-HttpResponse $Stream 404 'Not Found' 'text/plain; charset=utf-8' $Body ($Method -eq 'HEAD')
                continue
            }

            $Body = [System.IO.File]::ReadAllBytes($FullPath)
            $ContentType = Get-ContentType $FullPath
            Write-HttpResponse $Stream 200 'OK' $ContentType $Body ($Method -eq 'HEAD')
        } catch {
            if ($null -ne $Stream -and $Stream.CanWrite) {
                try {
                    $Body = [System.Text.Encoding]::UTF8.GetBytes('Internal Server Error')
                    Write-HttpResponse $Stream 500 'Internal Server Error' 'text/plain; charset=utf-8' $Body
                } catch {
                    # Ignore a client that disconnected before the error response.
                }
            }
        } finally {
            if ($null -ne $Reader) { $Reader.Dispose() }
            if ($null -ne $Stream) { $Stream.Dispose() }
            if ($null -ne $Client) { $Client.Dispose() }
        }
    }
} finally {
    $Listener.Stop()
}
