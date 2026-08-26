#!/bin/bash
PRODUCT_DIR=/host/product
[ -d "$PRODUCT_DIR" ] || { echo "No product dir"; exit 0; }

mac=$(cat $PRODUCT_DIR/mac 2>/dev/null)
model=$(cat $PRODUCT_DIR/model_name 2>/dev/null)
hw=$(cat $PRODUCT_DIR/hw_ver 2>/dev/null)

[ -n "$mac" ] || { echo "No product mac"; exit 0; }

mac_fmt=$(echo "$mac" | sed 's/../&:/g; s/:$//')

sonic-db-cli CONFIG_DB HSET 'DEVICE_METADATA|localhost' serial_number "$mac_fmt"
sonic-db-cli CONFIG_DB HSET 'DEVICE_METADATA|localhost' hardware_rev "$hw"
sonic-db-cli CONFIG_DB HSET 'DEVICE_METADATA|localhost' model_name "$model"
sonic-db-cli CONFIG_DB HSET 'UCENTRAL|global' SN "$mac"
config save -y
