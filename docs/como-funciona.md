# Como funciona

## De onde vêm os dados

### Tokens e atividade: históricos do Claude Code

O app lê `~/.claude/projects/**/*.jsonl` a cada 3 s, só o que foi acrescentado desde a última leitura:

- cada resposta vira várias linhas (uma por bloco) repetindo o mesmo `usage`, então deduplica por `message.id` + `requestId`;
- **tokens hoje** soma `input + output + cache_creation + cache_read`, igual ao `/usage`, por isso fica alto;
- a **média** usa os 7 dias anteriores a hoje;
- a última linha de cada arquivo diz o estado: `tool_use` = ferramenta rodando, `user` = pensando, `end_turn` = terminou.

Isso funciona sem instalar nada no Claude Code: o app do Claude, o terminal e o IntelliJ gravam todos no mesmo lugar.

### Unidades ponderadas

O limite do plano não conta todo token igual. Pra projetar o % entre duas leituras, cada mensagem vira "unidades" com peso de custo:

| Tipo | Peso |
|---|---|
| entrada | 1 |
| saída | 5 |
| escrita de cache 5 min | 1,25 |
| escrita de cache 1 h | 2 |
| leitura de cache | 0,1 |

Por modelo: Opus 1, Sonnet 0,6, Haiku 0,2.

### Estado e permissão: hooks (opcional)

`python3 setup.py` adiciona estes hooks ao `~/.claude/settings.json`, sem remover os que já existem, e faz backup antes:

```json
{
  "hooks": {
    "PreToolUse":       [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\"/usr/bin/python3\" \"<REPO>/hooks/hook.py\"" }] }],
    "PostToolUse":      [{ "matcher": "*", "hooks": [{ "type": "command", "command": "..." }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "..." }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "..." }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "..." }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "..." }] }]
  },
  "statusLine": { "type": "command", "command": "\"/usr/bin/python3\" \"<REPO>/hooks/statusline.py\"" }
}
```

- `hook.py` grava cada sessão separada, pelo `session_id`, em `~/.claudinho/state.json`, com trava de arquivo pra vários agentes escreverem juntos.
- `Notification` com "permission" na mensagem vira **pedindo permissão**. As outras notificações viram **esperando você**.
- O app observa a pasta `~/.claudinho` (`DispatchSource` de sistema de arquivos) e atualiza em ~0,3 s quando um hook grava, sem esperar o timer.
- O app usa os hooks quando o evento deles é tão recente quanto o dos históricos. Se os hooks pararem, ele volta sozinho pros históricos.

### % da sessão e da semana: em camadas

| Fonte | Quando | Exatidão |
|---|---|---|
| statusLine | toda vez que o Claude Code redesenha a statusLine | exato (`rate_limits.five_hour` e `seven_day`) |
| `claude "/usage"` | a cada 60 s com o Claude trabalhando, 15 s depois de terminar; nunca parado | exato, arredondado pra inteiro |
| manual | ⋯ → Calibrar à mão | o que você digitar |
| históricos | o tempo todo, entre leituras | projeção |

Uma leitura da statusLine menor que a anterior na mesma janela é descartada: o uso só sobe dentro da janela, então ela é velha.

Cada leitura real vira a **âncora**: o % mostrado é `% da leitura + unidades desde a leitura ÷ limite`. Quando duas leituras seguidas caem na mesma janela e o % andou pelo menos 3 pontos (2 na semana), o limite é medido de novo e tirada a média com o valor antigo.

Se a janela da âncora já passou, a sessão é estimada só pelos históricos: começa na hora cheia da primeira mensagem e dura 5 h. A semana sempre segue o ciclo de `weekResetsAt`.

### O `/usage` escondido

O `/usage` só existe na tela interativa do Claude Code. O app roda:

```sh
/usr/bin/script -q /dev/null claude "/usage"     # dentro de ~/.claudinho
```

`script` dá um pseudo-terminal pro Claude Code desenhar a tela. O app lê a saída, tira os códigos de cor, procura "Current session … N% used" e "Current week … N% used", e mata o processo assim que acha os números (cerca de 1 s). Não chama o modelo, não gasta limite e não grava sessão nos históricos.

Na primeira vez o Claude Code pergunta se você confia na pasta `~/.claudinho`. Veja [problemas.md](problemas.md).

## Recursos

| O quê | Como |
|---|---|
| Ícone | `NSStatusItem` em AppKit, imagem template 27×16 pt que segue o tema claro/escuro |
| Animação | 1 quadro por segundo, só quando o Claude está trabalhando ou o painel está aberto |
| Painel | SwiftUI num `NSPopover`, criado ao abrir e descartado ao fechar |
| Sprites | cache por estado e quadro, gerados uma vez |
| Memória | ~37 MB (pico de ~90 MB durante uma leitura do `/usage`) |
| CPU | ~0% parado, ~2,5% com o Claude trabalhando |
| `/usage` | ~1 s por leitura, no máximo 1 por minuto, e só com atividade nova |
| Instância | se já tem um Claudinho rodando, o segundo fecha sozinho |

## Rodando sozinho

`install.sh` copia o app pra `~/Applications` e registra `~/Library/LaunchAgents/local.claudinho.monitor.plist`:

- `RunAtLoad`: abre no login;
- `KeepAlive.SuccessfulExit = false`: volta se travar, mas não volta se você sair pelo menu;
- ao acordar o Mac (`NSWorkspace.didWakeNotification`), atualiza na hora.
