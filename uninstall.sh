#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 TheKimi7
# Mounts are not persistent, so only on-disk state needs clearing.
rm -rf /data/adb/TrustMeDarling
rm -rf /dev/.tmd_store 2>/dev/null
