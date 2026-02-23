#!/bin/bash
# dcn_regdump.sh - Generic AMD GPU DCN register dump tool
# Automatically detects DCN version from dmesg and dumps relevant display registers.
# Supports reading from preprocessed .txt files or raw C header files in dcn_reg/.

if [ $UID -ne 0 ]; then
	echo "This script must be run as root!"
	exit 1
fi

if ! which iotools &>/dev/null; then
	echo "iotools not found! Please install iotools from https://github.com/adurbin/iotools.git first."
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# DCN version → header file prefix mapping table.
# Normally dmesg "X.Y.Z" maps directly to dcn_X_Y_Z_offset.h (dots → underscores).
# List special cases where the dmesg version string differs from the file naming.
# ---------------------------------------------------------------------------
declare -A DCN_VERSION_MAP
DCN_VERSION_MAP["4.0.1"]="4_1_0"   # DCN 4.0.1 hardware uses dcn_4_1_0 header files

# ---------------------------------------------------------------------------
# DCN MMIO base address table indexed by BASE_IDX value.
# NOTE: These values apply to RDNA3/4 hardware (DCN 3.2.x and 4.x.x).
# Older GPU generations may require different values.
# ---------------------------------------------------------------------------
dcn_base[1]=$((0xc0))
dcn_base[2]=$((0x34c0))
dcn_base[3]=$((0x9000))

# ---------------------------------------------------------------------------
# Register sections to discover and dump: "SECTION_TITLE:bare_name_pattern"
# Patterns are bare register name prefixes WITHOUT the reg/mm prefix.
# The correct prefix is detected at runtime and prepended automatically.
# Patterns support extended regex (passed to grep -E).
# ---------------------------------------------------------------------------
REG_SECTIONS=(
	"PHY_MUX:PHY_MUX"
	"HDMICHARCLOCK:HDMICHARCLK"
	"HDMI:HDMI"
	"DIO:DIO"
	"DIG:DIG"
	"DCCG:DCCG"
	"HPO:HPO"
	"SYMCLK:SYMCLK"
	"PHY_SYMCLK:PHY[A-G]SYMCLK"
	"VPG:VPG"
	"DME:DME"
	"AFMT:AFMT"
	"DTBCLK:DTBCLK"
	"OTG:OTG"
	"DENTIST:DENTIST"
)

# ---------------------------------------------------------------------------
# GPU PCI detection
# ---------------------------------------------------------------------------
gpu_bdf=$(lspci -D -d 1002: | grep -E "VGA|Display|3D" | head -n 1 | awk '{print $1}')
if [ -z "$gpu_bdf" ]; then
	echo "Error: No AMD GPU found on this system."
	exit 1
fi
echo "Found AMD GPU at $gpu_bdf"

resource_file="/sys/bus/pci/devices/$gpu_bdf/resource"
if [ ! -f "$resource_file" ]; then
	echo "Error: Resource file not found at $resource_file"
	exit 1
fi
echo "Found resource file at $resource_file"

last_bar_raw=$(head -n 6 "$resource_file" | awk '{print "BAR"NR-1, $0}' | grep -v "0x0000000000000000 0x0000000000000000" | tail -n 1)
bar_name=$(echo "$last_bar_raw" | awk '{print $1}')
bar_start=$(echo "$last_bar_raw" | awk '{print $2}')
echo "Using $bar_name at $bar_start"
rbase=$bar_start

# ---------------------------------------------------------------------------
# detect_dcn_version: parse dmesg for "initialized on DCN X.Y.Z"
# ---------------------------------------------------------------------------
detect_dcn_version() {
	dmesg 2>/dev/null | grep -oE 'initialized on DCN [0-9]+\.[0-9]+\.[0-9]+' | tail -1 | awk '{print $NF}'
}

