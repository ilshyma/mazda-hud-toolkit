# Mazda CMU CarPlay-HUD Toolkit — Português

Navegação turn-by-turn do **Apple CarPlay** no **Head-Up Display** do painel de instrumentos para Mazda CMU150 (firmware 74.00.324) — com indicador correto de limite de velocidade em **km/h** para o mercado europeu.

**Compatível com:** CX-5 KF, CX-8, CX-9 (2016-2023) e veículos da mesma plataforma com firmware EU.

**Traduções:** [English](README.md) · [Українська](README.uk.md) · [Español](README.es.md) · [Deutsch](README.de.md)

---

## O que este toolkit faz

Baseado no shim `LD_PRELOAD` [KidMixer/mazda-carplay-hud](https://github.com/KidMixer/mazda-carplay-hud) construído pela comunidade, com duas adições para veículos europeus:

1. **Correção km/h** — patch de uma linha no código fonte (`displaySpeedUnit = 2` em vez de `1`, enum VBS `km/h` em vez de `mph`). Sem isto, um HUD EU renderiza um sinal `50 km/h` vindo do shim como `≈80 km/h` após conversão mile→km.
2. **Daemon-espelho do limite de velocidade** — pequeno script shell que escuta passivamente o stream HUD do `svcjcinavi.so` OEM e copia o limite *atual* para os frames keep-alive do próprio shim. Sem isto, o shim sobrescreve o slot de velocidade com `0` a cada 500 ms e o valor morre para `---` entre atualizações OEM.

Tudo o resto é bit-a-bit o build original KidMixer.

---

## Requisitos

- Mazda CMU150, firmware `74.00.324`, versão EU (verificar: `cat /jci/version.ini` no CMU)
- Pen USB (≥1 GB, formatada FAT32)
- Um computador com Wi-Fi (macOS, Linux ou Windows 10+)
- Hotspot Wi-Fi no seu CMU (vem com dongles CarPlay sem fios) ou setup root+SSH a funcionar

## Conteúdo

```
mazda-hud-toolkit/
├── toolkit.sh              # menu macOS/Linux
├── toolkit.bat             # menu Windows (precisa OpenSSH integrado)
├── id_rsa_cmu              # gerada pela opção B no primeiro uso (NÃO vem incluída)
├── files/
│   ├── libpatch-blmjcicarplay.so         # PURE KidMixer .so (md5 0ce29da4…)
│   ├── libpatch-blmjcicarplay-splim.so   # meu .so patched — correção km/h + guard read_splim (md5 faf82efb…)
│   ├── install.sh                        # instalador original KidMixer
│   ├── uninstall.sh                      # desinstalador original
│   ├── splim_bridge.sh                   # meu daemon-espelho do limite de velocidade (v16)
│   ├── splim_udpd_start.sh               # auto-launcher usado pelo shim
│   └── usb_unlock/                       # payload MP3-XSS para acesso root
└── backups/                              # criado pela opção 2 do menu
```

## Menu (tanto `toolkit.sh` quanto `toolkit.bat`)

| # | Ação |
|---|---|
| **1** | **Criar pen USB** — formata uma USB (FAT32, etiqueta MZD) com o desbloqueio MP3-XSS (botão SSH) **e** o patch HUD (`hud-mod/`). No carro, o menu no ecrã oferece **SSH**, **HUD+** (instalar), **HUD-** (remover) e **HUD?** (verificar), para instalar o patch sem portátil. |
| **2** | **Backup do CMU** — baixa por SSH um arquivo com todos os ficheiros que um patch toca para `backups/YYYYMMDD_HHMMSS/`. Execute isto antes de instalar. |
| **3** | **Rollback** — remove **todos** os patches HUD: CarPlay + Android Auto, ilshyma v16 com seu daemon, KidMixer e oem-aa-mod. Volta ao estado de fábrica, reinicia e confirma. |
| **4** | **Instalar patch HUD (CarPlay + Android Auto)** — um patch único para ambos os telefones: setas e distância para CarPlay e Android Auto, mais o sinal de limite de velocidade da navegação de série (precisa do SD de navegação). Cada ficheiro é verificado por md5. O toolkit reinicia a unidade, aguarda SSH e verifica que os 4 módulos carregaram. Fonte: [mazda-carplay-hud `unified-carplay-aa`](https://github.com/ilshyma/mazda-carplay-hud/tree/unified-carplay-aa). A linha de nome de rua não aparece em HUDs EU. |
| **B** | **Configurar chave SSH** — setup único para o fluxo SSH (opções 2 / 3 / 4). Gera `id_rsa_cmu` se não existir e instala a metade pública em `authorized_keys` do CMU usando a palavra-passe de uso único `cmu:jci` do desbloqueio USB XSS. Só necessário num computador novo. |
| **A** | **Avançado** — validar instalação, verificação SSH, dump diagnóstico e patches antigos só-CarPlay (v16, pure KidMixer, legacy) com as suas ferramentas. |


### Instalar o patch HUD a partir da pen USB (sem portátil)

A pen da opção 1 também traz o patch CarPlay + Android Auto (`hud-mod/`). No carro, abra normalmente: Media → USB → toque num MP3. O menu em cima do ecrã tem três botões adicionais:

- **HUD+** instala o patch. Toque, depois no botão vermelho de confirmação. A unidade reinicia sozinha após ~30 s.
- **HUD-** remove-o, volta ao stock. Confirmação igual.
- **HUD?** verifica que cada parte está ativa: CarPlay, Android Auto, Navi/velocidade.

Cada botão termina com uma mensagem no ecrã. Se começar com **ERROR** ou **CHECK S1**, fotografe e envie. Contém um código de erro, versão do firmware, região e o que fazer. Cada tentativa recebe a sua pasta numerada na pen, `hud-mod/logs/001_install_<data>/`, com o mesmo texto (`RESULT.txt`), log completo (`run.log`) e snapshot do sistema (`system.txt`). Envie essa pasta juntamente com a foto.

## Duas formas de instalar

| | **A. Só USB** _(predefinição — nada para escrever)_ | **B. Instalação SSH a partir do seu computador** |
|---|---|---|
| O que faz no carro | Insere a pen → toca em **Install** no diálogo. | Insere a pen → toca em **SSH** no menu XSS. |
| O que corre no CMU | O patch é instalado automaticamente da USB. | Um pequeno `sshd` arranca em `192.168.53.1:36000`. |
| O que faz no seu computador | Nada. | Executa **opções 2 / 4** deste toolkit por SSH. |
| Precisa de chave SSH? | Não. | Sim — gere-a uma vez com a opção **B** abaixo. |
| Precisa da pen USB? | Sim, em cada instalação. | Sim, uma vez por arranque do CMU (para reativar o SSH — o CMU mata o `sshd` ao reiniciar). |

Escolha A se só quer o mod HUD. Escolha B se também quer backups, auto-validação, diagnóstico ou as variantes antigas só-CarPlay (menu `L` / `P` / `X`).

### A. Só USB (recomendado para a maioria)

1. Execute **opção 1** no seu computador — cria a pen USB.
2. Insira a pen no carro — espere ~30 s. Aparece um diálogo com **Install / Uninstall / Check Status** automaticamente (o scanner reflash do CMU é ativado via payloads `.up`). Se nada aparecer: Media → USB → toque qualquer mp3 — o menu XSS fallback tem botões **HUD+ / HUD- / HUD?**.
3. Toque em **Install**. O ecrã apaga durante ~2 min enquanto a unidade reinicia — é normal, não desligue a ignição.
4. Pronto. Inicie navegação em CarPlay ou Android Auto; a seta deve aparecer no HUD.

### B. Instalação SSH a partir do seu computador (utilizadores avançados)

1. **Crie a pen USB** — execute **opção 1**.
2. **Ative SSH no CMU** — insira a pen no carro, Media → USB → toque qualquer mp3 → toque em **SSH** no overlay XSS. Aparecem logs. (sshd agora escuta em `192.168.53.1:36000`. Morre em cada arranque — repita este passo após cada reinício.)
3. **Ligue-se ao Wi-Fi do CMU** no seu computador (`CMU-XX:XX:...` ou `MAZDA-xxx`).
4. **Configure a chave SSH — uma vez por computador:** execute **opção B**. O toolkit gera `id_rsa_cmu`, instala a metade pública no CMU usando a palavra-passe de uso único `jci` e verifica o login por chave. Introduz a palavra-passe exatamente uma vez.
5. **Verifique + backup** — Avançado → **S** (verificação SSH), depois **opção 2** (backup).
6. **Instale** — execute **opção 4**. Cada ficheiro é verificado por md5, o CMU reinicia, o toolkit espera que o SSH volte e auto-valida os 4 shims. (Após o reinício, repita o passo 2 quando o toolkit pedir — para que o SSH esteja ativo para a validação.)
7. **Teste** — inicie uma sessão de navegação em CarPlay ou Android Auto. A seta de manobra deve aparecer no HUD; o slot de limite de velocidade deve mostrar o valor OEM atual (mapa + câmara TSR).

> **A chave SSH NÃO vem incluída** — o release público não tem `id_rsa_cmu`. A opção **B** cria-a localmente e instala-a no CMU. A chave privada nunca sai do seu computador; o lado CMU guarda a metade pública em `/data_persist/.../authorized_keys` para sobreviver aos reinícios.

## Notas e limitações

- O shim usa apenas `LD_PRELOAD` — o `blmjcicarplay.so` original NUNCA é modificado no disco. O rootfs read-only não pode ser "brickado"; no pior caso, um reboot retorna a unidade ao stock.
- O daemon-espelho NÃO dispara nenhum request NNG. Apenas escuta o que o serviço OEM (`svcjcinavi.so`) já emite no bus D-Bus. Assim o HUD fica o mais próximo possível do comportamento stock.
- Setas de guia de faixa (`SetRecommLaneReq`) NÃO estão implementadas — a Apple não transmite dados de faixa pelo canal iAP2; apenas o stream de vídeo CarPlay os carrega.
- Nomes de ruas cirílicos renderizam corretamente; o apóstrofo ucraniano (`’`) atualmente aparece como `?` pois a fonte do HUD OEM não tem esse glifo — limitação OEM.
- O build foi feito com `-DCARPLAY_VN_NORMALIZE=1` (normalização de diacríticos vietnamitas). Inofensivo em cirílico/latim.

## Por baixo do capô

- Shim base: **KidMixer/mazda-carplay-hud v2.0.0** — [fonte](https://github.com/KidMixer/mazda-carplay-hud), AGPL-3.0.
- Uma única mudança no código: `hud/hud_send.cpp` linha 561, valor `displaySpeedUnit` `1 → 2` (enum VBS: `1 = mph`, `2 = km/h`).
- Daemon-espelho: nosso script shell de ~60 linhas; observa passivamente chamadas `com.jci.vbs.navi.SetHUDDisplayMsgReq` cujo sender NÃO é nosso shim, e escreve `<km/h> <unix_ts>` em `/data_persist/splim`. Refrescado a cada 3s; TTL 3600s.
- O shim lê `/data_persist/splim` em cada frame keep-alive; se fresco, inclui o valor; se vazio/stale, envia `0`.

## Suporte

Se SSH não conectar na porta 36000, o `sshd` foi eliminado pelo rootfs read-only no boot. Repita USB → XSS → SSH.

Se o bootstrap por palavra-passe (**opção B**) disser *"Permission denied"*, a palavra-passe está errada. O desbloqueio USB XSS define `cmu:jci` — digite `jci` (minúsculas, três letras) no prompt. Se continuar a falhar, o USB não ativou — repita o passo 2 (USB → XSS → SSH) e tente B novamente.

Se o HUD permanecer em branco após instalar, verifique com Avançado → **V** primeiro; então entre por SSH e verifique `ps | grep sm_svclauncher | grep jciCARPLAY` — o processo `L_jciCARPLAY` deve estar rodando com `LD_PRELOAD` em seu `/proc/PID/environ`.
