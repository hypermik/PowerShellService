param(
  [Parameter(Mandatory=$false, HelpMessage="Инсталляция сервиса")][switch]$Setup,
  [Parameter(Mandatory=$false, HelpMessage="Запуск сервиса")][switch]$Start,
  [Parameter(Mandatory=$false, HelpMessage="Используется SCM")][switch]$Service,
  [Parameter(Mandatory=$false, HelpMessage="Остановка сервиса")][switch]$Stop,
  [Parameter(Mandatory=$false, HelpMessage="Статус сервиса *пока не реализован*")][switch]$Status,
  [Parameter(Mandatory=$false, HelpMessage="Удаление сервиса")][switch]$Remove,
  [Parameter(Mandatory=$false, HelpMessage="Консольное приложение")][switch]$Console
)

<# 
пререквизиты:
Oracle Database Provider .Net (ODP.Net)
Microsoft.PowerShell.SecretManagement
Microsoft.PowerShell.SecretStore
----------------------------------------------------------------------------------------------------------------
#>

$ODPNETPath = "C:\app\oracle\product\18.0.0\client_1\ODP.NET\managed\common\Oracle.ManagedDataAccess.dll"
$cycle_pause = 15 # пауза в секундах

$destination_tns = "(DESCRIPTION = (ADDRESS_LIST = (ADDRESS = (PROTOCOL = TCP)(HOST = some.host.name)(PORT = 1521))) (CONNECT_DATA = (SERVICE_NAME = SMNAME)))"
$destination_login = "smlogin"

$source_tns = @(
)
$source_login = "smlogin"

<# 

----------------------------------------------------------------------------------------------------------------
#>

$serviceName = "BlitzTransport"
$serviceDisplayName = "SSO/Blitz Messaging Transport Service"

# !! Две косых черты - обязательно для кода на CSharp !!
$workingDirectory = "C:\\Users\\workingDir"

$scriptSelfName = "{0}\\{1}.ps1" -f $workingDirectory, $serviceName
$exeFullName = "{0}\\{1}.exe" -f $workingDirectory, $serviceName
$logOutput = "{0}\\{1}.log" -f $workingDirectory, $serviceName

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()

# функция траспортного сервиса

function TransportService {

  Export-Clixml -InputObject "Running" -Path "$workingDirectory\\control.xml"

  Register-EngineEvent PowerShell.Exiting -SupportEvent -Action {
    Write-Output "Service's getting shut down!"
    Export-Clixml -InputObject "Shutdown" -Path "$workingDirectory\\control.xml"
    
    Write-Output "Stopping jobs"
    do {
        $running_jobs = Get-Job | Where-Object { $_.State -match "Running" }
    }
    while($running_jobs.Count -gt 0)
    Get-Job | Remove-Job
    Write-Output "Process Stopped"
  }

  & { Write-Output $( "Service started at {0}" -f $(Get-Date) ) } >> $logOutput

  $destination_key = Get-Secret $destination_login -AsPlainText
  $dest_connection_string = "User Id={0};Password={1};Data Source={2}" -f $destination_login, $destination_key, $destination_tns
  
  $source_key = Get-Secret $source_login -AsPlainText

  $regex =[System.Text.RegularExpressions.Regex]::new("SERVICE_NAME\s{0,1}=\s{0,1}\w*")

  foreach( $tns in $source_tns ) {

    $dbServiceName = $regex.Match($tns).Value.Split('=')[1].Trim()

    $src_connection_string = "User Id={0};Password={1};Data Source={2}" -f $source_login, $source_key, $tns

    Start-Job -Name $dbServiceName -FilePath .\BackgroundJob.ps1 -ArgumentList $serviceName, $ODPNETPath, $src_connection_string, $dest_connection_string, $logOutput, $cycle_pause, $workingDirectory
  }
  
  while ($true) {
    $jobs = Get-Job
    foreach( $job in $jobs ) {
      Write-Output (Receive-Job $job).ChildJobs.Output
    }
    Start-Sleep -Seconds 1
  }
}

<# 

Код на CSharp для управления сервисом 
----------------------------------------------------------------------------------------------------------------
#>
$serviceHost = @"
using System;
using System.Diagnostics;

