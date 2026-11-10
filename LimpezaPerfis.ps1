#Requires -Version 5.1
<#
    Limpeza de Perfis de Usuário
    ----------------------------
    Mostra os perfis locais (os mesmos de sysdm.cpl > Perfis de Usuário),
    permite marcar vários e apagar de uma vez.

    A exclusão usa Win32_UserProfile (Remove-CimInstance), que é o mesmo
    mecanismo do botão "Excluir" do sysdm.cpl: remove a pasta C:\Users\<nome>
    E a entrada do registro (ProfileList). Não apaga a conta no AD/local.
#>

# ===================== CONFIGURAÇÃO =====================
# Pastas de perfil que NUNCA podem ser apagadas (nome da pasta em C:\Users).
# Adicione aqui as contas de TI / administrador da máquina.
$PerfisProtegidos = @(
    'Administrador',
    'Administrator',
    'Default',
    'Public'
)
$LogDir  = Join-Path $env:ProgramData 'LimpezaPerfis'
$LogFile = Join-Path $LogDir 'limpeza.log'
# ========================================================

# --- Reabre como administrador se necessário ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ===================== FUNÇÕES =====================
function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  [{1}]  {2}" -f (Get-Date), $env:USERNAME, $msg) -Encoding UTF8
    } catch {}
}

function Resolve-Usuario([string]$sid, [string]$pasta) {
    try {
        return (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        return "(conta inexistente) $pasta"
    }
}

function Convert-DwordToUInt32($v) {
    return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$v), 0)
}

# Último logon real do perfil. LastUseTime do WMI é pouco confiável no Win10/11
# (é atualizado por antivírus/backup), então preferimos o horário de carga do perfil.
function Get-UltimoUso($perfil) {
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($perfil.SID)"
    try {
        $p = Get-ItemProperty -Path $key -ErrorAction Stop
        if ($null -ne $p.LocalProfileLoadTimeHigh -and $null -ne $p.LocalProfileLoadTimeLow) {
            $hi = [int64](Convert-DwordToUInt32 $p.LocalProfileLoadTimeHigh)
            $lo = [int64](Convert-DwordToUInt32 $p.LocalProfileLoadTimeLow)
            $ft = ($hi -shl 32) -bor $lo
            if ($ft -gt 0) { return [DateTime]::FromFileTime($ft) }
        }
    } catch {}
    try {
        $ntuser = Join-Path $perfil.LocalPath 'NTUSER.DAT'
        if (Test-Path -LiteralPath $ntuser -ErrorAction SilentlyContinue) { return (Get-Item -LiteralPath $ntuser -Force).LastWriteTime }
    } catch {}
    if ($perfil.LastUseTime) { return $perfil.LastUseTime }
    return $null
}

# Tamanho da pasta ignorando junções (evita loops em "Application Data" etc.)
function Get-TamanhoPasta([string]$path) {
    $total = [int64]0
    if (-not (Test-Path -LiteralPath $path)) { return $total }
    $stack = New-Object System.Collections.Stack
    $stack.Push((New-Object System.IO.DirectoryInfo($path)))
    $n = 0
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            foreach ($f in $d.EnumerateFiles()) { $total += $f.Length }
            foreach ($s in $d.EnumerateDirectories()) {
                if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($s) }
            }
        } catch {}
        if ((++$n % 200) -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
    }
    return $total
}

function Get-EspacoLivreGB {
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    return [math]::Round($disk.FreeSpace / 1GB, 1)
}

# ===================== INTERFACE =====================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Limpeza de Perfis de Usuário'
$form.Size = New-Object System.Drawing.Size(1050, 620)
$form.MinimumSize = New-Object System.Drawing.Size(800, 400)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# --- Barra de botões ---
$top = New-Object System.Windows.Forms.FlowLayoutPanel
$top.Dock = 'Top'
$top.Height = 44
$top.Padding = New-Object System.Windows.Forms.Padding(6)
$top.WrapContents = $false

function New-Botao([string]$texto, [int]$largura = 110) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $texto
    $b.Width = $largura
    $b.Height = 28
    $top.Controls.Add($b)
    return $b
}

$btnAtualizar = New-Botao 'Atualizar'
$btnMarcar    = New-Botao 'Marcar todos'
$btnDesmarcar = New-Botao 'Desmarcar todos'
$btnTamanho   = New-Botao 'Calcular tamanhos' 130

$lblDias = New-Object System.Windows.Forms.Label
$lblDias.Text = '   Marcar sem uso há ≥'
$lblDias.AutoSize = $true
$lblDias.Margin = New-Object System.Windows.Forms.Padding(3, 8, 0, 0)
$top.Controls.Add($lblDias)

$numDias = New-Object System.Windows.Forms.NumericUpDown
$numDias.Minimum = 0; $numDias.Maximum = 3650; $numDias.Value = 30; $numDias.Width = 60
$numDias.Margin = New-Object System.Windows.Forms.Padding(3, 5, 0, 0)
$top.Controls.Add($numDias)

$btnPorDias = New-Botao 'dias' 50

