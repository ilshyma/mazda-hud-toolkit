# Mazda CMU CarPlay-HUD Toolkit — Português

Navegação turn-by-turn do **Apple CarPlay** no **Head-Up Display** do quadro de instrumentos para Mazda CMU150 (firmware 74.00.324) — com indicador correto de limite de velocidade em **km/h** para o mercado europeu.

**Compatível com:** CX-5 KF, CX-8, CX-9 (2018) e unidades da mesma plataforma com firmware EU.

**Traduções:** [English](README.md) · [Українська](README.uk.md) · [Español](README.es.md) · [Deutsch](README.de.md)

---

## O que este kit faz

Baseado no mod comunitário [KidMixer/mazda-carplay-hud](https://github.com/KidMixer/mazda-carplay-hud) com duas adições para veículos do mercado europeu:

1. **Correção km/h** — patch de uma linha no código-fonte (`displaySpeedUnit = 2` em vez de `1`, isto é, enum VBS `km/h` em vez de `mph`). Sem esta correção, um HUD europeu desenha um sinal de `50 km/h` vindo do shim como `≈80 km/h` após conversão milha→km.
2. **Daemon-espelho do limite de velocidade** — pequeno script shell que escuta passivamente o fluxo HUD original de `svcjcinavi.so` e copia o valor *atual* do limite nos frames keep-alive do próprio shim. Sem ele, o shim sobrescreve o slot de velocidade com `0` a cada 500 ms e o valor cai para `---` entre atualizações OEM.

Tudo o mais é bit-a-bit o original de KidMixer.

---

## Requisitos

- Mazda CMU150, firmware `74.00.324`, versão EU (verificação: `cat /jci/version.ini`)
- USB flash drive (≥1 GB, formato FAT32)
- Um computador com Wi-Fi (macOS, Linux ou Windows 10+)
- Wi-Fi hotspot no CMU (vem com dongles CarPlay sem fio) ou o setup root+SSH descrito abaixo

## Conteúdo

```
mazda-hud-toolkit/
├── toolkit.sh              # menu macOS/Linux
├── toolkit.bat             # menu Windows (precisa OpenSSH integrado)
├── id_rsa_cmu              # chave SSH para conta `cmu` do head unit
├── files/
│   ├── libpatch-blmjcicarplay.so         # PURE KidMixer .so (md5 0ce29da4…)
│   ├── libpatch-blmjcicarplay-splim.so   # meu .so patched — correção km/h + guard read_splim (md5 faf82efb…)
│   ├── install.sh                        # instalador original KidMixer
│   ├── uninstall.sh                      # desinstalador original
│   ├── splim_bridge.sh                   # meu daemon-espelho do limite de velocidade (v16)
│   ├── splim_udpd_start.sh               # auto-launcher usado pelo shim
│   └── usb_unlock/                       # payload MP3-XSS para acesso root
└── backups/                          # criado pela opção 2 do menu
```

## Menu (tanto `toolkit.sh` quanto `toolkit.bat`)

| # | Ação |
|---|---|
| **1** | **Criar USB de desbloqueio** — formata USB como FAT32/MZD e copia o payload MP3-XSS que dá root+SSH ao CMU. Usa a técnica [mzd-connect-1-root](https://github.com/mzd-evo/mzd-connect-1-root). Insira USB no head unit, toque qualquer MP3, depois toque **SSH** no menu XSS que aparece — `sshd` inicia na porta 36000. |
| **2** | **Backup do CMU** — baixa por SSH um arquivo com todos os ficheiros que o instalador toca (`sm.conf`, `sm_WCP.conf`, `devmgr_config_master.xml`, `blmjcicarplay.so`, `/data_persist/cp-hud-mod/`, `version.ini`) para `backups/YYYYMMDD_HHMMSS/`. Execute ANTES de instalar. |
| **3** | **Instalar PURE KidMixer Patch** — build upstream sem modificação. Rápido e seguro, mas em veículos EU tem um problema conhecido: o slot de limite de velocidade mostra ~80 km/h por uma conversão mile→km que o próprio shim faz, e morre para `---` entre atualizações OEM. Use isto se quiser o comportamento upstream puro ou como base antes de passar à opção 4. |
| **4** | **Instalar ilshyma HUD Patch** ★ recomendado — deploy em 3 passos: (a) `install.sh` original adiciona `LD_PRELOAD` a `sm.conf` e define `NaviSupported=TRUE`, (b) sobrepõe meu `.so` patched (correção km/h + guard `read_splim` contra future-ts), (c) copia daemon-espelho v16 e seu auto-launcher. Termina com reboot; espere ~2 min e restabeleça SSH via USB. |
| **5** | **Rollback completo** — mata meu daemon, remove meus extras, executa o `uninstall.sh` original que restaura `sm.conf` e `NaviSupported=FALSE` dos backups `.bak_precphud`. Termina com reboot. |
| **9** | Verificação da conexão SSH |

## Procedimento inicial

1. Formate um USB, execute **opção 1** para prepará-lo.
2. Insira USB no carro. Media → USB → toque qualquer MP3 → aguarde overlay XSS na parte inferior da tela → toque **SSH**. Logs verdes aparecem, pronto.
3. Conecte seu computador ao Wi-Fi do CMU (`CMU-XX:XX:...` ou `MAZDA-xxx`).
4. Execute **opção 9** para verificar SSH, depois **opção 2** para backup.
5. Execute **opção 4** (ilshyma HUD Patch) para instalar. Aguarde reboot.
6. No head unit, repita passo 2 (USB → SSH) para reativar SSH após reboot.
7. Teste — inicie uma sessão de navegação CarPlay. A seta de manobra deve aparecer no HUD; o slot de limite de velocidade deve mostrar o valor OEM atual (mapa + câmera TSR).

## Notas e limitações

- O shim usa apenas `LD_PRELOAD` — o `blmjcicarplay.so` original NUNCA é modificado no disco. O rootfs read-only não pode ser "brickado"; no pior caso, um reboot retorna a unidade ao stock.
- O daemon-espelho NÃO dispara nenhum request NNG. Apenas escuta o que o serviço OEM (`svcjcinavi.so`) já emite no bus D-Bus. Assim o HUD fica o mais próximo possível do comportamento stock.
- Setas de guia de faixa (`SetRecommLaneReq`) NÃO estão implementadas — a Apple não transmite dados de faixa pelo canal iAP2; apenas o stream de vídeo CarPlay os carrega.
- Nomes de ruas cirílicos renderizam corretamente; o apóstrofo ucraniano (`’`) atualmente aparece como `?` pois a fonte do HUD OEM não tem esse glifo — limitação OEM.
- O build foi feito com `-DCARPLAY_VN_NORMALIZE=1` (normalização de diacríticos vietnamitas). Inofensivo em cirílico/latim.

## Por baixo do capô

- Shim base: **KidMixer/mazda-carplay-hud v2.0.0** — [fonte](https://github.com/KidMixer/mazda-carplay-hud), AGPL-3.0.
- Uma única mudança no código: `hud/hud_send.cpp` linha 561, valor `displaySpeedUnit` `1 → 2` (enum VBS: `1 = mph`, `2 = km/h`).
- Daemon-espelho: nosso script shell de ~60 linhas; observa passivamente chamadas `com.jci.vbs.navi.SetHUDDisplayMsgReq` cujo sender NÃO é nosso shim, e escreve `<km/h> <unix_ts>` em `/data_persist/splim`. Refrescado a cada 3s para satisfazer a verificação stale do shim; TTL 3600s.
- O shim lê `/data_persist/splim` em cada frame keep-alive; se fresco, inclui o valor; se vazio/stale, envia `0`.

## Suporte

Se SSH não conectar na porta 36000, o `sshd` foi eliminado pelo rootfs read-only no boot. Repita USB → XSS → SSH.

Se o HUD permanecer em branco após instalar, verifique com opção 9 primeiro; então entre por SSH e verifique `ps | grep sm_svclauncher | grep jciCARPLAY` — o processo `L_jciCARPLAY` deve estar rodando com `LD_PRELOAD` em seu `/proc/PID/environ`.
