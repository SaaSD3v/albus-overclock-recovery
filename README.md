# Albus Overclock Recovery

Recovery TWRP com overclock para Moto Z2 Play (albus).

## Overclock Specs

| Componente | Stock | Overclock Recomendado | Máximo |
|------------|-------|----------------------|--------|
| **CPU** | 2208 MHz | 2300-2400 MHz | 2500 MHz |
| **GPU** | 650 MHz | 700-800 MHz | 950 MHz |

## Modificações aplicadas

### 1. CPU Clock Driver (`clock-cpu-8953.c`)
- `max_rate`: 2208 MHz → 2500 MHz
- `VDD_MX`: 2400 MHz → 2600 MHz

### 2. Device Tree (DTS)
- GPU: `qcom,gpu-freq` patchado via binary
- CPU: `cpufreq-table` patchado via binary

### 3. Binary Patch
- Valores big-endian no DTB compilado são substituídos
- Funciona mesmo com `make dtbs` em ARCH=arm64

## Como usar

### GitHub Actions
1. Vá em **Actions** → **Build Overclocked Recovery**
2. Clique em **Run workflow**
3. Insira os valores de GPU e CPU MHz
4. Aguarde o build completar
5. Baixe o `recovery.img` dos artifacts

### Local
```bash
# Configurar valores
export GPU_MHZ=700
export CPU_MHZ=2300

# Rodar build
bash scripts/build-overclock.sh
```

### Flash via TWRP
1. Copie `recovery.img` para o dispositivo
2. No TWRP: **Install** → selecione `recovery.img`
3. Ou: **Advanced** → **Install Recovery Ramdisk**

## Limites de Segurança

| Componente | Limite Seguro | Limite Máximo |
|------------|---------------|---------------|
| CPU | 2400 MHz | 2500 MHz |
| GPU | 800 MHz | 950 MHz |

**⚠️ Aviso:** Overclock acima dos limites recomendados pode causar:
- Instabilidade do sistema
- Aquecimento excessivo
- Degradação do hardware
- Perda de dados

## Requisitos

- Cooler externo recomendado
- Para CPU > 2400 MHz: remoção de tela + cooler
- Controle via ADB shell

## Estrutura

```
recovery-overclock/
├── .github/
│   └── workflows/
│       └── build-overclock.yml
├── scripts/
│   └── build-overclock.sh
├── patches/
├── README.md
└── LICENSE
```

## Créditos

- Kernel: [SaaSD3v/android_kernel_motorola_msm8996](https://github.com/SaaSD3v/android_kernel_motorola_msm8996)
- TWRP: [twrp.me/albus](https://twrp.me/motorola/motorolamotoz2play.html)
- Magisk: [topjohnwu/Magisk](https://github.com/topjohnwu/Magisk)
