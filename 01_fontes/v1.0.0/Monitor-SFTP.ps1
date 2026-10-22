#requires -Version 5.1
<#
Monitor-SFTP.ps1
Lista as pastas do servidor A por SFTP (WinSCP) ou pela simulacao local que imita o WinSCP
(config.json -> "Fonte": "Simulado" | "WinSCP"). Nunca baixa, altera nem remove arquivos.

  .\Monitor-SFTP.ps1                    # laco continuo: uma sessao SFTP aberta, consulta a cada IntervaloSegundos
  .\Monitor-SFTP.ps1 -UmCiclo           # um ciclo e sai
  .\Monitor-SFTP.ps1 -SalvarCredencial  # (WinSCP) grava a senha SFTP protegida por DPAPI; rodar com a conta do monitor
  .\Monitor-SFTP.ps1 -TestarEmail       # envia UM e-mail de teste pelo SMTP configurado (bloco Email) e sai; nao consulta o SFTP
#>
param([switch]$UmCiclo, [switch]$SalvarCredencial, [switch]$TestarEmail)

$ErrorActionPreference = 'Stop'
$raiz = $PSScriptRoot
$inv = [Globalization.CultureInfo]::InvariantCulture
$Rotulos = @{ OK = 'OK'; ATENCAO = 'ATENÇÃO'; CRITICO = 'CRÍTICO'; FALHA = 'FALHA NO MONITORAMENTO'; NORMALIZADO = 'MONITORAMENTO NORMALIZADO'; TESTE = 'TESTE DE E-MAIL' }

# ---------------------------------------------------------------- regras (sem E/S: testadas por Testar-Regras.ps1)

function Utc([DateTimeOffset]$d) { $d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $inv) }
function Minutos-Desde([string]$utc, [DateTimeOffset]$ate) { ($ate - [DateTimeOffset]::Parse($utc, $inv)).TotalMinutes }

function Nivel([double]$min, $Cfg) {
    # Tolerancia: o ciclo nunca cai no segundo exato; sem ela, 9m58s viraria "ainda OK" e o alerta atrasaria um ciclo.
    $tol = $Cfg.ToleranciaSegundos / 60
    if ($min -ge $Cfg.CriticoMinutos - $tol) { 'CRITICO' } elseif ($min -ge $Cfg.AtencaoMinutos - $tol) { 'ATENCAO' } else { 'OK' }
}

function Novo-Estado {
    [pscustomobject]@{
        FalhasSeguidas = 0; UltimoErro = $null; AlertaFalhaEnviado = $false
        Historico = @()                                                          # ultimos arquivos que sairam da pasta
        Pastas   = @{}                                                           # pasta -> ultima consulta OK (UTC)
        Arquivos = New-Object 'System.Collections.Generic.Dictionary[string,object]'  # sensivel a maiusculas, como o SFTP
    }
}

function Novo-Evento([string]$Tipo, $E, [string]$VistoAte, [string]$Em, [string]$Motivo, $Depois) {
    # Foto do arquivo no momento do evento (o objeto do estado continua mudando depois). Para auditoria.
    [pscustomobject]@{ Tipo = $Tipo; Pasta = $E.Pasta; Nome = $E.Nome; Tamanho = $E.Tamanho; Modificado = $E.Modificado
        DesdeUtc = $E.DesdeUtc; AnteriorUtc = $E.AnteriorUtc; AtencaoEnviada = $E.AtencaoEnviada; CriticoEnviado = $E.CriticoEnviado
        VistoAte = $VistoAte; Em = $Em; Motivo = $Motivo; Depois = $Depois }
}

