#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# deepseek-harness-termux — 在 Termux (Android aarch64) 上一键安装 DeepSeek Harness
# 前置要求: Termux aarch64; 有 root 推荐 (dns53 转发器更稳定), 无 root 也可用 (dns-bootstrap 实测公共 DNS)
#
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/deepseek-harness-termux/main/install.sh)
#   bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/deepseek-harness-termux/main/install.sh) --uninstall
#
# 原理:
#   dsh 官方只发布 linux 平台包(process.platform === "linux"), 在 Android Bionic 上
#   无法运行(node-pty/koffi 等原生模块对 Bionic 不可用)。本脚本走 glibc 兼容层:
#   Termux glibc 运行时 + grun 启动器 + nodejs.org 官方 linux-arm64 tarball,
#   koffi/sharp 用 npm 自动选择的 glibc 预编译包, 仅 node-pty 需 clang-glibc 编译。
#
# 固定版本策略: 官方无自动更新, 预览版变化大, 脚本固定已知可用的版本组合,
# 重跑本脚本 = 重装 + 重打补丁(幂等)。
# ============================================================
set -euo pipefail

# ---------- 常量 ----------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
GLIBC_PREFIX="$PREFIX/glibc"
NODE_VER="v24.19.0"
NODE_DIR="$GLIBC_PREFIX/opt/node-$NODE_VER-linux-arm64"
WRAPPER_DIR="$GLIBC_PREFIX/opt/bin"
# 不固定版本: 默认拉取 latest (DSH_VER 环境变量可覆盖, 如 DSH_VER=0.1.0-rc.7 ./install.sh)
DSH_VER="${DSH_VER:-}"
PROFILE_DIR="$HOME_DIR/.dsh/profiles/web"
PATCH_DIR="$(dirname "$(readlink -f "$0")")/patches"
# 若 patches 目录不存在 (如通过 bash <(curl ...) 运行), 从 GitHub 下载
if [ ! -d "$PATCH_DIR" ]; then
    _tmp_patches="$(mktemp -d)"
    for _p in 02-session-persistence-link-rename.patch 03-bash-persistent-rename.patch; do
        curl -fsSL "https://raw.githubusercontent.com/xkxxs/deepseek-harness-termux/main/patches/$_p" -o "$_tmp_patches/$_p" 2>/dev/null || true
    done
    PATCH_DIR="$_tmp_patches"
fi
RUNNER_URL="https://raw.githubusercontent.com/xkxxs/deepseek-harness-termux/main/install.sh"
DNS53_JS="$HOME_DIR/.local/bin/dns53.js"

