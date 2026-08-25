#!/bin/sh

# Copy product info (mac, model_name, hw_ver) from the PRODUCT partition
# to /host/product/ during SONiC boot.
# If /host/product/ already contains all three files, do nothing.

REQUIRED_FILES="mac model_name hw_ver"
PART_LABEL="PRODUCT"
HOST_DIR="/host/product"

mkdir -p "$HOST_DIR"

all_present=1
for f in $REQUIRED_FILES; do
    if [ ! -f "${HOST_DIR}/$f" ]; then
        all_present=0
        break
    fi
done

if [ "$all_present" -eq 1 ]; then
    echo "Product files already present in ${HOST_DIR}, skipping mount/copy"
    exit 0
fi

echo "Product files missing in ${HOST_DIR}, mounting ${PART_LABEL} partition..."

tmpmnt=$(mktemp -d)

if ! mount -o ro /dev/disk/by-label/${PART_LABEL} "$tmpmnt" >/dev/null 2>&1 && \
   ! mount -o ro /dev/disk/by-partlabel/${PART_LABEL} "$tmpmnt" >/dev/null 2>&1; then
    echo "ERROR: Cannot mount ${PART_LABEL} partition"
    rm -rf "$tmpmnt"
    exit 1
fi

missing=0
for f in $REQUIRED_FILES; do
    if [ ! -f "${tmpmnt}/$f" ]; then
        echo "ERROR: ${f} not found in ${PART_LABEL} partition"
        missing=1
    fi
done

if [ "$missing" -ne 0 ]; then
    umount "$tmpmnt" || true
    rm -rf "$tmpmnt"
    exit 1
fi

for f in $REQUIRED_FILES; do
    cp -v "${tmpmnt}/$f" "$HOST_DIR/"
done

chmod 700 "$HOST_DIR"

umount "$tmpmnt" || true
rm -rf "$tmpmnt"

echo "Product files copied to ${HOST_DIR}:"
ls -l "$HOST_DIR"
exit 0