$btnApagar = New-Object System.Windows.Forms.Button
$btnApagar.Text = 'APAGAR SELECIONADOS'
$btnApagar.Width = 180; $btnApagar.Height = 28
$btnApagar.BackColor = [System.Drawing.Color]::FromArgb(200, 40, 40)
$btnApagar.ForeColor = [System.Drawing.Color]::White
$btnApagar.FlatStyle = 'Flat'
$btnApagar.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnApagar.Margin = New-Object System.Windows.Forms.Padding(20, 3, 3, 3)
$top.Controls.Add($btnApagar)

# --- Grade ---
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeColumnsMode = 'Fill'
$grid.BackgroundColor = [System.Drawing.Color]::White

$colSel = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colSel.Name = 'Sel'; $colSel.HeaderText = 'Apagar'; $colSel.FillWeight = 7
[void]$grid.Columns.Add($colSel)

function Add-Coluna([string]$nome, [string]$titulo, [int]$peso, [type]$tipo, [string]$formato) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $nome; $c.HeaderText = $titulo; $c.FillWeight = $peso; $c.ReadOnly = $true
    $c.ValueType = $tipo
    if ($formato) { $c.DefaultCellStyle.Format = $formato }
    [void]$grid.Columns.Add($c)
    return $c
}
[void](Add-Coluna 'Usuario'   'Usuário'         25 ([string])   $null)
[void](Add-Coluna 'Pasta'     'Pasta do perfil' 25 ([string])   $null)
[void](Add-Coluna 'UltimoUso' 'Último logon'    14 ([datetime]) 'dd/MM/yyyy HH:mm')
$cDias = Add-Coluna 'Dias'    'Dias sem uso'    9  ([int])      'N0'
$cTam  = Add-Coluna 'TamMB'   'Tamanho (MB)'    10 ([double])   'N0'
[void](Add-Coluna 'Status'    'Status'          14 ([string])   $null)
$cDias.DefaultCellStyle.Alignment = 'MiddleRight'
$cTam.DefaultCellStyle.Alignment  = 'MiddleRight'

# --- Barra de status ---
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatus.Spring = $true; $lblStatus.TextAlign = 'MiddleLeft'
$lblSel = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblDisco = New-Object System.Windows.Forms.ToolStripStatusLabel
[void]$statusStrip.Items.Add($lblStatus)
[void]$statusStrip.Items.Add($lblSel)
[void]$statusStrip.Items.Add($lblDisco)

$form.Controls.Add($grid)
$form.Controls.Add($top)
$form.Controls.Add($statusStrip)
$grid.BringToFront()

# ===================== LÓGICA =====================
function Set-Status([string]$t) { $lblStatus.Text = $t; [System.Windows.Forms.Application]::DoEvents() }

function Update-Contagem {
    $n = 0
    foreach ($r in $grid.Rows) { if ($r.Cells['Sel'].Value -eq $true) { $n++ } }
    $lblSel.Text = "$n selecionado(s)   |"
    $lblDisco.Text = "Livre em ${env:SystemDrive} $(Get-EspacoLivreGB) GB"
}

function Get-Linhas-Liberadas { $grid.Rows | Where-Object { -not $_.Tag.Bloqueado } }

function Load-Perfis {
    $form.Cursor = 'WaitCursor'
    Set-Status 'Carregando perfis...'
    $grid.Rows.Clear()
    $sidAtual = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    $perfis = Get-CimInstance Win32_UserProfile |
        Where-Object { -not $_.Special -and $_.LocalPath } |
        Sort-Object LocalPath

    foreach ($p in $perfis) {
        $pasta   = Split-Path $p.LocalPath -Leaf
        $usuario = Resolve-Usuario $p.SID $pasta
        $ultimo  = Get-UltimoUso $p
        $dias    = if ($ultimo) { [int][math]::Floor(((Get-Date) - $ultimo).TotalDays) } else { $null }

        $bloq = $true
        if     ($p.Loaded)                       { $status = 'Em uso (logado)' }
        elseif ($p.SID -eq $sidAtual)            { $status = 'Você (atual)' }
        elseif ($PerfisProtegidos -contains $pasta) { $status = 'Protegido' }
        else                                     { $status = 'Pode apagar'; $bloq = $false }

        $vUltimo = if ($ultimo) { $ultimo } else { [DBNull]::Value }
        $vDias   = if ($null -ne $dias) { $dias } else { [DBNull]::Value }

        $i = $grid.Rows.Add($false, $usuario, $p.LocalPath, $vUltimo, $vDias, [DBNull]::Value, $status)
        $row = $grid.Rows[$i]
        $row.Tag = @{ SID = $p.SID; Bloqueado = $bloq }
        if ($bloq) {
            $row.Cells['Sel'].ReadOnly = $true
            $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
        }
    }
    $grid.ClearSelection()
    Update-Contagem
    Set-Status "$($grid.Rows.Count) perfil(is) encontrado(s). Linhas cinza não podem ser apagadas."
    $form.Cursor = 'Default'
}