# ---------- 颜色 ----------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[1;36m'; NC='\033[0m'
ok()   { echo -e "${GRN}✓${NC} $*"; }
info() { echo -e "${BLU}▸${NC} $*"; }
warn() { echo -e "${YEL}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# ---------- 环境检查 ----------
check_environment() {
    if [ "$(uname -o 2>/dev/null || true)" != "Android" ] && [ ! -x "$PREFIX/bin/pkg" ]; then
        fail "此脚本仅支持 Termux (Android)。"
    fi
    [ "$(uname -m)" = "aarch64" ] || fail "仅支持 aarch64 (ARM64) 架构, 当前: $(uname -m)"
    command -v curl >/dev/null || { info "安装 curl…"; pkg install -y curl; }
    command -v sudo >/dev/null || warn "未检测到 sudo(无 root 环境), dns53 需 root 绑定 53 端口"
    info "环境检查通过 (Termux aarch64)"
}

# ---------- 镜像源适配 ----------
# 新版 termux-tools (pkg ≥ 2.0 / tools ≥ 1.45) 自带 select_mirror:
# pkg update/upgrade 时会自动测速选源并重写 sources.list (含 root/x11),
# 无需自建测速 (自建反而会被 pkg 覆盖)。仅旧版 pkg 走下面的脚本测速。
fix_mirror() {
    # termux-glibc 仓库 (glibc 运行时/工具链来源; 新设备无此源)
    local glibc_list="$PREFIX/etc/apt/sources.list.d/glibc.list"
    if [ ! -f "$glibc_list" ]; then
        info "添加 termux-glibc 仓库…"
        mkdir -p "$PREFIX/etc/apt/sources.list.d"
        printf '%s\n' "# The glibc termux repository, with cloudflare cache" \
            "deb https://packages-cf.termux.dev/apt/termux-glibc/ glibc stable" > "$glibc_list"
    else
        ok "termux-glibc 仓库已存在"
    fi

    # 新版 termux-tools (pkg ≥ 2.0 / tools ≥ 1.45) 自带 select_mirror:
    # pkg update/upgrade 时会自动测速选源并重写 sources.list (含 root/x11),
    # 无需自建测速 (自建反而会被 pkg 覆盖)。仅旧版 pkg 走下面的脚本测速。
    if grep -q "select_mirror" "$PREFIX/bin/pkg" 2>/dev/null; then
        ok "pkg 自带镜像自动选择 (select_mirror), 跳过自建测速"
        DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1 \
            || { sleep 3; DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1; } \
            && ok "apt update 成功" || warn "apt update 失败, 请手动检查: pkg change-repo"
        return
    fi
    local sources_file="$PREFIX/etc/apt/sources.list"
    [ -f "$sources_file" ] || { warn "未找到 apt 源文件, 跳过镜像适配"; return; }

    # 候选源: (显示名 URL前缀)
    local candidates=(
        "packages.termux.dev"
        "mirrors.aliyun.com/termux"
        "mirrors.tuna.tsinghua.edu.cn/termux"
        "mirrors.ustc.edu.cn/termux"
        "mirrors.cloud.tencent.com/termux"
        "mirrors.huaweicloud.com/termux"
    )

    # 逐源测速 (2 次取最快, 全部失败得 99)
    local best="" best_t=99 c t1 t2 t
    for c in "${candidates[@]}"; do
        t1=$(curl -s -o /dev/null -w '%{time_total}' --connect-timeout 3 --max-time 8 \
            "https://$c/apt/termux-main/dists/stable/Release" 2>/dev/null || echo 99)
        t2=$(curl -s -o /dev/null -w '%{time_total}' --connect-timeout 3 --max-time 8 \
            "https://$c/apt/termux-main/dists/stable/Release" 2>/dev/null || echo 99)
        t=$(printf '%s\n%s\n' "$t1" "$t2" | sort -n | head -1)
        info "测速 $c: ${t}s"
        if awk "BEGIN{exit !($t < $best_t)}"; then
            best="$c"; best_t="$t"
        fi
    done

    if [ -z "$best" ]; then
        warn "全部源测速失败, 保持当前配置 (可手动: pkg change-repo)"
        return
    fi
    ok "最快源: $best (${best_t}s)"

    # 当前已是最快 → 不动
    if grep -q "$best" "$sources_file" 2>/dev/null; then
        ok "当前源已是最快, 无需切换"
    else
        warn "切换源: $(grep -oE 'https://[^/]+' "$sources_file" | head -1) → $best"
        cp "$sources_file" "$sources_file.bak.$(date +%s)"
        echo "deb https://$best/apt/termux-main stable main" > "$sources_file"
        info "已切换 (原配置已备份: sources.list.bak.*)"
    fi

    # termux-glibc 仓库 (glibc 运行时/工具链来源; 新设备无此源)
    local glibc_list="$PREFIX/etc/apt/sources.list.d/glibc.list"
    if [ ! -f "$glibc_list" ]; then
        info "添加 termux-glibc 仓库…"
        mkdir -p "$PREFIX/etc/apt/sources.list.d"
        printf '%s\n' "# The glibc termux repository, with cloudflare cache" \
            "deb https://packages-cf.termux.dev/apt/termux-glibc/ glibc stable" > "$glibc_list"
    else
        ok "termux-glibc 仓库已存在"
    fi

    DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1 \
        || { sleep 3; DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1; } \
        && ok "apt update 成功" || warn "apt update 失败, 请手动检查: pkg change-repo"
}

# ---------- 全量升级 ----------
# 换好源后把所有软件包升到最新 (幂等: 已最新则跳过)
# ⚠️ 不要重定向输出到 /dev/null: 全新 Termux 首次升级要下载几百 MB,
#    无输出会看起来像"卡死" (实际在下载), 用户会误以为卡住而 Ctrl+C。
#    DEBIAN_FRONTEND=noninteractive + force-conf* 避免 dpkg conffile 提问卡住。
upgrade_packages() {
    info "更新软件包索引并升级全部软件包…"
    info "提示: 全新 Termux 首次升级可能耗时数分钟 (下载量大), 请耐心等待, 不要打断"
    if DEBIAN_FRONTEND=noninteractive pkg upgrade -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"; then
        ok "软件包已是最新"
    else
        warn "pkg upgrade 未完全成功, 请稍后重试 (pkg upgrade -y)"
    fi
}

# ---------- 证书修复 ----------
fix_cert() {
    local cert_file="$PREFIX/etc/tls/cert.pem"
    if [ ! -f "$cert_file" ]; then
        warn "未找到 CA 证书 ($cert_file), 尝试安装 ca-certificates…"
        pkg install -y ca-certificates || warn "ca-certificates 安装失败"
    else
        ok "CA 证书就绪"
    fi
}

# ---------- 依赖 ----------
install_dependencies() {
    info "安装 glibc 运行时与编译工具链…"
    export DEBIAN_FRONTEND=noninteractive
    pkg install -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" \
        glibc glibc-runner clang-glibc make-glibc python-glibc cmake-glibc pkgconf-glibc lld-glibc
    ok "依赖安装完成 (glibc-runner 提供 grun)"
}

# ---------- DNS 修复 ----------
# Android 无 /etc/resolv.conf; glibc 进程解析失败。复用 dns53 转发器
# (opencode 等 CLI 的附属组件, 若已存在则跳过), 并将 glibc 的 resolv.conf
# 指向 127.0.0.1。注意: dns-bootstrap.js 重写 /usr/etc/resolv.conf 后需重跑本函数。
#
# 无 root 时: dns53 无法绑定 53 端口, 改用 dns-bootstrap 实测公共 DNS
# 并直接写入 resolv.conf (glibc 直接读, 不需要 proot)。
fix_dns() {
    local RESOLV="$PREFIX/etc/resolv.conf"
    local DNSBOOT="$HOME_DIR/.local/bin/dns-bootstrap.js"
    local has_root=false
    command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && has_root=true

    if $has_root; then
        info "检查 DNS 转发器 (dns53)…"
        if [ -f "$DNS53_JS" ]; then
            ok "dns53 已存在 ($DNS53_JS), 请确认其正在运行 (常驻/开机自启由安装它的 CLI 负责)"
        else
            warn "未找到 dns53.js —— 请先安装 opencode 或其他附带 dns53 的 CLI, 或手动部署转发器"
            warn "（glibc 程序在 Android 上无法直接解析 DNS, 这是硬依赖; 端口 53 需 root）"
        fi
        if [ -f "$RESOLV" ] && grep -q "127.0.0.1" "$RESOLV"; then
            ok "glibc resolv.conf 已指向 127.0.0.1"
        else
            [ -f "$RESOLV" ] && cp "$RESOLV" "$RESOLV.bak.$(date +%s)"
            printf "nameserver 127.0.0.1\n" > "$RESOLV"
            warn "已写入 $RESOLV -> 127.0.0.1 (请确认 dns53 正在运行; 旧配置备份为 .bak.*)"
        fi
    else
        info "未检测到 root, 使用 dns-bootstrap 实测公共 DNS"
        mkdir -p "$HOME_DIR/.local/bin"
        # 生成 dns-bootstrap.js (复用 codex-termux 方案, 精简为单次模式)
        if [ ! -f "$DNSBOOT" ]; then
            cat > "$DNSBOOT" << 'DNSBOOT_EOF'
#!/usr/bin/env node
// dns-bootstrap — 无 root 环境下的 DNS 自动校验器
// 实测候选 DNS 应答质量 (SERVFAIL/空/被过滤全判废), 只写入真实可用的 resolv.conf
const dgram = require('dgram');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const PUBLIC_DNS = ['223.5.5.5', '119.29.29.29', '114.114.114.114', '2400:3200::1', '2402:4e00::'];
const PROBE_DOMAINS = ['api.deepseek.com', 'www.baidu.com'];
const TIMEOUT_MS = 2500;
const RESOLV = process.env.DNS_RESOLV_CONF || `${process.env.PREFIX || '/data/data/com.termux/files/usr'}/etc/resolv.conf`;
function discoverPhoneDns() {
  const servers = [];
  try {
    const props = execFileSync('/system/bin/getprop', [], { encoding: 'utf8', timeout: 3000 });
    for (const line of props.split('\n')) {
      const m = line.match(/^\[net\.\S+\.dns\d+\]:\s*\[([0-9.]+)\]/);
      if (m) servers.push(m[1]);
    }
  } catch (_) {}
  if (servers.length === 0) {
    try {
      const out = execFileSync('/system/bin/dumpsys', ['connectivity'], { encoding: 'utf8', timeout: 5000 });
      const blocks = out.split('NetworkAgentInfo{').slice(1);
      const scored = [];
      for (const b of blocks) {
        const dm = b.match(/DnsAddresses:\s*\[([^\]]*)\]/);
        if (!dm) continue;
        const ips = [];
        let hit;
        const re = /(\d{1,3}(?:\.\d{1,3}){3})/g;
        while ((hit = re.exec(dm[1]))) ips.push(hit[1]);
        if (!ips.length) continue;
        const score = (b.includes('TRANSPORT_PRIMARY') ? 0 : 1) + (b.includes('INTERNET') && b.includes('VALIDATED') ? 0 : 2);
        scored.push([score, ips]);
      }
      scored.sort((a, b) => a[0] - b[0]);
      for (const [, ips] of scored) servers.push(...ips);
    } catch (_) {}
  }
  return [...new Set(servers)].filter((ip) => ip !== '127.0.0.1' && ip !== '0.0.0.0');
}
function queryDNS(server, host, timeout = TIMEOUT_MS) {
  return new Promise((resolve) => {
    const sock = dgram.createSocket(server.includes(':') ? 'udp6' : 'udp4');
    const id = Buffer.from([Math.floor(Math.random() * 256), Math.floor(Math.random() * 256)]);
    const q = Buffer.alloc(12 + 2 + host.length + 4);
    id.copy(q, 0);
    q[5] = 1;
    let off = 12;
    for (const part of host.split('.')) { q[off++] = part.length; q.write(part, off); off += part.length; }
    q[off++] = 0; q[off++] = 0; q[off++] = 1; q[off++] = 0; q[off++] = 1;
    const t0 = Date.now();
    const timer = setTimeout(() => { try { sock.close(); } catch (_) {} resolve({ ok: false, reason: 'timeout', ms: Date.now() - t0 }); }, timeout);
    sock.on('message', (resp) => {
      clearTimeout(timer);
      resolve({ ok: !badAnswer(resp), ms: Date.now() - t0, raw: resp });
      try { sock.close(); } catch (_) {}
    });
    sock.on('error', () => { clearTimeout(timer); try { sock.close(); } catch (_) {} resolve({ ok: false, reason: 'error', ms: Date.now() - t0 }); });
    sock.send(q, 53, server);
  });
}
function badAnswer(resp) {
  if (resp.length < 12) return true;
  const rcode = resp.readUInt16BE(2) & 0x0f;
  if (rcode === 2) return true;
  if (rcode !== 0 && rcode !== 3) return true;
  const qd = resp.readUInt16BE(4);
  const an = resp.readUInt16BE(6);
  if (an === 0) return rcode === 0;
  let off = 12;
  const skipName = (p) => {
    let hops = 0;
    while (off < p.length && p[off] !== 0) {
      if ((p[off] & 0xc0) === 0xc0) { off += 2; return; }
      off += p[off] + 1;
      if (++hops > 32) break;
    }
    off++;
  };
  for (let i = 0; i < qd && off < resp.length; i++) { skipName(resp); off += 4; }
  for (let i = 0; i < an && off + 10 <= resp.length; i++) {
    skipName(resp);
    const type = resp.readUInt16BE(off);
    const len = resp.readUInt16BE(off + 8);
    off += 10 + len;
    if (type === 1 || type === 28) return false;
  }
  return true;
}
async function probe(server) {
  for (const host of PROBE_DOMAINS) {
    const r = await queryDNS(server, host);
    if (r.ok) return { ip: server, ms: r.ms, host, ok: true };
  }
  return { ip: server, ms: Infinity, ok: false };
}
async function main() {
  const phone = discoverPhoneDns();
  const candidates = [...phone, ...PUBLIC_DNS];
  const uniq = [];
  for (const ip of candidates) if (!uniq.includes(ip)) uniq.push(ip);
  if (uniq.length === 0) uniq.push(...PUBLIC_DNS);
  const results = await Promise.all(uniq.map((ip) => probe(ip)));
  const good = results.filter((r) => r.ok).sort((a, b) => a.ms - b.ms);
  const top = good.slice(0, 3);
  const body = top.length
    ? top.map((r) => `nameserver ${r.ip}`).join('\n') + '\n'
    : 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 2400:3200::1\n';
  fs.mkdirSync(path.dirname(RESOLV), { recursive: true });
  fs.writeFileSync(RESOLV, `# auto-written by dns-bootstrap.js @ ${new Date().toISOString()}\n${body}`);
  console.log(`resolv.conf: ${top.map((r) => `${r.ip} (${r.ms}ms)`).join(', ') || 'fallback public DNS'}`);
}
main();
DNSBOOT_EOF
            chmod +x "$DNSBOOT"
            info "dns-bootstrap.js 已生成: $DNSBOOT"
        fi
        # 立即实测一次
        node "$DNSBOOT" || warn "DNS 实测失败, 已回退公共 DNS"
        if [ -f "$RESOLV" ]; then
            ok "glibc resolv.conf 已更新 (实测公共 DNS, 无需 root)"
        fi
    fi
}

