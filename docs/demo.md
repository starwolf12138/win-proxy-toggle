# CLI demo (isolated test key)

This transcript was produced against a temporary registry key, not the real system proxy:

```text
HKCU\Software\WinProxyToggle\Demo\<guid>
```

It shows the full state cycle.

```text
PS> .\src\proxy-toggle.ps1 status -SkipWinHttp
WinINET system proxy
  State          : ON
  ProxyServer    : 127.0.0.1:7890
  ProxyOverride  : <local>
  AutoConfigURL  : (none)

WinHTTP proxy
  Skipped

Environment
  HTTP_PROXY     :
  HTTPS_PROXY    :
  ALL_PROXY      :
  NO_PROXY       :

Administrator    : True
Saved state      : no

PS> .\src\proxy-toggle.ps1 disable -SkipWinHttp
System proxy disabled. Saved state: %TEMP%\WinProxyToggle-demo-<guid>.json
WinHTTP: Skipped

PS> .\src\proxy-toggle.ps1 status -SkipWinHttp
WinINET system proxy
  State          : OFF
  ProxyServer    : 127.0.0.1:7890
  ProxyOverride  : <local>
  AutoConfigURL  : (none)

WinHTTP proxy
  Skipped

Environment
  HTTP_PROXY     :
  HTTPS_PROXY    :
  ALL_PROXY      :
  NO_PROXY       :

Administrator    : True
Saved state      : yes

PS> .\src\proxy-toggle.ps1 restore -SkipWinHttp
Previous proxy state restored. WinHTTP: Skipped
```

Note that `ProxyServer` remains visible while the proxy is OFF; that is intentional. It is the value that `enable`/`restore` can put back.
