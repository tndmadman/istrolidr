# Applied only to a locally extracted private-server client in .build/.
# Ensures the original game account profile and production URLs are untouched.
param([Parameter(Mandatory=$true)][string]$ApplicationDir)
$ErrorActionPreference = 'Stop'
$path=Join-Path ([IO.Path]::GetFullPath($ApplicationDir)) 'main.js'
$utf8=New-Object Text.UTF8Encoding($false)
$text=[IO.File]::ReadAllText($path)
function Swap([string]$inputText,[string]$needle,[string]$replacement) {
  $a=$inputText.IndexOf($needle,[StringComparison]::Ordinal)
  if($a -lt 0 -or $inputText.IndexOf($needle,$a+$needle.Length,[StringComparison]::Ordinal) -ge 0) {
    throw "Unsupported original game main.js: missing/duplicate anchor: $needle"
  }
  return $inputText.Substring(0,$a)+$replacement+$inputText.Substring($a+$needle.Length)
}
$text=Swap $text '  app = electron.app;' @'
  app = electron.app;
  // ISTROLIDR_PRIVATE: isolate private test player saves from Steam/online users.
  var privateProfile = path.join(app.getPath("userData"), "istrolidr-private");
  require("fs").mkdirSync(privateProfile, {recursive:true});
  app.setPath("userData", privateProfile);
'@
$text=Swap $text '  track = function(name, ops) {' @'
  track = function(name, ops) {
    // No telemetry or HTTP requests to the production game while testing.
    return;
'@
$text=Swap $text '    makeMenu();' @'
    makeMenu();
    // Block production HTTP(S) and WebSockets; allow only local test endpoints.
    electron.session.defaultSession.webRequest.onBeforeRequest(
      {urls:["http://*/*","https://*/*","ws://*/*","wss://*/*"]},
      function(details, callback) {
        var allowed=/^ws:\/\/(?:127\.0\.0\.1|localhost)(?::[0-9]+)?\//.test(details.url);
        callback({cancel:!allowed});
      }
    );
'@
[IO.File]::WriteAllText($path,$text,$utf8)
Write-Host 'Private server isolation enabled: local profile, production network disabled.'