# ---------- 官方 glibc Node.js ----------
install_node() {
    if [ -x "$NODE_DIR/bin/node" ]; then
        local ver
        ver=$(grun "$NODE_DIR/bin/node" --version 2>/dev/null || echo '?')
        ok "glibc node 已存在 ($ver), 跳过下载"
        return
    fi
    mkdir -p "$GLIBC_PREFIX/opt"
    local url="https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-linux-arm64.tar.xz"
    local mirror="https://npmmirror.com/mirrors/node/$NODE_VER/node-$NODE_VER-linux-arm64.tar.xz"
    local tarball="$GLIBC_PREFIX/opt/node-$NODE_VER-linux-arm64.tar.xz"
    info "下载官方 glibc Node.js $NODE_VER (linux-arm64)…"
    if ! curl -fsSL --max-time 300 -o "$tarball" "$url"; then
        warn "官方源失败, 改用 npmmirror 镜像…"
        curl -fsSL --max-time 300 -o "$tarball" "$mirror" || fail "Node.js 下载失败"
    fi
    tar xf "$tarball" -C "$GLIBC_PREFIX/opt"
    rm -f "$tarball"
    ok "Node.js $NODE_VER 解压到 $NODE_DIR"
}

# ---------- wrapper (node/pnpm) ----------
write_wrappers() {
    mkdir -p "$WRAPPER_DIR"
    cat > "$WRAPPER_DIR/node" <<EOF
#!/$PREFIX/bin/bash
exec grun $NODE_DIR/bin/node "\$@"
EOF
    cat > "$WRAPPER_DIR/pnpm" <<EOF
#!/$PREFIX/bin/bash
exec grun $NODE_DIR/bin/node $PREFIX/lib/node_modules/pnpm/bin/pnpm.cjs "\$@"
EOF
    chmod +x "$WRAPPER_DIR/node" "$WRAPPER_DIR/pnpm"
    ln -sf "$WRAPPER_DIR/node" "$WRAPPER_DIR/npm"
    ok "wrapper 就绪: $WRAPPER_DIR/{node,pnpm,npm}"
}