class $serviceName : System.ServiceProcess.ServiceBase {

  void InvokePSScript(string argument) {
    Process p = new Process();
    // Redirect the output stream of the child process.
    p.StartInfo.UseShellExecute = false;
    p.StartInfo.RedirectStandardOutput = true;
    p.StartInfo.FileName = @"C:\windows\system32\windowspowershell\v1.0\powershell.exe";
    p.StartInfo.Arguments = "-c & '$scriptSelfName' -" + argument;
    p.Start();
    string output = p.StandardOutput.ReadToEnd();
    p.WaitForExit();
  }

  protected override void OnStart(string [] args) {
    this.InvokePSScript("Start");
  }

  protected override void OnStop() {
    this.InvokePSScript("Stop");
  }
}

class ServiceHost {
  public static void Main() {
    System.ServiceProcess.ServiceBase.Run(new $serviceName());
  }
}
"@

<# 

Управление сервисом 
----------------------------------------------------------------------------------------------------------------
#>

function WriteToLog([System.Object]$info) {
  Add-Content  -LiteralPath "$logOutput" -Value $info
}

if( $Setup ) {
  try{
    Add-Type -TypeDefinition $serviceHost -Language CSharp -OutputAssembly $exeFullName  -OutputType ConsoleApplication -ReferencedAssemblies "System.ServiceProcess"
    New-Service $serviceName $exeFullName -DisplayName $serviceDisplayName -StartupType Automatic
    WriteToLog( "Service $ServiceName successfully installed" )
  }
  catch {
    WriteToLog( "Serive creation failed with exception: {0}" -f $PSItem.Exception.Message )
  }
  return
}

if( $Start ) {

  if($identity.IsSystem) {
    try{
      Start-Process "powershell.exe" -ArgumentList("-mta -c & '$scriptSelfName' -Service")
      Write-EventLog -LogName "Application" -Source "$serviceName" -EntryType Information -Message "Service started"
      WriteToLog( "Service started" )  
    }
    catch {
      WriteToLog( "Error occured while starting service. See the Application log for details." )
      Write-EventLog -LogName "Application" -Source "$serviceName" -EntryType Error -Message $("Exception occurred while starting service: {0}" -f $PSItem.Exception.Message)
    }
  }
  else {
    Start-Service $serviceName
  }
  return
}

if ( $Service ) {
  if($identity.IsSystem) {
    TransportService
  }
  else{
    Write-Output "Key [-Service] is for SCM only! Use key [-Console] instead."
  }
  return
}

if( $Stop ) {

  if($identity.IsSystem) {
    $processes = @(Get-WmiObject Win32_Process -filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -match ".*$serviceName.*-Service" })
    foreach( $process in $processes ) {
      try {
        Stop-Process $process.ProcessId
        Write-EventLog -LogName "Application" -Source "$serviceName" -EntryType Information -Message "Service stopped"
        WriteToLog( "Service stopped" )
          }
      catch {
        WriteToLog( "Error occured while stopping service. See the pplication log for details." )
        Write-EventLog -LogName "Application" -Source "$serviceName" -EntryType Error -Message $("Exception occurred while stopping service: {0}" -f $PSItem.Exception.Message)
      }
    }
  }
  else {
    Stop-Service $serviceName
  }
  return
}

if( $Remove ) {
  sc.exe delete $serviceName
  WriteToLog( "Service $ServiceName successfully removed" )
  return
}

if( $Console ) {
  TransportService
  #Start-Process "powershell.exe" -ArgumentList("-c & '$scriptSelfName' -Console -Service")
}

<# 

Справочная информация 
----------------------------------------------------------------------------------------------------------------
#>

Write-Output @"

Справка:
--------

Сервис пересылки сообщений 
Разработка: Волчков Михаил

Использование:
    ServiceExample.ps1 [ключ]

Ключи:
    -Setup      - инсталляция сервиса, требует административных привилегий
    -Start      - запуск сервиса (также можно запускать в SCM)
    -Stop       - остановка сервиса (также можно останавливать в SCM)
    -Remove     - удаление сервиса
    -Console    - запуск в отдельном консольном процессе без регистрации сервиса


"@