function Aplicar-Ciclo {
    # Atualiza o estado com uma coleta e devolve o que precisa de alerta e os eventos de ciclo de vida dos
    # arquivos (ENTRADA / ALTERADO / SAIDA) para o log de auditoria. Pastas que falharam nao sao tocadas:
    # sem listagem nao da pra saber se o arquivo saiu, e "falha" nao pode virar "processado".
    param($Estado, $Observados, [string[]]$PastasFalha, [string]$Erro, [DateTimeOffset]$Agora, $Cfg)
    $agoraTxt = Utc $Agora
    $res = @{ Atencao = @(); Critico = @(); Falha = $false; Normalizado = $false; Eventos = @() }
    foreach ($pasta in $Cfg.PastasRemotas) {
        if ($PastasFalha -contains $pasta) { continue }
        $okAnterior = $Estado.Pastas[$pasta]
        $lacuna = $okAnterior -and (Minutos-Desde $okAnterior $Agora) -gt $Cfg.MaxLacunaMinutos
        $vistos = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($o in $Observados) {
            if ($o.Pasta -ne $pasta) { continue }
            [void]$vistos.Add($o.Chave)
            $e = $null; [void]$Estado.Arquivos.TryGetValue($o.Chave, [ref]$e)
            $mudou = $e -and ($e.Tamanho -ne $o.Tamanho -or $e.Modificado -ne $o.Modificado)
            # Mudanca sem lacuna = arquivo ainda sendo gravado (segue contando). Mudanca depois de uma lacuna =
            # pode ser outro arquivo com o mesmo nome: recomeca. Igual depois da lacuna = o mesmo: mantem contagem e alertas.
            if ($e -and $lacuna -and $mudou) {
                $res.Eventos += Novo-Evento 'SAIDA' $e $okAnterior $agoraTxt 'substituido por outro arquivo de mesmo nome apos lacuna nas consultas'
            }
            if (-not $e -or ($lacuna -and $mudou)) {
                $novo = [pscustomobject]@{
                    Chave = $o.Chave; Pasta = $pasta; Nome = $o.Nome; Tamanho = $o.Tamanho; Modificado = $o.Modificado
                    DesdeUtc = $agoraTxt; AtencaoEnviada = $false; CriticoEnviado = $false
                    AnteriorUtc = $okAnterior   # ultima consulta SEM este arquivo ($null = 1a consulta: ja podia estar ali)
                }
                $Estado.Arquivos[$o.Chave] = $novo
                $res.Eventos += Novo-Evento 'ENTRADA' $novo
            }
            else {
                if ($mudou) { $res.Eventos += Novo-Evento 'ALTERADO' $e $null $agoraTxt $null $o }   # $e = antes, $o = depois
                $e.Tamanho = $o.Tamanho; $e.Modificado = $o.Modificado
            }
        }
        foreach ($chave in @($Estado.Arquivos.Keys)) {
            if ($Estado.Arquivos[$chave].Pasta -eq $pasta -and -not $vistos.Contains($chave)) {
                $arq = $Estado.Arquivos[$chave]
                $res.Eventos += Novo-Evento 'SAIDA' $arq $okAnterior $agoraTxt 'saiu da pasta'
                # Historico do painel: os 10 ultimos que sairam, mais recente primeiro. So aqui: saida por pasta retirada do
                # config.json ou por troca apos lacuna nao tem horario de saida confiavel.
                $Estado.Historico = @(@([pscustomobject]@{ Pasta = $arq.Pasta; Nome = $arq.Nome; EntradaUtc = $arq.DesdeUtc; SaidaUtc = $agoraTxt
                    Minutos = [math]::Round((Minutos-Desde $arq.DesdeUtc $Agora), 1)   # 1a observacao ate a 1a consulta sem ele
                    AtencaoEnviada = $arq.AtencaoEnviada; CriticoEnviado = $arq.CriticoEnviado }) + @($Estado.Historico) | Select-Object -First 10)
                [void]$Estado.Arquivos.Remove($chave)
            }
        }
        $Estado.Pastas[$pasta] = $agoraTxt
    }
    foreach ($chave in @($Estado.Arquivos.Keys)) {   # pasta retirada do config.json
        $e = $Estado.Arquivos[$chave]
        if ($Cfg.PastasRemotas -notcontains $e.Pasta) {
            $res.Eventos += Novo-Evento 'SAIDA' $e $Estado.Pastas[$e.Pasta] $agoraTxt 'pasta removida do config.json'
            [void]$Estado.Arquivos.Remove($chave)
        }
    }

    foreach ($e in @($Estado.Arquivos.Values)) {
        if ($PastasFalha -contains $e.Pasta) { continue }   # sem confirmacao nesta coleta: quem avisa e o alerta de falha
        $n = Nivel (Minutos-Desde $e.DesdeUtc $Agora) $Cfg
        if ($n -eq 'CRITICO' -and -not $e.CriticoEnviado) { $res.Critico += $e }       # critico substitui atencao atrasada
        elseif ($n -eq 'ATENCAO' -and -not $e.AtencaoEnviada) { $res.Atencao += $e }
    }
    if ($PastasFalha.Count) {
        $Estado.FalhasSeguidas++; $Estado.UltimoErro = $Erro
        $res.Falha = $Estado.FalhasSeguidas -ge $Cfg.FalhasParaAlertar -and -not $Estado.AlertaFalhaEnviado
    }
    else {
        $res.Normalizado = [bool]$Estado.AlertaFalhaEnviado
        $Estado.FalhasSeguidas = 0; $Estado.UltimoErro = $null
    }
    return $res
}

# ---------------------------------------------------------------- estado e painel (JSON)