# ---------- 安装 dsh ----------
install_dsh() {
    local npm="$NODE_DIR/bin/node $NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
    local pkg="@deepseek-ai/dsh${DSH_VER:+@$DSH_VER}"
    info "npm 安装 $pkg (--ignore-scripts)…"
    # shellcheck disable=SC2086
    PATH="$WRAPPER_DIR:$GLIBC_PREFIX/bin:$PATH" grun $npm install -g --ignore-scripts "$pkg"
    ok "dsh 已安装 ($pkg)"
    if [ ! -f "$PREFIX/lib/node_modules/pnpm/bin/pnpm.cjs" ]; then
        info "npm 安装 pnpm (dsh plugin 管理器依赖)…"
        # shellcheck disable=SC2086
        PATH="$WRAPPER_DIR:$GLIBC_PREFIX/bin:$PATH" grun $npm install -g pnpm || \
            warn "pnpm 安装失败 — profile 插件管理将不可用 (可手动: npm i -g pnpm)"
    fi
}

# ---------- profile 初始化 + 插件 ----------
init_profile() {
    local bin="$PREFIX/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
    if [ ! -d "$PROFILE_DIR/node_modules" ]; then
        info "初始化 web profile…"
        PATH="$WRAPPER_DIR:$GLIBC_PREFIX/bin:$PATH" grun "$NODE_DIR/bin/node" --expose-internals "$bin" --profile web --dump-config >/dev/null 2>&1 || \
            fail "profile 初始化失败"
        ok "web profile 已初始化"
    fi
    info "安装 dsh-web-mobile 插件 (竖屏 UI)…"
    PATH="$WRAPPER_DIR:$GLIBC_PREFIX/bin:$PATH" grun "$NODE_DIR/bin/node" --expose-internals "$bin" plugin --profile web add github:mexiaosqwq/dsh-web-mobile || \
        warn "dsh-web-mobile 插件安装失败 (可忽略, 不影响核心功能)"
    # 去重: 插件可能同时注册 @dsh-external/dsh-mobile-nav 和 dsh-web-mobile, 导致 locale 冲突
    local pkg_json="$PROFILE_DIR/package.json"
    if [ -f "$pkg_json" ] && grep -q '@dsh-external/dsh-mobile-nav' "$pkg_json"; then
        grun "$NODE_DIR/bin/node" -e "
const fs = require('fs');
const p = JSON.parse(fs.readFileSync('$pkg_json','utf8'));
delete p.dependencies['@dsh-external/dsh-mobile-nav'];
p.dsh.profile.bundles = (p.dsh.profile.bundles||[]).filter(b => b !== '@dsh-external/dsh-mobile-nav');
fs.writeFileSync('$pkg_json', JSON.stringify(p,null,2));
" 2>/dev/null && ok "去重: 移除 @dsh-external/dsh-mobile-nav" || warn "去重失败, 可能需手动修复"
        PATH="$WRAPPER_DIR:$GLIBC_PREFIX/bin:$PATH" grun "$NODE_DIR/bin/node" "$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js" install -g pnpm >/dev/null 2>&1 || true
        ( cd "$PROFILE_DIR" && PATH="$WRAPPER_DIR:$GLIBC_PREFIX/bin:$PATH" grun "$NODE_DIR/bin/node" "$NODE_DIR/lib/node_modules/pnpm/bin/pnpm.cjs" install >/dev/null 2>&1 ) || true
    fi
    ok "profile 插件就绪"
}

