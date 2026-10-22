# Histórico de Versões

## 1.0.0 - 22/10/2026

### Adicionado
- Monitoramento de pastas de um servidor remoto por SFTP (WinSCP), sem instalar nada no servidor monitorado.
- Alertas por e-mail de atenção (10 minutos) e crítico (15 minutos), com tolerância configurável.
- Alerta de falha de monitoramento (3 falhas seguidas) e aviso de normalização.
- Log de auditoria com o ciclo de vida de cada arquivo (ENTRADA, ALTERADO e SAIDA) e a janela de permanência mínima e máxima.
- Retenção configurável dos logs (padrão de 90 dias).
- Painel web com status por pasta, arquivos em andamento e os 10 últimos arquivos que saíram das pastas.
- Modo simulado, para testes sem servidor real.
- Modos de execução -UmCiclo, -SalvarCredencial e -TestarEmail.
- Execução contínua por tarefa agendada do Windows, com recuperação automática.
- 42 verificações automatizadas das regras de negócio (Testar-Regras.ps1).

### Segurança
- Operação somente leitura no servidor monitorado.
- Fingerprint SSH obrigatória (curinga recusado).
- Senha SFTP fora do arquivo de configuração, protegida por DPAPI.
- Nomes de arquivo sanitizados no log, codificados nos e-mails e inseridos como texto no painel.
- Host do servidor e texto dos erros de conexão não são exibidos no painel.

### Observações
- O intervalo padrão de consulta é de 60 segundos.
- O histórico dos 10 últimos arquivos fica em estado.json e sobrevive a reinícios.
- Limitação conhecida: não há alerta quando o próprio monitor para de rodar.
