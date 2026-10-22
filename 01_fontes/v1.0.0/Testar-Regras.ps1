#requires -Version 5.1
# Checagem das regras do Monitor-SFTP.ps1 sem rede, sem arquivos e sem esperar: horarios sinteticos.
# Rodar: powershell -NoProfile -ExecutionPolicy Bypass -File Testar-Regras.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Monitor-SFTP.ps1')

$Cfg = [pscustomobject]@{ PastasRemotas = @('/entrada', '/saida'); AtencaoMinutos = 10; CriticoMinutos = 15
    ToleranciaSegundos = 30; MaxLacunaMinutos = 3; FalhasParaAlertar = 3 }
$script:erros = 0
function Confere($ok, [string]$msg) { if ($ok) { "OK      $msg" } else { "FALHOU  $msg"; $script:erros++ } }
function Obs($pasta, $nome, $tam = 100, $mod = '2026-10-13T11:59:00Z') {
    [pscustomobject]@{ Chave = "$pasta/$nome"; Pasta = $pasta; Nome = $nome; Tamanho = [long]$tam; Modificado = $mod }
}
function Marcar($r) {   # o que o Enviar-Alertas faz quando o envio da certo
    foreach ($e in $r.Critico) { $e.AtencaoEnviada = $true; $e.CriticoEnviado = $true }
    foreach ($e in $r.Atencao) { $e.AtencaoEnviada = $true }
}
$t = { param($min, $seg = 0) [DateTimeOffset]::Parse('2026-10-13T12:00:00Z').AddMinutes($min).AddSeconds($seg) }

# 1) Variacao normal da conexao (1o ciclo 4s atrasado, demais 1s): atencao aos 10 e critico aos 15, sem atrasar um ciclo
$e = Novo-Estado; $alertas = @()
foreach ($k in 0..20) {
    $r = Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml') @() $null (& $t $k $(if ($k) { 1 } else { 4 })) $Cfg
    if ($r.Atencao.Count) { $alertas += "A$k" }; if ($r.Critico.Count) { $alertas += "C$k" }; Marcar $r
}
Confere (($alertas -join ',') -eq 'A10,C15') "jitter: alertas em [$($alertas -join ',')], esperado [A10,C15] (sem duplicar depois)"

