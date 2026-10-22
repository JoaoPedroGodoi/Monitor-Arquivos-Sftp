# Monitoramento de Arquivos por SFTP

## 1. Descrição

Aplicação desenvolvida para monitorar, de forma automatizada, pastas de um
servidor remoto acessado por SFTP e avisar quando um arquivo permanece parado
por mais tempo que o esperado.

A ferramenta roda em um segundo servidor (servidor B), consulta as pastas do
servidor monitorado (servidor A) por SFTP, calcula há quanto tempo cada arquivo
está na pasta, publica o resultado em um painel web e envia alertas por e-mail.

O servidor monitorado **não recebe nenhuma instalação** e a ferramenta **só
lista** nomes, tamanhos e datas: nunca baixa, altera ou remove arquivos. Isso
atende ambientes em que o servidor de origem não pode ter agentes instalados
nem pastas compartilhadas (por exemplo, por política contra ransomware).

## 2. Versão

Versão atual: 1.0.0
Status: Em validação

## 3. Funcionalidades

- Consulta periódica das pastas por SFTP (WinSCP), mantendo uma única sessão
  aberta em vez de um login por consulta;
- Cálculo do tempo de permanência de cada arquivo;
- Alerta por e-mail de **atenção** (padrão: 10 min) e **crítico** (padrão: 15 min);
- Alerta quando o próprio monitoramento perde o acesso ao servidor (3 falhas
  seguidas) e aviso quando o acesso volta;
- Distinção entre "arquivo processado" e "falha de consulta": sem acesso, o
  arquivo **não** é dado como processado;
- Log de auditoria com o ciclo de vida de cada arquivo (entrada, alteração e
  saída) e a janela de permanência (mínima e máxima);
- Painel web com status por pasta, arquivos em andamento e os 10 últimos
  arquivos que saíram das pastas;
- Execução contínua por tarefa agendada do Windows, com recuperação automática;
- Modo simulado, que dispensa servidor real para testes;
- Testes automatizados das regras de negócio, sem rede.

## 4. Como funciona

A cada `IntervaloSegundos`, o monitor lista as pastas configuradas e compara com
o estado anterior:

| Situação | Comportamento |
|---|---|
| Arquivo novo | Registra a `ENTRADA` e começa a contar o tempo |
| Arquivo mudou de tamanho ou data, sem lacuna nas consultas | Registra `ALTERADO` e **continua** contando (ainda está sendo gravado) |
| Arquivo mudou depois de uma lacuna maior que `MaxLacunaMinutos` | É tratado como **outro** arquivo: registra `SAIDA` do antigo e recomeça a contagem |
| Arquivo não aparece mais | Registra `SAIDA` e entra no histórico do painel |
| Falha ao consultar uma pasta | Nada sai do controle: falha de consulta **não** é saída de arquivo |
| Tempo na pasta >= `AtencaoMinutos` | Envia o alerta de atenção (uma vez por arquivo) |
| Tempo na pasta >= `CriticoMinutos` | Envia o alerta crítico (uma vez por arquivo) |

O ciclo nunca cai no segundo exato, por isso existe uma **tolerância**
(`ToleranciaSegundos`): sem ela, um arquivo com 9 min 58 s ainda seria "OK" e o
alerta atrasaria um ciclo inteiro.

O tempo de uma pasta sem acesso **para de contar** na última consulta bem
sucedida, para não envelhecer arquivos sem confirmação.

## 5. Arquitetura e fluxo

```text
 Servidor A (monitorado)                    Servidor B (monitor)
 ┌──────────────────────┐   SFTP (somente   ┌───────────────────────────────┐
 │ Pastas de arquivos   │ ◄── listagem) ─── │ Monitor-SFTP.ps1 (laço)       │
 │ (nada instalado)     │                   │   ├─ dados\estado.json        │
 └──────────────────────┘                   │   ├─ dados\monitor-AAAA-MM-DD.log
                                            │   └─ painel\dados\dashboard.json
                                            └──────────┬──────────┬─────────┘
                                                       │          │
                                       SMTP (alertas)  ▼          ▼  HTTP (estático)
                                                  e-mails     painel\index.html
```