function Salvar-Json($obj, [string]$caminho) {
    $tmp = "$caminho.tmp"   # grava ao lado e troca: quem le nunca ve um JSON pela metade
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $obj -Depth 6), (New-Object Text.UTF8Encoding($false)))
    # Outro programa (provavelmente o antivirus inspecionando o arquivo recem-gravado) pode segurar o arquivo por
    # milissegundos e a troca falhava em ~5% dos ciclos ("nao foi possivel remover o arquivo a ser substituido").
    # Tentar de novo resolve; se persistir, avisa e segue: os dados continuam em memoria ate o proximo ciclo.
    foreach ($tentativa in 1..5) {
        try {
            # [NullString]::Value, nao $null: o PowerShell converte $null em "" e o Replace falharia sempre.
            if (Test-Path -LiteralPath $caminho) { [IO.File]::Replace($tmp, $caminho, [NullString]::Value) } else { [IO.File]::Move($tmp, $caminho) }
            if ($tentativa -gt 1) { Escrever-Log "$(Split-Path $caminho -Leaf) gravado na tentativa $tentativa (estava em uso por outro programa)." }
            return
        }
        catch { $motivo = $_.Exception.GetBaseException().Message; Start-Sleep -Milliseconds 200 }
    }
    Escrever-Log "AVISO: nao foi possivel gravar $(Split-Path $caminho -Leaf) apos 5 tentativas ($motivo). Os dados continuam em memoria; nova tentativa no proximo ciclo."
}

function Ler-Estado([string]$caminho) {
    $e = Novo-Estado
    if (-not (Test-Path -LiteralPath $caminho)) { return $e }
    try {
        $j = Get-Content -LiteralPath $caminho -Raw -Encoding UTF8 | ConvertFrom-Json
        $e.FalhasSeguidas = [int]$j.FalhasSeguidas; $e.UltimoErro = $j.UltimoErro; $e.AlertaFalhaEnviado = [bool]$j.AlertaFalhaEnviado
        foreach ($p in $j.Pastas.PSObject.Properties) { $e.Pastas[$p.Name] = $p.Value }
        foreach ($a in @($j.Arquivos)) { $e.Arquivos[$a.Chave] = $a }
        if ($j.PSObject.Properties['Historico']) { $e.Historico = @($j.Historico) }   # estado.json antigo nao tem
    }
    catch { Escrever-Log "estado.json invalido ($($_.Exception.Message)); recomecando a contagem."; $e = Novo-Estado }
    return $e
}

function Salvar-Estado($Estado) {
    Salvar-Json ([ordered]@{
        FalhasSeguidas = $Estado.FalhasSeguidas; UltimoErro = $Estado.UltimoErro; AlertaFalhaEnviado = $Estado.AlertaFalhaEnviado
        Pastas = $Estado.Pastas; Arquivos = @($Estado.Arquivos.Values); Historico = @($Estado.Historico)
    }) $script:arqEstado
}

function Publicar-Painel($Estado, [string[]]$falhas) {
    # O monitor calcula nivel e minutos; o painel so exibe (limites num lugar so).
    # Minutos contam ate a ultima consulta OK da pasta: pasta fora do ar nao "envelhece" arquivos sem confirmacao.
    $pastas = @(foreach ($p in $Cfg.PastasRemotas) {
        [ordered]@{ Pasta = $p; UltimaOkUtc = $Estado.Pastas[$p]; Falha = [bool]($falhas -contains $p) }
    })
    $arquivos = @(foreach ($e in $Estado.Arquivos.Values) {
        $ok = $Estado.Pastas[$e.Pasta]
        $min = if ($ok) { [math]::Max(0, (Minutos-Desde $e.DesdeUtc ([DateTimeOffset]::Parse($ok, $inv)))) } else { 0 }
        [ordered]@{ Pasta = $e.Pasta; Nome = $e.Nome; Tamanho = $e.Tamanho; DesdeUtc = $e.DesdeUtc; Modificado = $e.Modificado
            Minutos = [math]::Round($min, 1); Nivel = (Nivel $min $Cfg); AtencaoEnviada = $e.AtencaoEnviada; CriticoEnviado = $e.CriticoEnviado }
    })
    # Sem host do servidor A nem texto de erro: o painel e lido por quem nao precisa saber disso (host e erro ficam no log e no e-mail).
    Salvar-Json ([ordered]@{
        GeradoUtc = (Utc ([DateTimeOffset]::UtcNow)); IntervaloSegundos = $Cfg.IntervaloSegundos
        AtencaoMinutos = $Cfg.AtencaoMinutos; CriticoMinutos = $Cfg.CriticoMinutos
        FalhasSeguidas = $Estado.FalhasSeguidas; Pastas = $pastas; Arquivos = $arquivos; Historico = @($Estado.Historico)
    }) $script:arqPainel
}

# ---------------------------------------------------------------- coleta (WinSCP real ou simulado)

