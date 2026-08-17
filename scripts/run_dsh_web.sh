#!/data/data/com.termux/files/usr/bin/bash
export PATH=/data/data/com.termux/files/usr/glibc/opt/bin:/data/data/com.termux/files/usr/glibc/bin:/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/applets
exec grun /data/data/com.termux/files/usr/glibc/opt/node-v24.19.0-linux-arm64/bin/node --expose-internals /data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/lib/bin.js web
