param(
    [System.String]$serviceName,
    [System.String]$ODPPath,
    [System.String]$source_connection_string,
    [System.String]$destination_connection_string,
    [System.String]$commonLog,
    [System.Int16]$pause,
    [System.String]$workingDirectory
  )

  # инициируем подключение к БД Oracle
  Add-Type -LiteralPath $ODPPath
  $source_connection = New-Object Oracle.ManagedDataAccess.Client.OracleConnection($source_connection_string)
  $destination_connection = New-Object Oracle.ManagedDataAccess.Client.OracleConnection($destination_connection_string)

  $regex =[System.Text.RegularExpressions.Regex]::new("SERVICE_NAME\s{0,1}=\s{0,1}\w*")
  [System.String]$src_name = $regex.Match($source_connection.DataSource).Value.Split('=')[1].Trim() 
  [System.String]$dst_name = $regex.Match($destination_connection.DataSource).Value.Split('=')[1].Trim() 

  if( -not $(Test-Path -Path "$workingDirectory\\logs") ) { mkdir "$workingDirectory\\logs" }
  $log = "$workingDirectory\\logs\\$src_name-log.txt"

  try {
    $source_connection.Open()
  }
  catch { 
    & { Write-Warning $("{0}: failed to open connection: {1}" -f $src_name, $PSItem.Exception.Message) } 3>&1 >> $log
   }

  try {
    $destination_connection.Open()
  }
  catch { 
    & { Write-Warning $("{0}: failed to open connection: {1}" -f $dst_name, $PSItem.Exception.Message) } 3>&1 >> $log
   }

  if( $source_connection.State -ieq "Open" -and $destination_connection.State -ieq "Open" ) {
    & { Write-Output $( "{0}: transport to {1} is ready!" -f $src_name, $dst_name ) } >> $log
  }
  else {
    & { Write-Output $( "{0}: there's no transport to {1}" -f $src_name, $dst_name ) } >> $log
  }

  $messages = [System.Collections.Generic.Queue[System.String]]::new()

  $continue = $(Import-Clixml -Path "$workingDirectory\\control.xml") -ieq "Running"

  while( $continue ) {

    # проверяем соединения
    if( $source_connection.State -ieq "Closed" ) {
      try{
        $source_connection.Open()
      }
      catch {  }
    }
    if( $destination_connection.State -ieq "Closed" ) {
      try{
        $destination_connection.Open()
      }
      catch {  }
    }

    # переносим сообщения из очереди виртуальной БД в очередь .Net
    if( $source_connection.State -ieq "Open" ) {
      $command = $source_connection.CreateCommand()
      $command.CommandText = "SELECT * FROM AIS.GetUserQueue"
      try {
        $reader = $command.ExecuteReader()
        while( $reader.Read() ) {
          $messages.Enqueue( $reader.GetString() )
        }
      $reader.Despose()
      }
      catch {
        & { Write-Warning $( "{0}: failed to read messages: {1}" -f $src_name, $PSItem.Exception.Message ) } 3>&1 >> $log
      }
      $command.Dispose()
    }

    & { Write-Output $("{1}: messages received: {0}" -f $messages.Count, $src_name) } >> $log

    # переносим сообщения из очереди .Net в очередь эталонной БД
    if( $destination_connection.State -ieq "Open" -and $messages.Count -gt 0) {
      $command = $destinatoin_connection.CreateCommand()
      $command.CommandType = "StoredProcedure"
      $command.CommandText = "AIS.GetUserQueue"

      while( $messages.Count -gt 0 ) {
        $message = $messages.Dequeue()
        $command.CommandText = "AIS.SetUserQueue( $message )"
        try {
          $command.ExecuteNonQuery()
        }
        catch {
          & { Write-Warning $("{0}: failed to send messages" -f $PSItem.Exception.Message) } 3>&1 >> $log
        }
      }
      $command.Dispose()    
    }
    
    Start-Sleep -Seconds $pause
    $continue = $(Import-Clixml -Path "$workingDirectory\\control.xml") -ieq "Running"
  }

$source_connection.Close()
$destination_connection.Close() 
  
