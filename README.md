# dcn_regdump

Utility for dumping HDMI-related registers from the AMD GPU Display Core Next (DCN).
Supports DCN 3.2.x (RX 7000 series) and DCN 4.x.x (RX 9000 series), and any other
generation with header files present in `dcn_reg/`.

> **Warning:** Only run this on hardware with matching register definitions in `dcn_reg/`.
> Running on an unsupported GPU may cause a crash.

## Dependencies

- [`iotools`](https://github.com/adurbin/iotools) — must be in `PATH`
- `lspci` (from `pciutils`)
- Must be run as root

## Usage

```
sudo ./dcn_regdump.sh
```

The script automatically detects the DCN version from `dmesg` and selects the
appropriate register definitions. Output is printed to stdout; redirect to a file
to save a log:

```
sudo ./dcn_regdump.sh | tee dcn_regdump.$(date +%Y%m%d-%H%M%S).log
```

## Capturing logs with a GPU passthrough VM

The typical workflow for capturing registers in a specific GPU/display state
(e.g. Windows with a particular driver or display config) is:

1. **Boot a Windows VM** with the AMD GPU passed through (e.g. via VFIO/QEMU).
   The GPU is now fully controlled by the Windows guest driver.

2. **On the Linux host**, while the VM is running, run the script:
   ```
   sudo ./dcn_regdump.sh | tee my_capture.log
   ```
   The host can still access the GPU's MMIO registers directly through the PCI BAR
   even while the GPU is owned by the guest.

3. To capture multiple states (e.g. before and after plugging in a display, or
   with audio playing vs. silent), run the script once per state and save each
   to a separate log file.

## Register definitions

Register offset and shift/mask definitions live in `dcn_reg/` as C headers extracted
from the Linux kernel's `amdgpu` driver source. The script also accepts preprocessed
flat `.txt` versions (`dcn321_regs.txt`, `dcn410_regs.txt`, etc.) which are faster
to load if present.

To add support for a new DCN generation, drop the corresponding
`dcn_X_Y_Z_offset.h` and `dcn_X_Y_Z_sh_mask.h` files into `dcn_reg/`.