## 6. Estrutura do Projeto

    01_fontes/v1.0.0/
    │
    ├── Monitor-SFTP.ps1       # aplicação (laço de monitoramento)
    ├── Testar-Regras.ps1      # testes automatizados das regras
    ├── config.json.example    # modelo de configuração (valores fictícios)
    ├── iniciar.bat            # atalho para rodar manualmente
    ├── README.md
    └── painel/
        ├── index.html         # painel web (estático)
        └── css/style.css

Criados em tempo de execução (não versionados): `config.json`, `dados/`,
`segredos/`, `winscp/`, `simulado/` e `painel/dados/`.

## 7. Responsabilidade dos Arquivos

### Monitor-SFTP.ps1
Arquivo principal. Reúne:
- as **regras de negócio** (funções puras, sem leitura de disco ou rede, que
  são as testadas por `Testar-Regras.ps1`);
- a coleta (WinSCP real ou simulado, no mesmo formato);
- a gravação de `estado.json` e `dashboard.json` (por arquivo temporário e
  troca, para quem lê nunca ver um JSON pela metade);
- o log de auditoria;
- o envio de e-mails;
- o laço principal, com trava de instância única.

Modos de execução:

    .\Monitor-SFTP.ps1                    # laço contínuo
    .\Monitor-SFTP.ps1 -UmCiclo           # um ciclo e sai
    .\Monitor-SFTP.ps1 -SalvarCredencial  # grava a senha SFTP (protegida por DPAPI)
    .\Monitor-SFTP.ps1 -TestarEmail       # envia um e-mail de teste e sai

### Testar-Regras.ps1
Verifica as regras com horários sintéticos, sem rede e sem esperar (ver seção 13).

### painel/index.html
Painel estático. Lê `dados/dashboard.json` a cada 30 segundos. O monitor calcula
nível e minutos; o painel apenas exibe (os limites ficam em um só lugar). Todo
texto vindo do servidor é inserido como texto, nunca como HTML.

### config.json
Parâmetros da aplicação (seção 8). Não é versionado.

## 8. Configuração

Copie `config.json.example` para `config.json` e ajuste:

| Chave | Descrição | Padrão |
|---|---|---|
| `Fonte` | `WinSCP` (servidor real) ou `Simulado` | `WinSCP` |
| `PastaSimulada` | Pasta local que faz o papel do servidor; só o modo `Simulado` usa | - |
| `PastasRemotas` | Lista de pastas a monitorar | - |
| `IntervaloSegundos` | Intervalo entre consultas | 60 |
| `AtencaoMinutos` | Tempo parado para o alerta de atenção | 10 |
| `CriticoMinutos` | Tempo parado para o alerta crítico | 15 |
| `ToleranciaSegundos` | Margem aplicada aos limites | 30 |
| `MaxLacunaMinutos` | Intervalo sem consulta a partir do qual um arquivo alterado vira "outro arquivo" | 3 |
| `FalhasParaAlertar` | Falhas seguidas até o alerta de falha de monitoramento | 3 |
| `RetencaoLogsDias` | Dias de retenção dos logs (`0` = nunca apagar) | 90 |
| `Sftp.Host`, `Porta`, `Usuario` | Conexão SFTP (usuário **somente de listagem**) | - |
| `Sftp.Fingerprint` | Fingerprint da chave SSH do servidor (curinga `*` é recusado) | - |
| `Sftp.WinScpDll`, `WinScpExe` | Caminho do WinSCP, relativo à pasta ou completo | `winscp\...` |
| `Email.SmtpHost`, `SmtpPorta`, `Tls` | Servidor SMTP | porta 25 |
| `Email.Remetente`, `Destinatarios` | Remetente e lista de destinatários | - |

O `config.json` só é lido ao iniciar: reinicie o monitor depois de editar.

A senha do SFTP **não** fica no `config.json`: `-SalvarCredencial` grava em
`segredos\sftp.xml`, protegida por DPAPI (só abre na mesma conta e máquina que
gravou).

## 9. Log de Auditoria

`dados\monitor-AAAA-MM-DD.log` registra o ciclo de vida de cada arquivo, uma linha
por evento, com datas no horário local e fuso:

| Evento | Quando | Dados |
|---|---|---|
| `ENTRADA` | 1ª vez que aparece na pasta | pasta, arquivo, tamanho, data de modificação, janela da entrada real |
| `ALTERADO` | tamanho ou data mudou com o arquivo na pasta | tamanho e data antes e depois |
| `SAIDA` | deixou de aparecer | tamanho final, entrada, última vez visto, `permanencia_minima`, `permanencia_maxima`, alertas recebidos, motivo |