# ---------- 补丁 ----------
# 注意: 补丁针对当前源码结构, 新版本可能失效。失效时仅警告不中断
# (会话持久化/持久终端可能不可用, 但核心功能不受影响; 等官方正式版/musl)。
apply_patches() {
    local profiles_nm="$HOME_DIR/.dsh/profiles/node_modules/@deepseek-ai"
    info "打补丁…"
    # 1) 会话持久化: link(2) 被 Android sepolicy 拦截, 回退 rename
    if grep -q 'error?.code === "EACCES"' "$profiles_nm/dsh-session-persistence-jsonl/lib/index.js" 2>/dev/null; then
        ok "补丁 02 (会话持久化 link->rename) 已生效, 跳过"
    else
        ( cd "$profiles_nm/dsh-session-persistence-jsonl" && \
          patch -p1 < "$PATCH_DIR/02-session-persistence-link-rename.patch" ) || \
          warn "补丁 02 失败 — 版本漂移? (会话持久化可能失效, 重启后历史可能丢失)"
        if grep -q 'error?.code === "EACCES"' "$profiles_nm/dsh-session-persistence-jsonl/lib/index.js" 2>/dev/null; then
            ok "补丁 02 (会话持久化 link->rename)"
        else
            warn "补丁 02 未生效 — 需等待适配新版本"
        fi
    fi
    # 2) 持久终端工具改名: 与普通 bash 同名冲突
    if grep -q '"bash_persistent"' "$profiles_nm/dsh-tool-bash-persistent/lib/index.js" 2>/dev/null; then
        ok "补丁 03 (bash_persistent 改名) 已生效, 跳过"
    else
        ( cd "$profiles_nm/dsh-tool-bash-persistent" && \
          patch -p1 < "$PATCH_DIR/03-bash-persistent-rename.patch" ) || \
          warn "补丁 03 失败 — 版本漂移? (持久终端工具可能不可用)"
        if grep -q '"bash_persistent"' "$profiles_nm/dsh-tool-bash-persistent/lib/index.js" 2>/dev/null; then
            ok "补丁 03 (bash_persistent 改名)"
        else
            warn "补丁 03 未生效 — 需等待适配新版本"
        fi
    fi
}

