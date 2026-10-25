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

`python3 setup.py` copia `hooks/hook.py` e `hooks/statusline.py` pra `~/.claudinho/hooks` e adiciona estes hooks ao `~/.claude/settings.json`, sem remover os que já existem, e faz backup antes. Como os scripts ficam fora do repo, ele pode ser apagado depois:

```json
{
  "hooks": {
    "PreToolUse":       [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\"/usr/bin/python3\" \"~/.claudinho/hooks/hook.py\"" }] }],
    "PostToolUse":      [{ "matcher": "*", "hooks": [{ "type": "command", "command": "..." }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "..." }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "..." }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "..." }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "..." }] }]
  },
  "statusLine": { "type": "command", "command": "\"/usr/bin/python3\" \"~/.claudinho/hooks/statusline.py\"" }
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

Cada leitura real vira a **âncora**: o % mostrado é `% da leitura + unidades desde a leitura ÷ limite`. O limite é medido com as leituras do `/usage` guardadas na janela: entre a mais antiga (ignorando o 0% do começo) e a mais nova, desde que tenham pelo menos 15 min e 5 pontos de diferença (1 h e 3 pontos na semana). O valor anda meio caminho até a medida nova, sem mais que dobrar ou cortar pela metade de uma vez. A statusLine e a calibração manual não entram nessa conta.

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

## O Claudinho de mesa

Uma `NSPanel` sem borda e não ativável, com o mesmo `Card` do widget nativo dentro de um `NSHostingView`:

- **Nível:** `desktopIconWindow + 1`, logo acima dos ícones da mesa e abaixo de qualquer janela.
- **Mesas:** `canJoinAllSpaces` e `stationary`, então aparece em todos os Spaces e não se mexe no Mission Control.
- **Dados:** observa o mesmo `Monitor` da barra de menu. Muda no mesmo instante que o ícone.
- **Animação:** usa o mesmo `Ticker`, 1 quadro por segundo e só enquanto o Claude trabalha. Parado, não redesenha.
- **Posição:** arrastar move a janela (`mouseDownCanMoveWindow`). Tamanho e posição ficam em `~/.claudinho/mesa.json`. Se a posição salva não cabe mais em nenhuma tela (monitor desligado, resolução trocada), o cartão volta pro canto de cima à direita.

## O widget nativo

O widget é uma extensão WidgetKit embutida no app (`Contents/PlugIns/ClaudinhoWidget.appex`). Ele roda em sandbox, então não lê os históricos nem roda o `/usage`:

1. A cada atualização, o app monta um `WidgetSnapshot` (estado, %, renovações, tokens, ferramenta) e grava em `~/.claudinho/widget.json`.
2. Se o desenho mudou, o app chama `WidgetCenter.reloadTimelines(ofKind: "claudinho")`. Troca de estado recarrega na hora; mudança de % ou ferramenta, no máximo a cada 30 s, pra não estourar o limite diário de recargas do macOS.
3. O widget lê o arquivo pelo `temporary-exception.files.home-relative-path.read-only` (`/.claudinho/`) e se redesenha. Sozinho, ele só se atualiza a cada 15 min.
4. Se o arquivo tem mais de 15 min, o app está fechado ou o Mac dormiu: o widget mostra "Descansando" e zera a sessão se a janela já renovou.

O widget é linkado com `-e _NSExtensionMain`, como o Xcode faz com extensões; sem isso ele trava ao abrir. O app e o widget são assinados com o certificado "Apple Development" do chaveiro, se tiver, ou ad hoc (`codesign --sign -`). Os dois funcionam, sem conta de desenvolvedor. Quem escolhe é `tools/identidade.sh` (ou `CLAUDINHO_SIGN_IDENTITY`).

## Rodando sozinho

`install.sh` copia o app pra `~/Applications` e registra `~/Library/LaunchAgents/local.claudinho.monitor.plist`:

- `RunAtLoad`: abre no login;
- `KeepAlive.SuccessfulExit = false`: volta se travar, mas não volta se você sair pelo menu;
- ao acordar o Mac (`NSWorkspace.didWakeNotification`), atualiza na hora.
