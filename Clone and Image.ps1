Param(
  [Parameter(Position=0,mandatory=$true)]
  [string]$rgName,
  [Parameter(Position=1,mandatory=$true)]
  [string]$vmName,
  [Parameter(Position=2,mandatory=$true)]
  [string]$userName,
  [Parameter(Position=3,mandatory=$true)]
  [string]$password,
  [Parameter(Position=4,mandatory=$true)]
  [string]$location
)

Login-AzureRmAccount

$vm = Get-AzureRmVM -ResourceGroupName $rgName -Name $vmName
$disks = Get-AzureRmDisk -ResourceGroupName $rgName | Where {$_.ManagedBy -match $vmName}

#Create disk snapshots
foreach ($disk in $disks)
{
    $storageType = $disk.AccountType
    $snapshotConfig = New-AzureRmSnapshotConfig -SourceUri $disk.Id -CreateOption Copy -Location $Location
    $snapshot = New-AzureRmSnapshot -Snapshot $snapshotConfig -ResourceGroupName $rgName -SnapshotName "$($disk.Name)_snapshot"
    $diskConfig = New-AzureRmDiskConfig -AccountType $storageType -Location $location -CreateOption Copy -SourceResourceId $snapshot.Id
    New-AzureRmDisk -Disk $diskConfig -ResourceGroupName $rgName -DiskName "$($disk.Name)_image"
}


$osDisk = Get-AzureRmDisk -ResourceGroupName $rgName | Where {$_.Name -match "image" -and $_.ostype -ne $null -and $_.ManagedBy -eq $null}
$dataDisks = Get-AzureRmDisk -ResourceGroupName $rgName | Where {$_.Name -match "image" -and $_.ostype -eq $null -and $_.ManagedBy -eq $null}
$virtualMachineSize = $vm.HardwareProfile.VmSize
$virtualMachineName = "$($vm.Name)-Image"
$osType = $osDisk.OsType

#Initialize virtual machine configuration
$VirtualMachine = New-AzureRmVMConfig -VMName $virtualMachineName -VMSize $virtualMachineSize

#Use the Managed Disk Resource Id to attach it to the virtual machine. Please change the OS type to linux if OS disk has linux OS
if ($osType -eq "Linux"){
    $VirtualMachine = Set-AzureRmVMOSDisk -VM $VirtualMachine -ManagedDiskId $osDisk.Id -CreateOption Attach -Linux 
}
else {
    $VirtualMachine = Set-AzureRmVMOSDisk -VM $VirtualMachine -ManagedDiskId $osDisk.Id -CreateOption Attach -Windows
}
#Create a public IP for the VM  
$publicIp = New-AzureRmPublicIpAddress -Name ($VirtualMachineName.ToLower()+'_ip') -ResourceGroupName $rgName -Location $snapshot.Location -AllocationMethod Dynamic

#Get the virtual network where virtual machine will be hosted
$vnet = Get-AzureRmVirtualNetwork -ResourceGroupName $rgName

# Create NIC in the first subnet of the virtual network 
$nic = New-AzureRmNetworkInterface -Name ($VirtualMachineName.ToLower()+'_nic') -ResourceGroupName $rgName -Location $location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $publicIp.Id

$VirtualMachine = Add-AzureRmVMNetworkInterface -VM $VirtualMachine -Id $nic.Id

#Create the virtual machine with Managed Disk
New-AzureRmVM -VM $VirtualMachine -ResourceGroupName $rgName -Location $location
$newVM = Get-AzureRmVM -ResourceGroupName $rgName -Name $virtualMachineName

#Attach data disks
if ($dataDisks -ne $null){
    foreach ($disk in $dataDisks)
    {
        az vm disk attach -g $rgName --vm-name $newVM.Name --disk $disk.Id   
    }
}
    

#Deprovision linux vm
$cmd = 'az vm extension set -g ' + $rgName + ' --vm-name ' + $virtualMachineName + ' -n customScript --publisher Microsoft.Azure.Extensions --settings "{\"fileUris\": [\"https://raw.githubusercontent.com/elad488/AzureImageFactory/master/deprovision.sh\"],\"commandToExecute\": \"./deprovision.sh ' + $userName + '\"}"'
cmd /c $cmd
$pip = (Get-AzureRmPublicIpAddress -ResourceGroupName $rgName -Name ($($virtualMachineName)+'_ip')).IpAddress
$session = New-SshSession -ComputerName $pip -Username $userName -Password $password 
Invoke-SshCommand -ComputerName $pip -Command 'pwd' -Verbose
Invoke-SshCommand -ComputerName $pip -Command 'sudo /usr/sbin/waagent -deprovision -force' -Verbose

#Create image
$imageName = "$virtualMachineName-image"
Stop-AzureRmVM -ResourceGroupName $rgName -Name $virtualMachineName -Force
Set-AzureRmVm -ResourceGroupName $rgName -Name $virtualMachineName -Generalized
$image = New-AzureRmImageConfig -Location $location -SourceVirtualMachineId $newVM.ID 
New-AzureRmImage -Image $image -ImageName $imageName -ResourceGroupName $rgName

#Delete resources
$resources = Get-AzureRmResource -ErrorAction SilentlyContinue | Where {$_.Name -ne $imageName -and $_.Name -ne $vmName -and $_.ResourceGroupName -eq $rgName -and $_.Kind -ne "Storage"} | Remove-AzureRmResource -Force -ErrorAction SilentlyContinue