Como o monitor só enxerga o arquivo nas consultas, o tempo real de permanência é
uma **janela**: `permanencia_minima` vai da 1ª à última consulta em que o arquivo
apareceu, e `permanencia_maxima` vai da última consulta sem ele até a 1ª em que
já tinha sumido. Arquivo que já estava na pasta quando o monitor iniciou tem a
entrada real `desconhecida`.

Cada consulta também registra quem está na pasta e há quanto tempo, e cada
e-mail registra os arquivos que cobriu.

Nomes de arquivo vêm do servidor remoto: caracteres de controle (como quebra de
linha) são trocados por `?` para impedir a criação de linhas falsas no log.

## 10. Painel

O painel mostra:

- indicadores gerais (arquivos nas pastas, atenção, crítico, status geral);
- um cartão por pasta, com barra proporcional por status;
- a tabela dos arquivos que estão nas pastas agora;
- a tabela dos **10 últimos arquivos que saíram** (entrada, saída, tempo na pasta
  e e-mail enviado), guardada em `estado.json` para sobreviver a reinícios.

Quando o monitor para de publicar, o painel exibe um aviso de dados
desatualizados. O painel **não** mostra o host do servidor monitorado nem o
texto dos erros de conexão: isso fica no log e no e-mail.

## 11. Requisitos