function Garantir-Sessao {
    if ($Cfg.Fonte -eq 'Simulado') {
        if (Test-Path -LiteralPath (Join-Path $script:raizSimulada 'SERVIDOR_FORA_DO_AR.txt')) { throw 'conexao SFTP recusada (simulado: servidor fora do ar)' }
        return
    }
    if ($script:sessao -and $script:sessao.Opened) { return }   # sessao aberta: 1 login, nao 1 por ciclo
    if ($script:sessao) { $script:sessao.Dispose() }
    $o = New-Object WinSCP.SessionOptions
    $o.Protocol = [WinSCP.Protocol]::Sftp
    $o.HostName = $Cfg.Sftp.Host; $o.PortNumber = $Cfg.Sftp.Porta; $o.UserName = $Cfg.Sftp.Usuario
    $o.SshHostKeyFingerprint = $Cfg.Sftp.Fingerprint
    # DPAPI: so abre na mesma conta e maquina que gravou; sem este texto o erro vira "parte do caminho" ou "chave invalida".
    $o.Password = try { (Import-Clixml -LiteralPath $script:arqCredencial).GetNetworkCredential().Password }
                  catch { throw 'senha SFTP ausente ou gravada por outra conta/maquina: rode .\Monitor-SFTP.ps1 -SalvarCredencial com a conta que executa o monitor' }
    $o.Timeout = [TimeSpan]::FromSeconds(30)
    $script:sessao = New-Object WinSCP.Session
    $script:sessao.ExecutablePath = [IO.Path]::Combine($raiz, $Cfg.Sftp.WinScpExe)   # aceita caminho relativo ou absoluto
    $script:sessao.Open($o)
    Escrever-Log "Sessao SFTP aberta com $($Cfg.Sftp.Host)."
}

