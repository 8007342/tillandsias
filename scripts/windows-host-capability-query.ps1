# @trace order:806-2r4s, order:809-7e4m, order:2421-7wvs
#
# windows-host-capability-query.ps1 - the ONE PowerShell query behind
# scripts/lua/windows-host-capability-probe.lua: RAM, OS version, NPUs and GPUs as one
# compact JSON object. A FILE, not a -Command string: the command policy refuses shell
# strings (1252-fg9e). THE DEVICE FILTER IS A CLASS, NEVER A NAME REGEX (a /NPU/
# pattern matched four USB HID devices, 2026-08-18).
$ErrorActionPreference = "Stop"
$npus = @(Get-PnpDevice -PresentOnly | Where-Object { $_.Class -eq "ComputeAccelerator" })
$gpus = @(Get-PnpDevice -PresentOnly | Where-Object { $_.Class -eq "Display" })
function DriverVersion($id) {
    try { (Get-PnpDeviceProperty -InstanceId $id -KeyName "DEVPKEY_Device_DriverVersion").Data }
    catch { $null }
}
$out = [ordered]@{
    ram_bytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    os_version = [string](Get-CimInstance Win32_OperatingSystem).Version
    npus = @($npus | ForEach-Object {
        [ordered]@{ name = $_.FriendlyName; status = $_.Status
                    instance_id = $_.InstanceId; driver = (DriverVersion $_.InstanceId) } })
    gpus = @($gpus | ForEach-Object {
        [ordered]@{ name = $_.FriendlyName; status = $_.Status
                    instance_id = $_.InstanceId; driver = (DriverVersion $_.InstanceId) } })
}
$out | ConvertTo-Json -Depth 6 -Compress