# ---------- profile 配置文件 (terminals 服务 + 权限) ----------
write_profile_files() {
    mkdir -p "$PROFILE_DIR/plugins"
    cat > "$PROFILE_DIR/plugins/terminals.js" <<'EOF'
import { TerminalSessionService } from "@deepseek-ai/dsh-terminal";

export const name = "terminals";
export const inject = ["subprocess"];

export function apply(ctx) {
	new TerminalSessionService(ctx);
}
EOF
    if [ ! -s "$PROFILE_DIR/cordis.patch.yml" ] || [ "$(cat "$PROFILE_DIR/cordis.patch.yml")" = "[]" ]; then
        cat > "$PROFILE_DIR/cordis.patch.yml" <<'EOF'
- insert:
    - id: terminals
      name: ./plugins/terminals.js

    - id: terminal-bash
      name: '@deepseek-ai/dsh-terminal-bash'
      config:
        shellPath: /data/data/com.termux/files/usr/bin/bash

    - id: tool-bash-persistent
      name: '@deepseek-ai/dsh-tool-bash-persistent'
EOF
    else
        warn "cordis.patch.yml 非空, 跳过覆盖 (如需持久终端请手动合并)"
    fi
    ok "profile 配置文件就绪"
}

# ---------- 启动脚本 ----------
write_launcher() {
    mkdir -p "$HOME_DIR/.local/bin"
    cat > "$HOME_DIR/.local/bin/dsh-web" <<EOF
#!$PREFIX/bin/bash
unset LD_PRELOAD
export PATH=$WRAPPER_DIR:$GLIBC_PREFIX/bin:$PREFIX/bin:$PREFIX/bin/applets
exec grun $NODE_DIR/bin/node --expose-internals $PREFIX/lib/node_modules/@deepseek-ai/dsh/lib/bin.js web --no-open
EOF
    cat > "$HOME_DIR/.local/bin/dsh" <<'DSH_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# dsh — DeepSeek Harness 统一入口
#   dsh           前台启动 web
#   dsh web       后台常驻启动
#   dsh stop      停止 web 服务
#   dsh update    手动更新到最新版
#
# 启动前自动检查最新版本, 非最新则自动更新再启动
# (可用 DSH_NO_AUTO_UPDATE=1 跳过检查)
# ============================================================
set -uo pipefail

WEB="$HOME/.local/bin/dsh-web"
LOG="$HOME/.dsh/web.log"
URL="http://127.0.0.1:3080"
DSH_PKG="@deepseek-ai/dsh"
VERSION_FILE="$HOME/.dsh/version.json"
GLIBC_PREFIX="/data/data/com.termux/files/usr/glibc"
NODE_DIR="$GLIBC_PREFIX/opt/node-v24.19.0-linux-arm64"
NPM="$NODE_DIR/bin/node $NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
GRUN_PREFIX="/data/data/com.termux/files/usr/glibc/opt/bin"

current_version() {
    PATH="$GRUN_PREFIX:$GLIBC_PREFIX/bin:$PATH" grun "$NODE_DIR/bin/node" \
        "$PREFIX/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>/dev/null | head -1 || true
}

latest_version() {
    PATH="$GRUN_PREFIX:$GLIBC_PREFIX/bin:$PATH" grun $NPM view "$DSH_PKG" version \
        --fetch-timeout=10000 --fetch-retries=0 2>/dev/null || true
}

version_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

pin_version() {
    local v
    v="$(current_version)"
    mkdir -p "$(dirname "$VERSION_FILE")"
    cat > "$VERSION_FILE" <<EOF
{"latest_version":"$v","last_checked_at":"$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)","dismissed_version":"$v"}
EOF
}

do_update() {
    echo "→ 更新 $DSH_PKG…"
    PATH="$GRUN_PREFIX:$GLIBC_PREFIX/bin:$PATH" grun $NPM install -g --ignore-scripts "$DSH_PKG@latest" >/dev/null 2>&1 || return 1
    pin_version
    echo "✓ 已更新: $(current_version)"
}

auto_update() {
    [ "${DSH_NO_AUTO_UPDATE:-0}" = "1" ] && return 0
    command -v grun >/dev/null 2>&1 || return 0
    local LATEST CURRENT
    LATEST="$(latest_version)"
    [ -z "$LATEST" ] && return 0
    CURRENT="$(current_version)"
    if [ -z "$CURRENT" ] || ! version_ge "$CURRENT" "$LATEST"; then
        echo "→ 检测到新版本 v${LATEST} (当前 ${CURRENT:-未知}), 自动更新…"
        if do_update; then
            echo "→ 更新完毕, 继续启动…"
        else
            echo "!! 自动更新失败, 继续使用现有版本" >&2
        fi
    fi
    return 0
}

case "${1:-}" in
    update|upgrade|--update|-u)
        do_update || { echo "!! 更新失败" >&2; exit 1; }
        ;;
    web)
        auto_update
        mkdir -p "$HOME/.dsh"
        : > "$LOG"
        setsid nohup "$WEB" > "$LOG" 2>&1 < /dev/null &
        TOKEN_URL=""
        for i in $(seq 1 30); do
            TOKEN_URL=$(grep -oP 'http://127\.0\.0\.1:3080/\?token=[^ ]+' "$LOG" 2>/dev/null | head -1 || true)
            [ -n "$TOKEN_URL" ] && break
            sleep 0.5
        done
        if [ -n "$TOKEN_URL" ]; then
            echo "dsh web 已启动: $TOKEN_URL"
        else
            echo "dsh web 后台启动中: $URL (日志: $LOG)"
        fi
        ;;
    stop)
        if pkill -f "[b]in.js web"; then
            echo "dsh web 已停止"
        else
            echo "dsh web 未在运行"
        fi
        ;;
    "")
        auto_update
        exec "$WEB"
        ;;
    *)
        echo "用法: dsh | dsh web | dsh stop | dsh update"
        exit 1
        ;;