# ---------------------------------------------------------------------------
# find_reg_files: locate offset + sh_mask files for a given DCN version string.
# Sets globals: OFFSET_FILE, SHMASK_FILE, USE_TXT (1=.txt, 0=.h)
# Preference order: preprocessed .txt files, then raw .h headers.
# ---------------------------------------------------------------------------
find_reg_files() {
	local dcn_ver="$1"
	local file_prefix compact_ver

	# 1. Try preprocessed .txt files with direct version (e.g. 3.2.1 → dcn321_regs.txt)
	compact_ver="${dcn_ver//./}"    # 3.2.1 → 321
	if [ -f "$SCRIPT_DIR/dcn${compact_ver}_regs.txt" ] && \
	   [ -f "$SCRIPT_DIR/dcn${compact_ver}_sh_mask.txt" ]; then
		OFFSET_FILE="$SCRIPT_DIR/dcn${compact_ver}_regs.txt"
		SHMASK_FILE="$SCRIPT_DIR/dcn${compact_ver}_sh_mask.txt"
		USE_TXT=1
		return 0
	fi

	# 2. Try raw .h header with direct version (e.g. 3.2.1 → dcn_3_2_1_offset.h)
	file_prefix="${dcn_ver//./_}"   # 3.2.1 → 3_2_1
	if [ -f "$SCRIPT_DIR/dcn_reg/dcn_${file_prefix}_offset.h" ]; then
		OFFSET_FILE="$SCRIPT_DIR/dcn_reg/dcn_${file_prefix}_offset.h"
		SHMASK_FILE="$SCRIPT_DIR/dcn_reg/dcn_${file_prefix}_sh_mask.h"
		USE_TXT=0
		return 0
	fi

	# 3. Try mapped file prefix from DCN_VERSION_MAP (e.g. "4.0.1" → "4_1_0")
	if [ -n "${DCN_VERSION_MAP[$dcn_ver]+x}" ]; then
		file_prefix="${DCN_VERSION_MAP[$dcn_ver]}"
		# Try .txt with mapped prefix (e.g. 4_1_0 → dcn410_regs.txt)
		compact_ver="${file_prefix//_/}"
		if [ -f "$SCRIPT_DIR/dcn${compact_ver}_regs.txt" ] && \
		   [ -f "$SCRIPT_DIR/dcn${compact_ver}_sh_mask.txt" ]; then
			OFFSET_FILE="$SCRIPT_DIR/dcn${compact_ver}_regs.txt"
			SHMASK_FILE="$SCRIPT_DIR/dcn${compact_ver}_sh_mask.txt"
			USE_TXT=1
			return 0
		fi
		# Try .h with mapped prefix
		if [ -f "$SCRIPT_DIR/dcn_reg/dcn_${file_prefix}_offset.h" ]; then
			OFFSET_FILE="$SCRIPT_DIR/dcn_reg/dcn_${file_prefix}_offset.h"
			SHMASK_FILE="$SCRIPT_DIR/dcn_reg/dcn_${file_prefix}_sh_mask.h"
			USE_TXT=0
			return 0
		fi
	fi

	return 1
}

# ---------------------------------------------------------------------------
# detect_reg_prefix: determine whether offset file uses "reg" or "mm" prefix.
# Sets global: REG_PREFIX
# ---------------------------------------------------------------------------
detect_reg_prefix() {
	if [ "$USE_TXT" -eq 1 ]; then
		if grep -qE '^reg[A-Za-z]' "$OFFSET_FILE"; then
			echo "reg"
		else
			echo "mm"
		fi
	else
		if grep -qE '^#define[[:space:]]+reg[A-Za-z]' "$OFFSET_FILE"; then
			echo "reg"
		else
			echo "mm"
		fi
	fi
}

# ---------------------------------------------------------------------------
# load_registers: source or parse register definitions into bash environment.
# For .txt files: direct source (they are already valid bash variable assignments).
# For .h files:  convert #define lines to variable assignments and source them.
# ---------------------------------------------------------------------------
load_registers() {
	if [ "$USE_TXT" -eq 1 ]; then
		echo "Loading registers from: $OFFSET_FILE"
		source "$OFFSET_FILE"
		source "$SHMASK_FILE"
	else
		echo "Loading registers from: $OFFSET_FILE"
		# Parse offset header: #define (reg|mm)NAME 0xVALUE  →  (reg|mm)NAME=0xVALUE
		source <(grep -E '^#define[[:space:]]+(reg|mm)[A-Za-z0-9_]+[[:space:]]' "$OFFSET_FILE" | \
		         awk '{print $2 "=" $3}')
		# Parse sh_mask header: NAME__FIELDNAME__SHIFT and NAME__FIELDNAME_MASK
		# SHIFT uses double underscore prefix, MASK uses single underscore prefix.
		source <(grep -E '^#define[[:space:]]+[A-Za-z0-9_]+(_MASK|__SHIFT)[[:space:]]' "$SHMASK_FILE" | \
		         awk '{print $2 "=" $3}')
	fi
}