function Listar-Pasta([string]$pasta) {
    if ($Cfg.Fonte -ne 'Simulado') { return $script:sessao.ListDirectory($pasta).Files }
    $local = Join-Path $script:raizSimulada ($pasta.Trim('/') -replace '/', '\')
    if (-not (Test-Path -LiteralPath $local -PathType Container)) { throw 'pasta remota inacessivel (simulado)' }
    foreach ($i in Get-ChildItem -LiteralPath $local -Force) {   # mesmo formato do RemoteFileInfo do WinSCP
        [pscustomobject]@{
            Name = $i.Name; FullName = $pasta.TrimEnd('/') + '/' + $i.Name
            FileType = $(if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { 'L' } elseif ($i.PSIsContainer) { 'D' } else { '-' })
            Length = $(if ($i.PSIsContainer) { 0 } else { $i.Length }); LastWriteTime = $i.LastWriteTime
        }
    }
}

function Executar-Ciclo($Estado) {
    $agora = [DateTimeOffset]::UtcNow
    $observados = @(); $falhas = @(); $erro = $null
    try { Garantir-Sessao } catch { $falhas = @($Cfg.PastasRemotas); $erro = $_.Exception.Message }
    if (-not $falhas.Count) {
        foreach ($pasta in $Cfg.PastasRemotas) {
            try {
                foreach ($f in @(Listar-Pasta $pasta)) {
                    # So arquivo comum ('-'): ignora diretorios, '..' e links. (O pacote anterior lia IsSymbolicLink,
                    # que nao existe no RemoteFileInfo do WinSCP e derrubaria a coleta com StrictMode.)
                    if ($f.FileType -ne '-') { continue }
                    $observados += [pscustomobject]@{ Chave = $f.FullName; Pasta = $pasta; Nome = $f.Name
                        Tamanho = [long]$f.Length; Modificado = (Utc ([DateTimeOffset]$f.LastWriteTime)) }
                }
            }
            catch {
                $falhas += $pasta; $erro = "${pasta}: $($_.Exception.Message)"
                if ($script:sessao -and -not $script:sessao.Opened) { $script:sessao.Dispose(); $script:sessao = $null }
            }
        }
    }
    $r = Aplicar-Ciclo $Estado $observados $falhas $erro $agora $Cfg
    if ($falhas.Count) { Escrever-Log "FALHA na consulta ($($Estado.FalhasSeguidas)x seguidas): $erro" }
    else { Escrever-Log "Consulta OK: $(Resumo-Presentes $Estado $agora)" }
    foreach ($ev in $r.Eventos) { Escrever-Log (Formatar-Evento $ev) }   # trilha de auditoria: entrada, alteracao e saida
    Enviar-Alertas $r $Estado $agora
    Salvar-Estado $Estado
    Publicar-Painel $Estado $falhas
}

# ---------------------------------------------------------------- log de auditoria (sem E/S: testado por Testar-Regras.ps1)

function Aspas([string]$s) {
    # Nome de arquivo vem do servidor remoto: caracteres de controle (ex.: quebra de linha) poderiam forjar
    # linhas falsas no log de auditoria. Viram "?" e as aspas internas sao escapadas.
    '"' + ([regex]::Replace($s, '[\x00-\x1F\x7F]', '?') -replace '"', '\"') + '"'
}

function Data-Log([string]$utc) {
    if (-not $utc) { return '-' }
    [DateTimeOffset]::Parse($utc, $inv).ToLocalTime().ToString("yyyy-MM-dd'T'HH:mm:sszzz", $inv)   # local com fuso, sem espacos
}

function Formatar-Duracao([double]$seg) {
    # Com segundos: no log de auditoria "00m" para 30 s ou 16m59s virando "16m" escondia ate 59 s.
    $t = [TimeSpan]::FromSeconds([math]::Max(0, [math]::Floor($seg)))
    if ($t.Days) { '{0}d{1:D2}h{2:D2}m{3:D2}s' -f $t.Days, $t.Hours, $t.Minutes, $t.Seconds }
    elseif ($t.Hours) { '{0}h{1:D2}m{2:D2}s' -f $t.Hours, $t.Minutes, $t.Seconds }
    elseif ($t.Minutes) { '{0}m{1:D2}s' -f $t.Minutes, $t.Seconds }
    else { '{0}s' -f $t.Seconds }
}

function Dif-Seg([string]$deUtc, [string]$ateUtc) { ([DateTimeOffset]::Parse($ateUtc, $inv) - [DateTimeOffset]::Parse($deUtc, $inv)).TotalSeconds }

function Formatar-Evento($ev) {
    $base = '{0} pasta={1} arquivo={2}' -f $ev.Tipo, (Aspas $ev.Pasta), (Aspas $ev.Nome)
    switch ($ev.Tipo) {
        'ENTRADA' {
            # O monitor so enxerga o arquivo na consulta seguinte: a chegada real esta entre a ultima consulta SEM ele e esta.
            $janela = if ($ev.AnteriorUtc) { "entrada_real_entre=$(Data-Log $ev.AnteriorUtc)..$(Data-Log $ev.DesdeUtc)" } else { 'entrada_real=desconhecida(ja_estava_na_pasta_na_1a_consulta)' }
            "$base tamanho_bytes=$($ev.Tamanho) modificado_no_servidor=$(Data-Log $ev.Modificado) primeira_observacao=$(Data-Log $ev.DesdeUtc) $janela"
        }
        'ALTERADO' { "$base tamanho_bytes=$($ev.Tamanho)->$($ev.Depois.Tamanho) modificado_no_servidor=$(Data-Log $ev.Modificado)->$(Data-Log $ev.Depois.Modificado) entrada=$(Data-Log $ev.DesdeUtc)" }
        'SAIDA' {
            $alertas = @(if ($ev.AtencaoEnviada) { 'atencao' }; if ($ev.CriticoEnviado) { 'critico' })
            # O tempo real na pasta esta entre dois limites: o MINIMO e da 1a a ultima consulta em que o arquivo
            # apareceu; o MAXIMO e da ultima consulta sem ele ate a 1a consulta em que ja tinha sumido.
            $min = if ($ev.VistoAte) { Formatar-Duracao (Dif-Seg $ev.DesdeUtc $ev.VistoAte) } else { 'indeterminada' }
            $max = if ($ev.AnteriorUtc -and $ev.Em) { Formatar-Duracao (Dif-Seg $ev.AnteriorUtc $ev.Em) } else { 'indeterminada' }   # sem consulta anterior: nao da pra limitar
            "$base tamanho_bytes=$($ev.Tamanho) modificado_no_servidor=$(Data-Log $ev.Modificado) entrada=$(Data-Log $ev.DesdeUtc) ultima_vez_visto=$(Data-Log $ev.VistoAte) ausente_na_consulta=$(Data-Log $ev.Em) permanencia_minima=$min permanencia_maxima=$max alertas=$(if ($alertas.Count) { $alertas -join ',' } else { 'nenhum' }) motivo=$(Aspas $ev.Motivo)"
        }
    }
}

function Resumo-Presentes($Estado, [DateTimeOffset]$Agora) {
    # Uma linha por consulta: quem esta na pasta e ha quanto tempo (mostra a presenca ao longo do tempo sem 1 linha por arquivo por ciclo).
    $a = @($Estado.Arquivos.Values | Sort-Object DesdeUtc)
    if (-not $a.Count) { return '0 arquivo(s).' }
    $lista = @($a | Select-Object -First 10 | ForEach-Object { '{0} {1}' -f (Aspas $_.Nome), (Formatar-Tempo (Minutos-Desde $_.DesdeUtc $Agora)) })
    "$($a.Count) arquivo(s): $($lista -join '; ')$(if ($a.Count -gt 10) { '; ...' })"
}

# ---------------------------------------------------------------- e-mail

function Para-Ascii([string]$s) {
    # Acentos viram &#NNN;: visualizadores que ignoram o charset mostrariam "CRÃ�TICO".
    -join ($s.ToCharArray() | ForEach-Object { if ([int]$_ -gt 127) { "&#$([int]$_);" } else { [string]$_ } })
}

function Formatar-Tempo([double]$min) {
    $t = [TimeSpan]::FromMinutes([math]::Max(0, $min))
    if ($t.Days) { '{0}d {1:D2}h {2:D2}m' -f $t.Days, $t.Hours, $t.Minutes }
    elseif ($t.Hours) { '{0:D2}h {1:D2}m' -f $t.Hours, $t.Minutes }
    else { '{0:D2}m' -f $t.Minutes }
}

function Html-Email([string]$tipo, [string]$intro, [string]$tabela) {
    $cores = @{ ATENCAO = '#FDC20F;color:#3B2900'; CRITICO = '#B42318;color:#FFFFFF'; FALHA = '#B42318;color:#FFFFFF'; NORMALIZADO = '#1E7B4F;color:#FFFFFF'; TESTE = '#003B77;color:#FFFFFF' }
    @"
<html><body style="margin:0;padding:0;background-color:#F3F4F6;font-family:'Montserrat','Segoe UI',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#F3F4F6;padding:24px 0;"><tr><td align="center">
<table role="presentation" width="640" cellpadding="0" cellspacing="0" style="background-color:#FFFFFF;border:1px solid #D0D1D4;">
<tr><td style="background-color:#003B77;padding:20px 28px;border-bottom:3px solid #F79D1B;"><table role="presentation" cellpadding="0" cellspacing="0"><tr>
<td><span style="color:#FFFFFF;font-size:20px;font-weight:700;">Monitor de Arquivos</span></td></tr></table></td></tr>
<tr><td style="padding:24px 28px 0 28px;"><span style="display:inline-block;background-color:$($cores[$tipo]);font-size:12px;font-weight:700;padding:4px 10px;">$($Rotulos[$tipo])</span>
<p style="margin:12px 0 0 0;color:#0E2041;font-size:15px;line-height:1.5;">$intro</p></td></tr>
<tr><td style="padding:16px 28px 24px 28px;">$tabela</td></tr>
<tr><td style="padding:14px 28px;background-color:#FAFAFA;border-top:1px solid #D0D1D4;"><p style="margin:0;color:#7A8496;font-size:12px;">E-mail automático do Monitor de Arquivos (SFTP), gerado em $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss'). Não responda a esta mensagem.</p></td></tr>
</table></td></tr></table></body></html>
"@
}

function Html-Arquivos([string]$tipo, $itens, [DateTimeOffset]$agora) {
    $th = 'padding:10px 14px;color:#FAFAFA;font-size:12px;text-transform:uppercase;text-align:left;'
    $td = 'padding:10px 14px;border-bottom:1px solid #D0D1D4;color:#0E2041;font-size:14px;'
    $linhas = foreach ($e in $itens) {
        "<tr><td style=`"$td`">$([Net.WebUtility]::HtmlEncode($e.Nome))</td><td style=`"$td`">$([Net.WebUtility]::HtmlEncode($e.Pasta))</td>" +
        "<td style=`"$td white-space:nowrap;`">$(Formatar-Tempo (Minutos-Desde $e.DesdeUtc $agora))</td></tr>"
    }
    $limite = if ($tipo -eq 'CRITICO') { $Cfg.CriticoMinutos } else { $Cfg.AtencaoMinutos }
    $tabela = "<table role=`"presentation`" width=`"100%`" cellpadding=`"0`" cellspacing=`"0`" style=`"border:1px solid #D0D1D4;`">" +
        "<tr style=`"background-color:#0E2041;`"><th style=`"$th`">Arquivo</th><th style=`"$th`">Pasta</th><th style=`"$th`">Tempo parado</th></tr>$($linhas -join '')</table>"
    Html-Email $tipo "<strong>$(@($itens).Count) arquivo(s)</strong> parado(s) há <strong>$limite minutos ou mais</strong> em <strong>$([Net.WebUtility]::HtmlEncode($script:nomeServidor))</strong>:" $tabela
}

function Enviar-Email([string]$assunto, [string]$html) {
    $m = New-Object Net.Mail.MailMessage
    $smtp = New-Object Net.Mail.SmtpClient
    try {
        $m.From = $Cfg.Email.Remetente
        foreach ($d in $Cfg.Email.Destinatarios) { $m.To.Add($d) }
        $m.Subject = $assunto; $m.SubjectEncoding = [Text.Encoding]::UTF8
        $v = [Net.Mail.AlternateView]::CreateAlternateViewFromString((Para-Ascii $html), [Text.Encoding]::UTF8, 'text/html')
        $m.AlternateViews.Add($v)
        $smtp.Host = $Cfg.Email.SmtpHost; $smtp.Port = $Cfg.Email.SmtpPorta; $smtp.EnableSsl = [bool]$Cfg.Email.Tls
        $smtp.Send($m)
    }
    finally { $m.Dispose(); $smtp.Dispose() }
}

function Tentar-Enviar([string]$tipo, [string]$html, [int]$qtd, [string]$arquivos = '') {
    $assunto = "[Monitor SFTP] $($Rotulos[$tipo])" + $(if ($qtd) { " | $qtd arquivo(s)" } else { '' })
    $detalhe = if ($arquivos) { " arquivos=$arquivos" } else { '' }   # auditoria: quais arquivos cada e-mail cobriu
    # "aceito" e o que o SMTP confirma; nao garante entrega na caixa (pode cair no Lixo Eletronico/quarentena).
    try { Enviar-Email $assunto $html; Escrever-Log "E-mail $tipo aceito pelo servidor SMTP.$detalhe"; return $true }
    catch {
        # A mensagem de topo do .NET e sempre "Falha ao enviar email."; o motivo real (conexao recusada, resposta
        # 5.7.x do servidor, IP nao autorizado...) esta na excecao mais interna e no StatusCode do SMTP.
        $ex = $_.Exception.GetBaseException()
        $codigo = if ($ex -is [Net.Mail.SmtpException]) { " [SMTP $($ex.StatusCode)]" } else { '' }
        Escrever-Log "FALHA ao enviar e-mail ${tipo}: $($ex.Message)$codigo (nova tentativa no proximo ciclo).$detalhe"
        return $false
    }
}

function Enviar-Alertas($r, $Estado, [DateTimeOffset]$agora) {
    # So marca como enviado se o envio deu certo: senao tenta de novo no ciclo seguinte.
    foreach ($tipo in 'CRITICO', 'ATENCAO') {
        $itens = if ($tipo -eq 'CRITICO') { $r.Critico } else { $r.Atencao }
        if (-not @($itens).Count) { continue }
        if (Tentar-Enviar $tipo (Html-Arquivos $tipo $itens $agora) @($itens).Count ((@($itens) | ForEach-Object { Aspas $_.Nome }) -join ',')) {
            foreach ($e in $itens) { $e.AtencaoEnviada = $true; if ($tipo -eq 'CRITICO') { $e.CriticoEnviado = $true } }
        }
    }
    if ($r.Falha) {
        $msg = "Não foi possível consultar <strong>$([Net.WebUtility]::HtmlEncode($script:nomeServidor))</strong> em $($Estado.FalhasSeguidas) tentativas seguidas. " +
            "Enquanto isso, arquivos parados <strong>não geram alerta</strong>.<br><br>Último erro: $([Net.WebUtility]::HtmlEncode($Estado.UltimoErro))"
        if (Tentar-Enviar 'FALHA' (Html-Email 'FALHA' $msg '') 0) { $Estado.AlertaFalhaEnviado = $true }
    }
    if ($r.Normalizado) {
        $msg = "As consultas a <strong>$([Net.WebUtility]::HtmlEncode($script:nomeServidor))</strong> voltaram a funcionar. Os alertas de arquivos parados foram retomados."
        if (Tentar-Enviar 'NORMALIZADO' (Html-Email 'NORMALIZADO' $msg '') 0) { $Estado.AlertaFalhaEnviado = $false }
    }
}

function Escrever-Log([string]$msg) {
    $linha = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $linha
    # Log preso (antivirus, disco cheio) nao pode derrubar o monitor: sem laco, ninguem e avisado de arquivo parado.
    try { Add-Content -LiteralPath (Join-Path $script:dirDados ('monitor-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))) -Value $linha -Encoding UTF8 }
    catch { Write-Host "AVISO: nao foi possivel gravar no log ($($_.Exception.Message))" }
}

# ---------------------------------------------------------------- execucao

function Limpar-Logs-Antigos {
    # Retencao: apaga monitor-AAAA-MM-DD.log com mais de RetencaoLogsDias dias (padrao 90; 0 = nunca apagar).
    # Mexe SO em arquivos com esse nome exato, no maximo 1 vez por dia, e registra cada remocao no log.
    # Defina o prazo conforme a politica de auditoria da empresa.
    if ($script:diaLimpeza -eq (Get-Date).Date) { return }
    $script:diaLimpeza = (Get-Date).Date
    try {
        $dias = if ($null -ne $Cfg.RetencaoLogsDias) { [int]$Cfg.RetencaoLogsDias } else { 90 }
        if ($dias -le 0) { return }
        $limite = (Get-Date).Date.AddDays(-$dias)
        foreach ($f in @(Get-ChildItem -LiteralPath $script:dirDados -File -Filter 'monitor-*.log')) {
            if ($f.Name -notmatch '^monitor-(\d{4}-\d{2}-\d{2})\.log$') { continue }
            $data = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($Matches[1], 'yyyy-MM-dd', $inv, [Globalization.DateTimeStyles]::None, [ref]$data)) { continue }
            if ($data -lt $limite) {
                [IO.File]::Delete($f.FullName)
                Escrever-Log "Log antigo removido pela retencao de $dias dias: $($f.Name)"
            }
        }
    }
    catch { Escrever-Log "AVISO: falha ao aplicar a retencao de logs: $($_.Exception.Message)" }
}

if ($MyInvocation.InvocationName -eq '.') { return }   # carregado pelo Testar-Regras.ps1: so as funcoes

$Cfg = Get-Content -LiteralPath (Join-Path $raiz 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$script:dirDados = Join-Path $raiz 'dados'
$script:arqEstado = Join-Path $script:dirDados 'estado.json'
$script:arqPainel = Join-Path $raiz 'painel\dados\dashboard.json'
$script:arqCredencial = Join-Path $raiz 'segredos\sftp.xml'
$script:nomeServidor = if ($Cfg.Fonte -eq 'Simulado') { 'servidor A (simulado)' } else { $Cfg.Sftp.Host }
$script:sessao = $null
foreach ($d in $script:dirDados, (Split-Path $script:arqPainel)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

function Descrever-Email {
    "SMTP $($Cfg.Email.SmtpHost):$($Cfg.Email.SmtpPorta) (TLS: $($Cfg.Email.Tls)); de $($Cfg.Email.Remetente) para $(@($Cfg.Email.Destinatarios) -join ', ')"
}

if ($TestarEmail) {   # nao consulta o SFTP e nao exige a trava: da pra rodar com o monitor ligado
    Write-Host "E-mail: $(Descrever-Email)"
    $corpo = "Este &eacute; um e-mail de <strong>teste</strong> do Monitor de Arquivos (SFTP). Se voc&ecirc; o recebeu, o envio est&aacute; funcionando.<br><br>Configura&ccedil;&atilde;o usada: $([Net.WebUtility]::HtmlEncode((Descrever-Email)))"
    if (Tentar-Enviar 'TESTE' (Html-Email 'TESTE' $corpo '') 0) {
        Write-Host 'O servidor SMTP aceitou a mensagem. Confira a caixa de entrada, o Lixo Eletronico e a quarentena (aceitar nao garante entregar).'
        exit 0
    }
    exit 1
}

if ($SalvarCredencial) {
    New-Item -ItemType Directory -Path (Split-Path $script:arqCredencial) -Force | Out-Null
    Get-Credential -UserName $Cfg.Sftp.Usuario -Message 'Senha SFTP (use a conta Windows que vai rodar o monitor)' | Export-Clixml -LiteralPath $script:arqCredencial
    Write-Host "Credencial protegida por DPAPI gravada em $script:arqCredencial. Restrinja o acesso a essa pasta."
    exit 0
}

if ($Cfg.Fonte -eq 'Simulado') {
    $script:raizSimulada = [IO.Path]::Combine($raiz, $Cfg.PastaSimulada)   # so o modo Simulado usa (e exige) esta chave
    foreach ($p in $Cfg.PastasRemotas) { New-Item -ItemType Directory -Path (Join-Path $script:raizSimulada ($p.Trim('/') -replace '/', '\')) -Force | Out-Null }
}
else {
    foreach ($v in $Cfg.Sftp.Host, $Cfg.Sftp.Usuario, $Cfg.Sftp.Fingerprint) { if ($v -match 'PREENCHER') { throw 'Preencha o bloco "Sftp" do config.json.' } }
    if ($Cfg.Sftp.Fingerprint -match '\*') { throw 'Fingerprint SSH com * nao e permitida: valide a chave com a administradora do servidor A.' }
    Add-Type -Path ([IO.Path]::Combine($raiz, $Cfg.Sftp.WinScpDll))
}

# Trava em arquivo, nao mutex: vale entre sessoes e contas do Windows (tarefa agendada + alguem logado por RDP) e o
# sistema a solta sozinho se o processo morrer.
try { $trava = [IO.File]::Open((Join-Path $script:dirDados 'monitor.trava'), 'OpenOrCreate', 'ReadWrite', 'None') }
catch { Write-Warning 'Ja existe um Monitor-SFTP em execucao (ou a conta nao tem permissao de escrita em dados\).'; exit 2 }

$estado = Ler-Estado $script:arqEstado
Escrever-Log "Monitor iniciado (fonte: $($Cfg.Fonte); consulta a cada $($Cfg.IntervaloSegundos)s; atencao $($Cfg.AtencaoMinutos) min; critico $($Cfg.CriticoMinutos) min)."
Escrever-Log "E-mail: $(Descrever-Email)"
try {
    do {
        $inicio = Get-Date
        Limpar-Logs-Antigos   # se o dia mudou (e na 1a vez)
        try { Executar-Ciclo $estado } catch { Escrever-Log "ERRO inesperado no ciclo: $($_.Exception.Message)" }
        if ($UmCiclo) { break }
        $resto = $Cfg.IntervaloSegundos - ((Get-Date) - $inicio).TotalSeconds   # desconta a duracao do ciclo
        if ($resto -gt 0) { Start-Sleep -Milliseconds ([int]($resto * 1000)) }
    } while ($true)
}
finally {
    if ($script:sessao) { $script:sessao.Dispose() }
    $trava.Dispose()
}