esac
DSH_EOF
    chmod +x "$HOME_DIR/.local/bin/dsh-web" "$HOME_DIR/.local/bin/dsh"
    ok "启动器: ~/.local/bin/dsh (前台) / dsh web (常驻) / dsh stop (停止)"
}

# ---------- 验证 ----------
verify() {
    PATH="$WRAPPER_DIR:$GLIBC_PREFIX/bin:$PATH" grun "$NODE_DIR/bin/node" "$PREFIX/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>/dev/null || fail "dsh --version 失败"
    ok "安装完成。启动: dsh | dsh web | dsh stop"
    warn "升级: dsh update (或重跑本脚本, 幂等); 启动时自动检查新版"
}

# ---------- 卸载 ----------
uninstall() {
    info "卸载 dsh (保留 dns53 与 profile 数据)…"
    local npm="$NODE_DIR/bin/node $NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
    PATH="$WRAPPER_DIR:$GLIBC_PREFIX/bin:$PATH" grun $npm uninstall -g @deepseek-ai/dsh 2>/dev/null || true
    rm -f "$HOME_DIR/.local/bin/dsh-web"
    rm -rf "$GLIBC_PREFIX/opt/node-$NODE_VER-linux-arm64" "$WRAPPER_DIR"
    rm -f "$PREFIX/etc/resolv.conf.bak.dsh"
    ok "已卸载。profile 数据保留在 ~/.dsh/ (如需彻底删除: rm -rf ~/.dsh)"
    ok "注意: glibc 运行时/工具链未删除 (其他项目可能共用); 需要时: pkg uninstall glibc glibc-runner clang-glibc …"
}

# ---------- main ----------
main() {
    [ "${1:-}" = "--uninstall" ] && { uninstall; exit 0; }
    check_environment
    fix_mirror
    upgrade_packages
    fix_cert
    fix_dns
    install_dependencies
    unset LD_PRELOAD
    install_node
    write_wrappers
    install_dsh
    init_profile
    apply_patches
    write_profile_files
    write_launcher
    verify
    ok "提示: 沙箱不可用(Android 无 bwrap/landlock), 首次使用请在 web UI 权限选择器切 danger-full-access"
}

main "$@"