# 2) Servidor fora do ar: nada sai da pasta, alerta de falha so na 3a falha e uma vez, depois normaliza
$e = Novo-Estado
[void](Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml') @() $null (& $t 0) $Cfg)
$todas = [string[]]@('/entrada', '/saida'); $falhou = @()
foreach ($k in 1..5) {
    $r = Aplicar-Ciclo $e @() $todas 'conexao recusada' (& $t $k) $Cfg
    if ($r.Falha) { $falhou += $k; $e.AlertaFalhaEnviado = $true }
}
Confere (($falhou -join ',') -eq '3') "falha: alerta de falha nos ciclos [$($falhou -join ',')], esperado [3]"
Confere ($e.Arquivos.ContainsKey('/entrada/a.xml')) 'falha: arquivo continua pendente (falha nao vira "processado")'
$r = Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml') @() $null (& $t 6) $Cfg
Confere $r.Normalizado 'falha: e-mail de normalizacao quando volta'
Confere ($e.Arquivos['/entrada/a.xml'].DesdeUtc -eq (Utc (& $t 0))) 'falha: arquivo igual depois da queda mantem o inicio da contagem (nao zera)'

# 3) Depois de uma lacuna, arquivo com tamanho diferente = outro arquivo: recomeca
$e = Novo-Estado
[void](Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml' 100) @() $null (& $t 0) $Cfg)
foreach ($k in 1..5) { [void](Aplicar-Ciclo $e @() $todas 'x' (& $t $k) $Cfg) }
[void](Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml' 999) @() $null (& $t 6) $Cfg)
Confere ($e.Arquivos['/entrada/a.xml'].DesdeUtc -eq (Utc (& $t 6))) 'lacuna + arquivo mudou: contagem recomeca'

# 4) Sem lacuna, arquivo crescendo (ainda sendo gravado): continua contando
$e = Novo-Estado
[void](Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml' 100) @() $null (& $t 0) $Cfg)
[void](Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml' 500) @() $null (& $t 1) $Cfg)
Confere ($e.Arquivos['/entrada/a.xml'].DesdeUtc -eq (Utc (& $t 0))) 'arquivo crescendo sem lacuna: nao zera'

# 5) Saiu da pasta: sai do controle; voltou: contagem nova
$e = Novo-Estado
[void](Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml') @() $null (& $t 0) $Cfg)
[void](Aplicar-Ciclo $e @() @() $null (& $t 1) $Cfg)
Confere (-not $e.Arquivos.ContainsKey('/entrada/a.xml')) 'arquivo processado sai do controle'
[void](Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml') @() $null (& $t 2) $Cfg)
Confere ($e.Arquivos['/entrada/a.xml'].DesdeUtc -eq (Utc (& $t 2))) 'arquivo que volta comeca contagem nova'

# 6) So uma pasta falha: a outra segue normal; arquivo antigo da pasta com falha nao gera alerta sem confirmacao
$e = Novo-Estado
[void](Aplicar-Ciclo $e @((Obs '/entrada' 'sai.xml'), (Obs '/saida' 'velho.xml')) @() $null (& $t 0) $Cfg)
$r = Aplicar-Ciclo $e @() ([string[]]@('/saida')) 'permissao negada' (& $t 20) $Cfg
Confere (-not $e.Arquivos.ContainsKey('/entrada/sai.xml')) 'falha parcial: pasta OK processa a saida normalmente'
Confere ($e.Arquivos.ContainsKey('/saida/velho.xml') -and -not $r.Critico.Count) 'falha parcial: pasta com falha mantem o arquivo e nao alerta sem confirmacao'

# 7) SFTP diferencia maiusculas: A.xml e a.xml sao arquivos diferentes
$e = Novo-Estado
[void](Aplicar-Ciclo $e @((Obs '/entrada' 'A.xml'), (Obs '/entrada' 'a.xml')) @() $null (& $t 0) $Cfg)
Confere ($e.Arquivos.Count -eq 2) "maiusculas: $($e.Arquivos.Count) arquivo(s) controlado(s), esperado 2"

# 8) Log de auditoria: eventos do ciclo de vida do arquivo
$e = Novo-Estado
$r = Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml' 100) @() $null (& $t 0) $Cfg
Confere ((($r.Eventos | ForEach-Object Tipo) -join ',') -eq 'ENTRADA') 'auditoria: 1a vez que aparece gera ENTRADA'
$r = Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml' 100) @() $null (& $t 1) $Cfg
Confere ($r.Eventos.Count -eq 0) 'auditoria: sem mudanca nao gera evento (nao enche o log)'
$r = Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml' 500) @() $null (& $t 2) $Cfg
$alt = @($r.Eventos | Where-Object Tipo -eq 'ALTERADO')[0]
Confere ($alt -and $alt.Tamanho -eq 100 -and $alt.Depois.Tamanho -eq 500) 'auditoria: tamanho mudou -> ALTERADO com antes (100) e depois (500)'
$e.Arquivos['/entrada/a.xml'].AtencaoEnviada = $true   # como se ja tivesse recebido o alerta de atencao
$r = Aplicar-Ciclo $e @() @() $null (& $t 4) $Cfg
$sai = @($r.Eventos | Where-Object Tipo -eq 'SAIDA')[0]
Confere ($sai -and $sai.Motivo -eq 'saiu da pasta' -and $sai.AtencaoEnviada -and $sai.Tamanho -eq 500 -and $sai.VistoAte -eq (Utc (& $t 2))) 'auditoria: SAIDA com tamanho final, alerta recebido e ultima vez visto'

$e = Novo-Estado
[void](Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml' 100) @() $null (& $t 0) $Cfg)
$r = Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml' 999) @() $null (& $t 10) $Cfg   # 10 min sem consulta + arquivo diferente
Confere ((($r.Eventos | ForEach-Object Tipo) -join ',') -eq 'SAIDA,ENTRADA') 'auditoria: mesmo nome apos lacuna = SAIDA do antigo + ENTRADA do novo'

$e = Novo-Estado
[void](Aplicar-Ciclo $e @(Obs '/saida' 'velho.xml') @() $null (& $t 0) $Cfg)
$CfgSo = [pscustomobject]@{ PastasRemotas = @('/entrada'); AtencaoMinutos = 10; CriticoMinutos = 15; ToleranciaSegundos = 30; MaxLacunaMinutos = 3; FalhasParaAlertar = 3 }
$r = Aplicar-Ciclo $e @() @() $null (& $t 1) $CfgSo
Confere (@($r.Eventos | Where-Object { $_.Tipo -eq 'SAIDA' -and $_.Motivo -eq 'pasta removida do config.json' }).Count -eq 1) 'auditoria: pasta retirada do config gera SAIDA com o motivo'

$e = Novo-Estado
[void](Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml') @() $null (& $t 0) $Cfg)
$r = Aplicar-Ciclo $e @() $todas 'conexao recusada' (& $t 1) $Cfg
Confere ($r.Eventos.Count -eq 0) 'auditoria: pasta sem acesso nao gera SAIDA (falha nao e saida)'

$ev = Novo-Evento 'ENTRADA' ([pscustomobject]@{ Pasta = '/entrada'; Nome = "x`n[2026-10-15 00:00:00] ERRO falso `"citado`""; Tamanho = 7
    Modificado = '2026-10-13T11:59:00Z'; DesdeUtc = '2026-10-13T12:00:00Z'; AtencaoEnviada = $false; CriticoEnviado = $false })
$linha = Formatar-Evento $ev
Confere ($linha -notmatch '[\r\n]') 'auditoria: quebra de linha no nome do arquivo nao forja linha no log'
Confere ($linha.Contains('arquivo="x?[2026-10-15 00:00:00] ERRO falso \"citado\""')) 'auditoria: nome sanitizado e aspas escapadas'
Confere ($linha -match 'tamanho_bytes=7 modificado_no_servidor=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d ') 'auditoria: ENTRADA com tamanho e data local com fuso'
$ev = Novo-Evento 'SAIDA' ([pscustomobject]@{ Pasta = '/entrada'; Nome = 'a.xml'; Tamanho = 500; Modificado = '2026-10-13T11:59:00Z'
    DesdeUtc = '2026-10-13T12:00:00Z'; AnteriorUtc = '2026-10-13T11:59:30Z'; AtencaoEnviada = $true; CriticoEnviado = $true }) '2026-10-13T12:17:00Z' '2026-10-13T12:18:00Z' 'saiu da pasta'
$linha = Formatar-Evento $ev
Confere ($linha.Contains('permanencia_minima=17m00s') -and $linha.Contains('permanencia_maxima=18m30s')) 'auditoria: SAIDA traz a janela de permanencia (min 17m00s = 1a..ultima vista; max 18m30s = ultima sem ele..ausente)'
Confere ($linha.Contains('alertas=atencao,critico') -and $linha.Contains('motivo="saiu da pasta"')) 'auditoria: SAIDA traz alertas recebidos e motivo'
$ev = Novo-Evento 'SAIDA' ([pscustomobject]@{ Pasta = '/entrada'; Nome = 'a.xml'; Tamanho = 5; Modificado = '2026-10-13T11:59:00Z'
    DesdeUtc = '2026-10-13T12:00:00Z'; AnteriorUtc = $null; AtencaoEnviada = $false; CriticoEnviado = $false }) '2026-10-13T12:17:00Z' '2026-10-13T12:18:00Z' 'saiu da pasta'
Confere ((Formatar-Evento $ev).Contains('permanencia_maxima=indeterminada')) 'auditoria: arquivo que ja estava na pasta no inicio -> permanencia maxima indeterminada (nao inventa)'

# 9) Precisao da auditoria: segundos, janela da entrada, arquivo ja presente no inicio
Confere ((Formatar-Duracao 47) -eq '47s' -and (Formatar-Duracao 1002) -eq '16m42s' -and (Formatar-Duracao 3725) -eq '1h02m05s' -and (Formatar-Duracao 90000) -eq '1d01h00m00s') 'duracao: 47s, 16m42s, 1h02m05s, 1d01h00m00s (antes 30 s aparecia como "00m")'
$e = Novo-Estado
$r = Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml') @() $null (& $t 0) $Cfg
Confere ($null -eq $e.Arquivos['/entrada/a.xml'].AnteriorUtc -and (Formatar-Evento $r.Eventos[0]).Contains('entrada_real=desconhecida')) 'ja estava na pasta na 1a consulta: entrada real desconhecida (nao vira "chegou agora")'
$r = Aplicar-Ciclo $e @((Obs '/entrada' 'a.xml'), (Obs '/entrada' 'b.xml')) @() $null (& $t 1) $Cfg
$entB = Formatar-Evento (@($r.Eventos | Where-Object { $_.Tipo -eq 'ENTRADA' })[0])
Confere ($e.Arquivos['/entrada/b.xml'].AnteriorUtc -eq (Utc (& $t 0)) -and $entB.Contains('entrada_real_entre=')) 'arquivo novo guarda a ultima consulta sem ele e registra a janela da entrada'

# 10) Retencao de logs: so apaga monitor-AAAA-MM-DD.log antigo, nunca outros arquivos
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('retencao_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$script:dirDados = $tmp; $script:diaLimpeza = $null
$Cfg | Add-Member -NotePropertyName RetencaoLogsDias -NotePropertyValue 90 -Force
$hoje = (Get-Date).Date
$criar = @{ "monitor-$($hoje.AddDays(-200).ToString('yyyy-MM-dd')).log" = $true; "monitor-$($hoje.AddDays(-91).ToString('yyyy-MM-dd')).log" = $true
    "monitor-$($hoje.AddDays(-89).ToString('yyyy-MM-dd')).log" = $false; "monitor-$($hoje.ToString('yyyy-MM-dd')).log" = $false
    'estado.json' = $false; 'monitor-antigo-backup.log' = $false; 'monitor-2020-13-45.log' = $false }
foreach ($n in $criar.Keys) { [IO.File]::WriteAllText((Join-Path $tmp $n), 'x') }
Limpar-Logs-Antigos
$sobrou = @(Get-ChildItem $tmp -File | ForEach-Object Name)
$certos = ($criar.Keys | Where-Object { $criar[$_] -eq $false } | ForEach-Object { $sobrou -contains $_ } | Where-Object { -not $_ }).Count -eq 0
$apagados = ($criar.Keys | Where-Object { $criar[$_] -eq $true } | Where-Object { $sobrou -contains $_ }).Count -eq 0
Confere ($apagados) 'retencao: logs com mais de 90 dias foram apagados'
Confere ($certos) 'retencao: log de 89 dias, o de hoje, estado.json e nomes fora do padrao foram preservados'
Confere ((Get-Content (Join-Path $tmp "monitor-$($hoje.ToString('yyyy-MM-dd')).log") -Raw) -match 'Log antigo removido pela retencao de 90 dias') 'retencao: cada remocao fica registrada no proprio log'
$script:diaLimpeza = $null; $Cfg.RetencaoLogsDias = 0
[IO.File]::WriteAllText((Join-Path $tmp 'monitor-2000-01-01.log'), 'x'); Limpar-Logs-Antigos
Confere (Test-Path (Join-Path $tmp 'monitor-2000-01-01.log')) 'retencao: RetencaoLogsDias = 0 nunca apaga'
foreach ($f in Get-ChildItem $tmp -File) { [IO.File]::Delete($f.FullName) }
[IO.Directory]::Delete($tmp)


$e = Novo-Estado
[void](Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml') @() $null (& $t 0) $Cfg)
[void](Aplicar-Ciclo $e @((Obs '/entrada' 'a.xml'), (Obs '/entrada' 'b.xml')) @() $null (& $t 1) $Cfg)
Confere ((Resumo-Presentes $e (& $t 5)) -eq '2 arquivo(s): "a.xml" 05m; "b.xml" 04m') 'auditoria: resumo da consulta lista os arquivos presentes e ha quanto tempo'
Confere ((Resumo-Presentes (Novo-Estado) (& $t 0)) -eq '0 arquivo(s).') 'auditoria: resumo da consulta com pasta vazia'

# 11) Historico dos 10 ultimos arquivos que sairam da pasta (tabela do painel)
$e = Novo-Estado
[void](Aplicar-Ciclo $e @(Obs '/entrada' 'a.xml') @() $null (& $t 0) $Cfg)
$e.Arquivos['/entrada/a.xml'].AtencaoEnviada = $true
[void](Aplicar-Ciclo $e @() @() $null (& $t 12) $Cfg)
$h = $e.Historico[0]
Confere ($e.Historico.Count -eq 1 -and $h.Nome -eq 'a.xml' -and $h.Minutos -eq 12 -and $h.AtencaoEnviada -and -not $h.CriticoEnviado -and $h.SaidaUtc -eq (Utc (& $t 12))) 'historico: saida registra nome, tempo na pasta (12 min), alerta recebido e hora da saida'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('hist_' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp | Out-Null
$script:dirDados = $tmp; $script:arqEstado = Join-Path $tmp 'estado.json'; $script:arqPainel = Join-Path $tmp 'dashboard.json'
Publicar-Painel $e @()
Confere ((Get-Content $script:arqPainel -Raw) -match '"Historico":\s*\[') 'painel: historico com 1 item continua sendo lista no JSON'

$e = Novo-Estado
foreach ($k in 1..12) {   # um arquivo por vez: entra num minuto par e sai no seguinte (b1 ... b12)
    [void](Aplicar-Ciclo $e @(Obs '/entrada' "b$k.xml") @() $null (& $t (2 * $k)) $Cfg)
    [void](Aplicar-Ciclo $e @() @() $null (& $t (2 * $k + 1)) $Cfg)
}
Confere ($e.Historico.Count -eq 10 -and $e.Historico[0].Nome -eq 'b12.xml' -and $e.Historico[9].Nome -eq 'b3.xml') 'historico: guarda so os 10 mais recentes, o ultimo a sair primeiro'
Salvar-Estado $e
$e2 = Ler-Estado $script:arqEstado
Confere ($e2.Historico.Count -eq 10 -and $e2.Historico[0].Nome -eq 'b12.xml' -and $e2.Historico[0].Minutos -eq 1) 'historico: sobrevive a reiniciar o monitor (gravado e lido do estado.json)'
$e.UltimoErro = 'conexao recusada por host.interno.exemplo'
Publicar-Painel $e @()
$pub = Get-Content $script:arqPainel -Raw | ConvertFrom-Json
Confere ($pub.Historico.Count -eq 10 -and -not $pub.PSObject.Properties['Servidor'] -and -not $pub.PSObject.Properties['UltimoErro'] -and (Get-Content $script:arqPainel -Raw) -notmatch 'host\.interno') 'painel: publica o historico e NAO publica o host do servidor nem o texto do erro'
Salvar-Estado (Novo-Estado)
Confere ((Ler-Estado $script:arqEstado).Historico.Count -eq 0) 'historico: vazio grava e le de volta vazio (nao vira lista com item nulo)'
[IO.File]::WriteAllText($script:arqEstado, '{"FalhasSeguidas":0,"UltimoErro":null,"AlertaFalhaEnviado":false,"Pastas":{},"Arquivos":[]}')
Confere ((Ler-Estado $script:arqEstado).Historico.Count -eq 0) 'historico: estado.json da versao anterior (sem Historico) abre sem erro'

$e = Novo-Estado
[void](Aplicar-Ciclo $e @(Obs '/saida' 'velho.xml') @() $null (& $t 0) $Cfg)
[void](Aplicar-Ciclo $e @() @() $null (& $t 1) $CfgSo)   # a pasta /saida saiu do config.json
Confere ($e.Historico.Count -eq 0) 'historico: pasta retirada do config.json nao vira "arquivo que saiu"'
foreach ($f in Get-ChildItem $tmp -File) { [IO.File]::Delete($f.FullName) }
[IO.Directory]::Delete($tmp)

"`n$(if ($script:erros) { "$script:erros FALHA(S)" } else { 'TODAS AS REGRAS OK' })"
exit $script:erros
