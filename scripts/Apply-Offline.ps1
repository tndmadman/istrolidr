# Offline-only patch for a *local* extracted Istrolid application.
# Keeps copyrighted client source out of Git. Fail closed on unknown game releases.
param(
    [Parameter(Mandatory = $true)][string]$ApplicationDir
)
$ErrorActionPreference = 'Stop'
$ApplicationDir = [IO.Path]::GetFullPath($ApplicationDir)
$bundlePath = Join-Path $ApplicationDir 'js\istrolid.cat.js'
$mainPath = Join-Path $ApplicationDir 'main.js'
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)

function Replace-Once([string]$inputText, [string]$needle, [string]$replacement, [string]$description) {
    $first = $inputText.IndexOf($needle, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "Offline patch unsupported game version: missing $description" }
    if ($inputText.IndexOf($needle, $first + $needle.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Offline patch unsupported game version: ambiguous $description"
    }
    return $inputText.Substring(0, $first) + $replacement + $inputText.Substring($first + $needle.Length)
}

$bundle = [IO.File]::ReadAllText($bundlePath, $utf8)
$main = [IO.File]::ReadAllText($mainPath, $utf8)
if ($bundle.Contains('ISTROLIDR_OFFLINE') -or $main.Contains('ISTROLIDR_OFFLINE')) {
    throw 'Offline patch already applied; clean/rebuild before retrying.'
}

# Side-effect-free stub compatible with rootNet.send(), reconnect UI and multiplayer listings.
# CLOSED is intentional: account.onbeforeunload must never try a remote save or prevent exit.
$rootStub = @'
    window.rootNet = {
      offline: true,
      servers: {},
      serversStats: {},
      gameKey: null,
      websocket: {readyState: WebSocket.CLOSED},
      connect: function() { return; },
      send: function() { return; },
      sendMode: function() { return; },
      playerMode: function() { return "local*"; }
    };
    // Offline profile uses its own Electron userData directory (see main.js patch).
    window.commander = db.load("commander") || {
      name: "OfflineCommander",
      color: account.color || [120, 180, 250, 255],
      buildBar: [],
      fleet: {},
      galaxy: {},
      challenges: {},
      settings: {},
      friends: {},
      mutes: {}
    };
    account.fix();
    account.name = commander.name;
    account.signedIn = true;
    account.autoSigningIn = false;
    account.error = false;
    db.save("commander", account.simpleCommander());
    console.info("IstrolidR offline sandbox: no game servers, account login, or telemetry.");
'@
$bundle = Replace-Once $bundle '    ua = detect.parse(navigator.userAgent);' @'
    ua = detect.parse(navigator.userAgent);
    window.ISTROLIDR_OFFLINE = true;
    window.track = function() { return; };
'@ 'renderer startup telemetry guard'
$bundle = Replace-Once $bundle '    window.rootNet = new RootConnection(rootAddress);' $rootStub 'root WebSocket creation'
$bundle = Replace-Once $bundle '  ui.reconnectRoot = function() {' @'
  ui.reconnectRoot = function() {
    if (window.ISTROLIDR_OFFLINE) { return; }
'@ 'root connectivity warning'
$bundle = Replace-Once $bundle '    startInitialSandbox();' @'
    startInitialSandbox();
    if (window.ISTROLIDR_OFFLINE) { battleMode.joinLocal(); }
'@ 'sandbox entry'
# Normal multiplayer is still present in original client but cannot connect, as all
# renderer remote requests are blocked by Electron session webRequest below.

$main = Replace-Once $main '  app = electron.app;' @'
  app = electron.app;

  // ISTROLIDR_OFFLINE: use separate profile, never touch online login/cache saves.
  var offlineProfile = path.join(app.getPath("userData"), "istrolidr-offline");
  require("fs").mkdirSync(offlineProfile, {recursive: true});
  app.setPath("userData", offlineProfile);
'@ 'Electron app bootstrap'
$main = Replace-Once $main '    makeMenu();' @'
    makeMenu();
    // Block ALL browser HTTP(S)/WebSocket requests in this offline build. Local
    // game assets use file:// and remain available. Does not intercept Node HTTP.
    electron.session.defaultSession.webRequest.onBeforeRequest(
      {urls: ["http://*/*", "https://*/*", "ws://*/*", "wss://*/*"]},
      function(details, callback) { callback({cancel: true}); }
    );
'@ 'Electron session bootstrap'
# The original catch-all error reporter sends exceptions via Node http.request.
$main = Replace-Once $main '    return track("electron_error", {' '    return console.error("ISTROLIDR_OFFLINE Electron exception", {' 'process error reporting'
$main = Replace-Once $main '      title: "Istrolid",' '      title: "IstrolidR - Offline Sandbox",' 'offline window title'

# All expected anchors validated before either file is written.
[IO.File]::WriteAllText($bundlePath, $bundle, $utf8)
[IO.File]::WriteAllText($mainPath, $main, $utf8)
Write-Host 'Offline patch applied: local guest profile, root WebSocket disabled, telemetry disabled, network requests blocked.'