- Windows com PowerShell 5.1;
- [WinSCP](https://winscp.net) (`WinSCP.exe` e `WinSCPnet.dll`, mesma versão);
- Saída de rede para o servidor SFTP e para o SMTP;
- Uma conta dedicada para o monitor, com o direito "Fazer logon como um
  trabalho em lotes";
- Um servidor web para o painel estático (IIS, por exemplo).

Nenhuma dependência é instalada no servidor monitorado.

## 12. Execução em Ambiente de Desenvolvimento (modo simulado)

O modo simulado usa uma pasta local no lugar do servidor, no mesmo formato de
dados do WinSCP, e não precisa de rede nem de WinSCP.

1. Copie `config.json.example` para `config.json` e use, por exemplo:

        {
          "Fonte": "Simulado",
          "PastaSimulada": "simulado",
          "PastasRemotas": ["/entrada", "/saida"],
          "IntervaloSegundos": 5,
          "AtencaoMinutos": 10, "CriticoMinutos": 15,
          "ToleranciaSegundos": 30, "MaxLacunaMinutos": 3,
          "FalhasParaAlertar": 3, "RetencaoLogsDias": 90,
          "Email": { "SmtpHost": "127.0.0.1", "SmtpPorta": 1, "Tls": false,
                     "Remetente": "monitor@exemplo.invalid", "Destinatarios": ["alguem@exemplo.invalid"] }
        }

2. Inicie o monitor: `.\Monitor-SFTP.ps1` (ou `iniciar.bat`; feche a janela para parar).
3. Coloque arquivos em `simulado\entrada` ou `simulado\saida`.
4. Sirva o painel: `python -m http.server 8843 --directory painel` e abra
   `http://localhost:8843`.
5. Para simular o servidor fora do ar, crie `simulado\SERVIDOR_FORA_DO_AR.txt`;
   apague para voltar. Para simular uma pasta sem acesso, renomeie-a.

> Os alertas saem por e-mail de verdade pelo bloco `Email`, mesmo no modo
> simulado. No exemplo acima o SMTP aponta para um endereço inválido, então o
> envio falha e a falha é registrada no log sem derrubar o monitor.

## 13. Testes

    powershell -NoProfile -ExecutionPolicy Bypass -File Testar-Regras.ps1

São 42 verificações, sem rede e sem esperar (horários sintéticos). Cobrem:

- variação normal da conexão (atenção aos 10 min e crítico aos 15, sem duplicar);
- servidor fora do ar: alerta de falha só na 3ª falha, uma única vez, e aviso de
  normalização;
- falha de consulta não vira "arquivo processado";
- arquivo que muda com e sem lacuna nas consultas;
- diferenciação de maiúsculas e minúsculas, como no SFTP;
- eventos do log de auditoria e a janela de permanência;
- proteção do log contra nomes de arquivo com quebra de linha;
- retenção de logs (só apaga `monitor-AAAA-MM-DD.log` antigo);
- histórico dos 10 últimos arquivos, inclusive a persistência no `estado.json`
  e a ausência do host e dos erros no JSON do painel.

Antes de publicar uma nova versão, verificar:

- [ ] `Testar-Regras.ps1` termina com `TODAS AS REGRAS OK`;
- [ ] O modo simulado gera `ENTRADA`, `SAIDA` e o histórico no painel;
- [ ] `-TestarEmail` entrega a mensagem;
- [ ] Nenhuma credencial, host ou dado real no código e nos exemplos;
- [ ] `CHANGELOG.MD` atualizado e versão ajustada.

## 14. Implantação em Produção

1. Copie a pasta para o servidor B (por exemplo `C:\MonitorSFTP`). **Não** leve
   `segredos\` de outra máquina: a senha só abre na conta e máquina que a gravou.
2. Instale o WinSCP e aponte `WinScpDll` e `WinScpExe` no `config.json`.
3. Configure `Fonte: WinSCP`, o bloco `Sftp` (usuário somente de listagem e
   fingerprint validada com a administradora do servidor monitorado),
   `PastasRemotas` e o bloco `Email`.
4. Como a conta do monitor, grave a senha: `.\Monitor-SFTP.ps1 -SalvarCredencial`.
5. Valide, ainda como essa conta:

        .\Monitor-SFTP.ps1 -TestarEmail
        .\Monitor-SFTP.ps1 -UmCiclo

   O log deve mostrar `Sessao SFTP aberta` e `Consulta OK`.
6. Crie a tarefa agendada (seção 15).
7. Publique `painel\` como site estático e **desligue o acesso anônimo**: o painel
   mostra nomes de arquivos. Restrinja por grupo e, se possível, por IP.

## 15. Tarefa Agendada

O monitor é um laço contínuo. A tarefa o inicia com o servidor, mesmo sem
ninguém logado, e o sobe de novo em até 2 minutos se ele cair. No PowerShell
como administrador:

    $c = Get-Credential 'DOMINIO\conta-do-monitor'
    $acao = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory 'C:\MonitorSFTP' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\MonitorSFTP\Monitor-SFTP.ps1"'
    $regras = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -MultipleInstances IgnoreNew
    $gatilhos = (New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 2))
    Register-ScheduledTask -TaskName 'Monitor SFTP' -Action $acao -Trigger $gatilhos -Settings $regras -User $c.UserName -Password $c.GetNetworkCredential().Password
    Start-ScheduledTask -TaskName 'Monitor SFTP'

Pontos validados em teste:

- A opção "Se a tarefa falhar, reiniciar a cada…" do Agendador **não** reinicia um
  script que termina com erro (inclusive por encerramento forçado). O que
  mantém o monitor de pé é o **segundo gatilho, que repete a cada 2 minutos**,
  combinado com "não iniciar nova instância": a repetição é ignorada enquanto o
  monitor roda e o inicia se ele tiver morrido.
- `-ExecutionTimeLimit 0` é necessário: o limite padrão de 3 dias encerraria o
  monitor.
- `Stop-ScheduledTask` sozinho não segura o monitor parado (o gatilho o religa
  em até 2 minutos). Para parar de verdade:
  `Disable-ScheduledTask 'Monitor SFTP'; Stop-ScheduledTask 'Monitor SFTP'`.
- Só uma instância roda por pasta (trava em `dados\monitor.trava`).

## 16. Solução de Problemas

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| E-mail não chega | SMTP recusou, IP não autorizado, porta bloqueada ou caiu em lixo eletrônico | Rode `-TestarEmail`; leia a mensagem `FALHA ao enviar e-mail` no log; "aceito" não é "entregue" |
| Erro de senha SFTP | Credencial gravada por outra conta ou máquina | Rode `-SalvarCredencial` com a conta que executa o monitor |
| Painel mostra "Não foi possível ler os dados" | Página aberta por duplo clique (`file://`) ou site mal configurado | Abra pelo endereço HTTP do painel |
| Painel mostra "dados desatualizados" | O monitor parou de publicar | Verifique a tarefa agendada e o log do dia |
| Tarefa com `LastTaskResult 0x1` | O script terminou com erro (config inválida, DLL ausente) | Rode o script manualmente com a conta do monitor e leia a mensagem |
| Tarefa com `0x2` | Já existe outro monitor rodando nesta pasta | Feche a outra instância (por exemplo, `iniciar.bat`) |
| Tarefa com `0x80070569` | A conta não tem o direito de logon em lote | Conceda o direito na política de segurança local |

## 17. Segurança

Controles já implementados:

- Operação **somente leitura** no servidor monitorado (listagem);
- Fingerprint SSH obrigatória; curinga `*` é recusado;
- Senha SFTP fora do `config.json`, protegida por DPAPI;
- Nomes de arquivo tratados como dados não confiáveis: sanitizados no log,
  codificados em HTML nos e-mails e inseridos como texto no painel;
- Gravação atômica dos JSON (arquivo temporário e troca);
- Trava de instância única que o sistema libera sozinho se o processo morrer;
- Host e texto dos erros de conexão fora do painel.

Pontos de atenção, mapeados para técnicas do MITRE ATT&CK:

| Verificar | Por quê |
|---|---|
| Usuário SFTP **somente de listagem** (sem escrita nem exclusão) | O monitor nunca grava, mas a credencial vale o que o servidor permitir; com escrita, quem a obtiver pode adulterar arquivos (T1565.001) |
| Painel sem acesso anônimo e, de preferência, em HTTPS | O painel mostra nomes e horários dos arquivos; em HTTP o tráfego é visível e alterável na rede (T1040, T1557) |
| WinSCP em pasta que só administradores alteram, com assinatura conferida | A DLL roda no processo que tem a senha SFTP (T1195.002, T1574) |
| Permissões de escrita restritas na pasta de instalação | Quem altera o script, o `config.json` ou o WinSCP executa código com a conta do monitor (T1574, T1053.005) |
| Remetente em caixa compartilhada | O relay SMTP liberado por IP, sem senha, permite que qualquer processo do servidor envie como o remetente |
| Logs enviados para fora do servidor e Script Block Logging ligado | A conta do monitor consegue alterar os próprios logs (T1070.004) |
| Avisar o time de segurança da tarefa agendada | `-ExecutionPolicy Bypass -WindowStyle Hidden` é um padrão que EDRs costumam marcar (T1059.001, T1564.003) |

Limitação conhecida: nada avisa quando o próprio monitor para de rodar (T1489,
T1562). O painel exibe um aviso, mas só para quem o abre. O ideal é outra
máquina verificar a idade de `painel\dados\dashboard.json` e enviar e-mail.

Não armazenar no repositório: senhas, tokens, hosts, usuários, fingerprints,
endereços de e-mail reais ou qualquer dado do ambiente de produção.

## 18. Controle de Versão

As versões seguem o padrão:

    MAJOR.MINOR.PATCH

Alterações incompatíveis incrementam o MAJOR; funcionalidades compatíveis
incrementam o MINOR; correções e pequenos ajustes incrementam o PATCH.
Cada versão fica em uma pasta própria (`01_fontes/vX.Y.Z`), com a documentação
correspondente em `02_documentacao/vX.Y.Z` e o registro em
`03_notas_versao/CHANGELOG.MD`.

Processo recomendado para uma nova versão:

    Alteração no código
        ↓
    Testes (Testar-Regras.ps1 e modo simulado)
        ↓
    Atualização da versão e do CHANGELOG
        ↓
    Criação do publicável (02_publicaveis, não versionado)
        ↓
    Implantação e teste no servidor

## 19. Manutenção e Rollback

Para atualizar o código em produção:

1. Pare o monitor de verdade (`Disable-ScheduledTask` e `Stop-ScheduledTask`);
2. Substitua `Monitor-SFTP.ps1` e `painel\`, **mantendo** `config.json`, `dados\`
   e `segredos\`;
3. Volte a tarefa (`Enable-ScheduledTask` e `Start-ScheduledTask`).

O `estado.json` de versões anteriores continua sendo aceito. Para voltar a uma
versão anterior, restaure a pasta `01_fontes/vX.Y.Z` correspondente.

## 20. Histórico

### Versão 1.0.0
Primeira versão publicada. Ver `03_notas_versao/CHANGELOG.MD`.

## 21. Responsável

Projeto: Monitoramento de Arquivos por SFTP
Responsável pelo desenvolvimento: João Pedro Barboza Godoi
Área: Tecnologia da Informação
Data: 22/10/2026