# ---------------------------------------------------------------------------
# get_registers: list register names matching a prefix pattern from the offset file.
# The bare pattern (without reg/mm prefix) is passed in; REG_PREFIX is prepended.
# ---------------------------------------------------------------------------
get_registers() {
	local pattern="${REG_PREFIX}${1}"
	if [ "$USE_TXT" -eq 1 ]; then
		grep -E "^${pattern}" "$OFFSET_FILE" | grep -v "_BASE_IDX=" | cut -d '=' -f 1
	else
		grep -E "^#define[[:space:]]+${pattern}" "$OFFSET_FILE" | \
			grep -v "_BASE_IDX" | awk '{print $2}'
	fi
}

# ---------------------------------------------------------------------------
# reg_read: read one MMIO register and decode its bitfields.
# ---------------------------------------------------------------------------
reg_read() {
	local reg_name=$1
	local base_idx_var="${reg_name}_BASE_IDX"
	local base_idx="${!base_idx_var}"
	local offset="${!reg_name}"

	if [ -z "$offset" ] || [ -z "$base_idx" ]; then
		echo "$reg_name: SKIP (not defined for this DCN version)"
		return
	fi

	echo -en "$reg_name: "
	local value
	value=$(mmio_read32 $(( rbase + 4 * (dcn_base[base_idx] + offset) )))
	echo "$value"

	local reg_basename="${reg_name#${REG_PREFIX}}"  # strip "reg" or "mm" prefix
	local fields=()
	if [ "$USE_TXT" -eq 1 ]; then
		readarray -d '' -t fields < <(grep "${reg_basename}__" "$SHMASK_FILE" | grep "_MASK=" | cut -d '=' -f 1)
	else
		readarray -d '' -t fields < <(grep -E "^#define[[:space:]]+${reg_basename}__[A-Za-z0-9_]+_MASK[[:space:]]" "$SHMASK_FILE" | awk '{print $2}')
	fi

	for field in ${fields[@]}; do
		local base_name="${field%_MASK}"
		local field_name="${base_name#"${reg_basename}"}"
		field_name="${field_name#__}"
		local shift_field="${base_name}__SHIFT"
		local mask_val="${!field}"
		local shift_val="${!shift_field}"
		if [ -n "$mask_val" ] && [ -n "$shift_val" ]; then
			echo "    $field_name: $((( value & ${mask_val%L} ) >> shift_val))"
		fi
	done
}

# ---------------------------------------------------------------------------
# dump_section: discover and dump all registers matching a prefix pattern.
# ---------------------------------------------------------------------------
dump_section() {
	local title="$1"
	local pattern="$2"
	local regs=()
	readarray -t regs < <(get_registers "$pattern")
	if [ ${#regs[@]} -gt 0 ]; then
		echo -e "\n====${title}===="
		for reg in "${regs[@]}"; do
			[ -n "$reg" ] && reg_read "$reg"
		done
	fi
}

# ===========================================================================
# MAIN
# ===========================================================================

# Detect DCN hardware version from dmesg
dcn_version=$(detect_dcn_version)
if [ -z "$dcn_version" ]; then
	echo "Warning: Could not detect DCN version from dmesg."
	echo "Available header files:"
	ls "$SCRIPT_DIR/dcn_reg/"dcn_*_offset.h 2>/dev/null | \
		sed "s|.*dcn_reg/dcn_||;s|_offset\.h||" | tr '_' '.'
	echo -n "Please enter DCN version (e.g., 3.2.1): "
	read -r dcn_version
fi
echo "Detected DCN version: $dcn_version"

# Find appropriate register definition files
OFFSET_FILE=""
SHMASK_FILE=""
USE_TXT=0
if ! find_reg_files "$dcn_version"; then
	echo "Error: No register definition files found for DCN $dcn_version"
	echo "Available header files:"
	ls "$SCRIPT_DIR/dcn_reg/"dcn_*_offset.h 2>/dev/null | \
		sed "s|.*dcn_reg/dcn_||;s|_offset\.h||"
	exit 1
fi
echo "Offset file:  $OFFSET_FILE"
echo "SH mask file: $SHMASK_FILE"

# Detect register name prefix (reg for DCN 3.1.2+, mm for DCN 3.0.x and older)
REG_PREFIX=$(detect_reg_prefix)
echo "Register prefix: ${REG_PREFIX}"

# Load register definitions into bash environment
load_registers

# Discover and dump each register section
for section in "${REG_SECTIONS[@]}"; do
	title="${section%%:*}"
	pattern="${section#*:}"
	dump_section "$title" "$pattern"
done