$btnAtualizar.Add_Click({ Load-Perfis })

$btnMarcar.Add_Click({
    foreach ($r in Get-Linhas-Liberadas) { $r.Cells['Sel'].Value = $true }
    Update-Contagem
})

$btnDesmarcar.Add_Click({
    foreach ($r in $grid.Rows) { $r.Cells['Sel'].Value = $false }
    Update-Contagem
})

$btnPorDias.Add_Click({
    $lim = [int]$numDias.Value
    foreach ($r in Get-Linhas-Liberadas) {
        $d = $r.Cells['Dias'].Value
        $r.Cells['Sel'].Value = ($d -isnot [DBNull] -and $null -ne $d -and [int]$d -ge $lim)
    }
    Update-Contagem
})

$btnTamanho.Add_Click({
    $form.Cursor = 'WaitCursor'
    $total = 0.0
    foreach ($r in $grid.Rows) {
        $path = $r.Cells['Pasta'].Value
        Set-Status "Calculando tamanho de $path ..."
        $mb = [math]::Round((Get-TamanhoPasta $path) / 1MB, 0)
        $r.Cells['TamMB'].Value = [double]$mb
        if (-not $r.Tag.Bloqueado) { $total += $mb }
    }
    $form.Cursor = 'Default'
    Set-Status ("Tamanhos calculados. Perfis apagáveis somam ~{0:N1} GB." -f ($total / 1024))
})

# Atualiza a contagem assim que a caixinha é clicada
$grid.Add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty) { $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
})
$grid.Add_CellValueChanged({ param($s, $e) if ($e.ColumnIndex -eq 0) { Update-Contagem } })
$grid.Add_DataError({ param($s, $e) $e.ThrowException = $false })

$btnApagar.Add_Click({
    $sel = @($grid.Rows | Where-Object { $_.Cells['Sel'].Value -eq $true -and -not $_.Tag.Bloqueado })
    if ($sel.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Nenhum perfil marcado.', 'Limpeza de Perfis', 'OK', 'Information')
        return
    }

    $lista = $sel | Select-Object -First 20 | ForEach-Object { "  • $($_.Cells['Usuario'].Value)" }
    $lista = $lista -join "`n"
    if ($sel.Count -gt 20) { $lista += "`n  ... e mais $($sel.Count - 20)" }

    $resp = [System.Windows.Forms.MessageBox]::Show(
        "Apagar DEFINITIVAMENTE $($sel.Count) perfil(is)?`n`n$lista`n`nTodos os arquivos desses usuários (Área de Trabalho, Documentos, Downloads...) serão perdidos. Isso não pode ser desfeito.",
        'Confirmar exclusão', 'YesNo', 'Warning', 'Button2')
    if ($resp -ne 'Yes') { return }

    $form.Cursor = 'WaitCursor'
    $btnApagar.Enabled = $false
    $livreAntes = Get-EspacoLivreGB
    $ok = 0
    $falhas = @()
    $i = 0
    Write-Log "=== Início da limpeza: $($sel.Count) perfil(is) ==="

    foreach ($r in $sel) {
        $i++
        $sid   = $r.Tag.SID
        $nome  = $r.Cells['Usuario'].Value
        $pasta = $r.Cells['Pasta'].Value
        Set-Status "[$i/$($sel.Count)] Apagando $nome ..."
        try {
            # Busca de novo para garantir que o usuário não logou nesse meio-tempo
            $p = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction Stop
            if (-not $p)    { throw 'perfil não encontrado' }
            if ($p.Loaded)  { throw 'perfil em uso (usuário logado)' }
            Remove-CimInstance -InputObject $p -ErrorAction Stop
            if (Test-Path -LiteralPath $pasta) {
                Write-Log "AVISO  $nome  $pasta  (registro removido, mas sobrou parte da pasta)"
            }
            Write-Log "OK     $nome  $pasta  $sid"
            $ok++
        } catch {
            $msg = $_.Exception.Message
            $falhas += "• ${nome}: $msg"
            Write-Log "ERRO   $nome  $pasta  $sid  -> $msg"
        }
    }

    $livreDepois = Get-EspacoLivreGB
    $ganho = [math]::Round($livreDepois - $livreAntes, 1)
    Write-Log "=== Fim: $ok apagado(s), $($falhas.Count) falha(s), $ganho GB liberados ==="

    $btnApagar.Enabled = $true
    $form.Cursor = 'Default'
    Load-Perfis

    $texto = "$ok perfil(is) apagado(s).`nEspaço liberado: ~$ganho GB (livre agora: $livreDepois GB)."
    if ($falhas.Count) { $texto += "`n`nFalhas:`n" + ($falhas -join "`n") }
    $texto += "`n`nLog: $LogFile"
    $icone = if ($falhas.Count) { 'Warning' } else { 'Information' }
    [void][System.Windows.Forms.MessageBox]::Show($texto, 'Resultado', 'OK', $icone)
})

$form.Add_Shown({ Load-Perfis })
[void]$form.ShowDialog()
