# C:\SteamShell\disable-controller-audio.ps1
Start-Sleep -Seconds 10
$eps = Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue
$targets = $eps | Where-Object {
    ($_.FriendlyName -match 'Wireless Controller|DualShock|DualSense|Xbox') -and
    ($_.FriendlyName -match 'Headset|Headphones')
}
foreach ($t in $targets) {
  try { Disable-PnpDevice -InstanceId $t.InstanceId -Confirm:$false } catch {}
}
# self-remove the RunOnce entry
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'DisableCtrlAudio' -ErrorAction SilentlyContinue
