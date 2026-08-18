# DeepSeek Harness on Termux — glibc 路线实施方案与过程记录

> 2026-08-17 · OPPO/OnePlus · Termux (Android, aarch64)
> 目标:在 Termux 上运行官方 `@deepseek-ai/dsh`(DeepSeek Harness 0.1.0-rc.7),不做源码级 Android 适配,走 glibc 兼容层路线。

## 0. 一键安装(移植到新设备)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/deepseek-harness-termux/main/install.sh)
```

- 幂等:重跑 = 升级/修复;`--uninstall` 卸载(保留 dns53 与 ~/.dsh 数据)
- 前置:Termux + aarch64;dns53 转发器(opencode 等 CLI 的附属组件,脚本检测到即跳过,不会重复安装)
- 固定版本组合:node v24.19.0 + dsh 0.1.0-rc.7;官方无自动更新,升级 = 手动重跑脚本
- 安装后,在终端使用(`http://127.0.0.1:3080` 访问 web UI;首次使用请在 UI 权限选择器切 danger-full-access):

```bash
# 前台启动(占用终端, Ctrl+C 停止)
dsh

# 后台常驻(脱离终端, 日志 ~/.dsh/web.log)
dsh web

# 停止服务
dsh stop
```
- 结构:install.sh(主脚本)+ patches/02,03(补丁)+ scripts/run_dsh_web.sh(旧启动脚本,已被 install.sh 生成的 ~/.local/bin/dsh 与 dsh-web 取代)

---

## 1. 方案背景与选型

### 1.1 两条路线的对比

| 维度 | A. 社区补丁路线 (Vengisk/deepseek-harness-termux) | B. glibc 兼容层路线(本项目,已实施) |
|---|---|---|
| 原理 | 对 dsh tarball 打 9 个补丁,适配 Bionic libc | 官方 glibc 构建 + grun 启动器,零源码补丁 |
| libc 类问题 (statx/posix_spawn/platform 判断) | 逐个打补丁 | 自动解决(`process.platform === "linux"`) |
| Android 环境问题 (sepolicy link 拦截、无 /bin/bash、bubblewrap) | 仍需补丁/降级 | 同样存在,躲不掉 |
| 升级风险 | 补丁 context drift,静默失效 | 同样存在,但补丁面小得多 |
| 需要编译 | koffi + node-pty 对 Bionic sysroot 编译 | koffi/sharp 用预编译包,仅 node-pty 需编译 |

**结论:选 B。** glibc 路线把"libc 适配"整类问题消掉,只剩 2 个 Android 环境层问题(会话持久化 link 拦截、沙箱不可用),其中持久化问题一条补丁解决,沙箱问题属于安全降级(有明确报错,非数据丢失)。

### 1.2 关键事实(实施前调查)

- Termux glibc 仓库(416 包)已有:glibc 2.43、glibc-runner 2.0-3、clang-glibc、make-glibc、python-glibc、ncurses-glibc 等
- **仓库中没有 nodejs-glibc** → 必须用 nodejs.org 官方 linux-arm64 glibc 构建
- glibc 2.43 足够新,官方 Node LTS 构建要求 ≥2.28,兼容

---

## 2. 实施步骤(可复现)

### 2.1 基础组件

```bash
# 1. glibc 运行环境(设备上已装 glibc 2.43,补装 runner)
DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" glibc-runner

# 2. glibc 工具链(koffi 免构建后,仅 node-pty 编译需要)
DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" clang-glibc make-glibc python-glibc cmake-glibc pkgconf-glibc lld-glibc

# 3. 官方 glibc Node.js(2026-08 时点 LTS = v24.19.0)
#    nodejs.org/dist/v24.19.0/node-v24.19.0-linux-arm64.tar.xz
mkdir -p /data/data/com.termux/files/usr/glibc/opt
tar xf node-v24.19.0-linux-arm64.tar.xz -C /data/data/com.termux/files/usr/glibc/opt
```

### 2.2 DNS(glibc 进程专用,关键!)

Android 的 netd DNS 只服务 Bionic;glibc 进程读 `/etc/resolv.conf`(不存在 → 解析失败)。

```bash
# dns53.js 常驻转发器(设备已有,监听 127.0.0.1:53)
sudo nohup node ~/.local/bin/dns53.js &

# glibc 程序解析入口:把 termux 的 resolv.conf 指向本机转发器
# (注意:此文件由 dns-bootstrap.js 自动维护,重写后需重新执行!)
cp /data/data/com.termux/files/usr/etc/resolv.conf /data/data/com.termux/files/usr/etc/resolv.conf.bak
printf "# dsh glibc test\nnameserver 127.0.0.1\n" > /data/data/com.termux/files/usr/etc/resolv.conf
```

**为什么要 127.0.0.1 而不是公共 DNS**:node 的 glibc 解析器对 AF_UNSPEC 查询先发 AAAA(IPv6),Android 无 IPv6 路由 → 内核 EHOSTUNREACH → 直接 EAI_AGAIN 失败(公共 DNS 直连不可行);dns53 收到 AAAA 会抑制(返回空),glibc 便回退 A 查询走 IPv4 → dns53 转发到手机当前 DNS → 成功。

### 2.3 npm 安装 dsh

npm 官方 tarball 自带 npm,但 **npm 脚本 shebang 是 `#!/usr/bin/env node`(Android 无 /usr/bin/env)**,需用 node 直接执行 npm-cli.js:

```bash
# 用 wrapper 保证 PATH 中的 node 可被 sh/子进程直接执行(见 2.4)
npm install -g --ignore-scripts @deepseek-ai/dsh
# 实际执行:
# PATH=... grun $GLIBC_NODE $NODE_DIR/lib/node_modules/npm/bin/npm-cli.js install -g --ignore-scripts @deepseek-ai/dsh
```

`--ignore-scripts` 必须:原生模块的 install script 会 spawn node,必须走 wrapper;且我们手动控制构建时机。

### 2.4 wrapper 脚本(核心基础设施)

`/data/data/com.termux/files/usr/glibc/opt/bin/` 下放置(目录置于 PATH 首位):

```bash
# node —— 所有直接 exec 的场景(install scripts、node-gyp、CMake)都经过它
#!/data/data/com.termux/files/usr/bin/bash
exec grun /data/data/com.termux/files/usr/glibc/opt/node-v24.19.0-linux-arm64/bin/node "$@"

# pnpm —— dsh plugin 管理用 spawnSync("pnpm") 直接 exec
#!/data/data/com.termux/files/usr/bin/bash
exec grun /data/data/com.termux/files/usr/glibc/opt/node-v24.19.0-linux-arm64/bin/node /data/data/com.termux/files/usr/lib/node_modules/pnpm/bin/pnpm.cjs "$@"
```

### 2.5 原生模块处理(实测结果:意外地顺利)

| 模块 | 结果 | 说明 |
|---|---|---|
| koffi 3.1.5 | ✅ 免构建 | npm 自动装了 `@koromix/koffi-linux-arm64` **预编译 glibc 包**(linux_arm64/koffi.node),直接可用 |
| sharp | ✅ 免构建 | `@img/sharp-linux-arm64` + `sharp-libvips-linux-arm64` 预编译包齐了 |
| node-pty | ✅ 编译 | node-gyp rebuild,clang-glibc 一次通过(需 node 24 headers,npm 内置 node-gyp) |

koffi 的 cnoke.cjs 曾被打过 execPath 补丁(把 `process.execPath` 替换为 wrapper 路径),但最终因预编译包存在而未实际触发构建,该补丁保留无害。

### 2.6 移动端 UI 插件

```bash
# 需要 pnpm wrapper(见 2.4),profile 会自动初始化
dsh plugin --profile web add github:mexiaosqwq/dsh-web-mobile
# 效果:窄屏(<1024px)侧边栏隐藏 → 抽屉式目录,会话全宽,竖屏适配
```

### 2.7 启动

```bash
# scripts/run_dsh_web.sh(本目录已存副本)
grun $GLIBC_NODE --expose-internals /data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/lib/bin.js web
# 服务:http://127.0.0.1:3080
# --expose-internals 必须:HMR 插件(cordis-plugin-hmr)访问 node 内部模块(Node 22+ 默认禁用)
```

---

## 3. 踩坑记录(按时间线)

### 3.1 glibc 程序 DNS 解析失败 —— EAI_AGAIN
- 现象:npm install 报 `EAI_AGAIN`,curl(bionic)正常
- 根因:glibc 进程读 `/etc/resolv.conf`(Android 无此文件),而 Bionic 走 netd;且 glibc 对 AF_UNSPEC 先发 AAAA 查询,无 IPv6 路由直接 EHOSTUNREACH
- 解法:resolv.conf 指向 127.0.0.1(dns53 转发器),见 2.2
- 诊断方法:`strace -f -e trace=sendto,recvfrom` 对比 python(成功,发 A 查询)与 node(失败,发 AAAA)的行为差异

### 3.2 直接 exec glibc node 失败 —— "required file not found"
- 现象:`./node --version` 报 required file not found
- 根因:node 官方二进制 PT_INTERP = `/lib/ld-linux-aarch64.so.1`,Android 根文件系统无此路径
- 解法:一律经 grun(`exec ld.so <binary>`)启动
- **教训:禁止对 glibc node 使用 `grun -c`(patchelf --set-interpreter)**——实测 patchelf 后直接 exec 会 SIGSEGV,且连 grun 都无法再启动(必须重新解压 tarball 恢复);CLAUDE.md 中 claude 的 musl+patchelf 方案不适用于 glibc node

### 3.3 npm install script 失败 —— sh -c node 无法执行
- 现象:koffi install script `sh -c node ./cnoke.cjs` 报 127
- 根因:termux bash 直接 exec glibc node(PT_INTERP 问题)
- 解法:node wrapper(2.4),PATH 置首

### 3.4 koffi 构建时 CMake 直接 exec NODE_JS_EXECPATH 失败
- 现象:`trampolines.cjs: error while loading shared libraries: invalid ELF header`
- 根因:cnoke.cjs 用 `process.execPath`(= 真实 glibc node 二进制)传给 CMake 作为 trampoline 生成器,直接 exec 崩溃
- 解法(未走通):wrapper 无法骗过 process.execPath(exec 后即真实二进制)→ 需改 cnoke.cjs
- **最终绕开**:发现 `@koromix/koffi-linux-arm64` 预编译包存在,根本不触发构建(3.5)

### 3.5 会话持久化 link(2) 被 sepolicy 拦截 —— 静默数据丢失
- 现象:会话目录永远为空,无任何报错
- 根因:dsh-session-persistence-jsonl 的 `materializePosix` 用 `link(tmp, finalPath)` 做原子发布,Android sepolicy 对硬链接返回 EACCES(与 libc 无关,任何路线都中招)
- 解法:补丁(见 patches/)——link 失败且 code 为 EACCES/EPERM 时回退 `rename(tmp, finalPath)`(同文件系统原子性等价)
- 说明:profile 与全局的 dsh-session-persistence-jsonl 是**同一 inode(pnpm 硬链接)**,打一次补丁两处生效
- **严重性:无声数据丢失**——消息从不落盘,进程内存正常,重启才暴露

### 3.6 沙箱 bubblewrap 不可用 —— 安全降级(预期行为)
- 现象:Bash 工具首次调用报 `SandboxUnavailableError`
- 根因:bwrap 探测失败:`Can't read /proc/sys/kernel/overflowuid: Permission denied`(sepolicy),landlock 需要内核 ≥5.13(Android 4.19 没有)
- 行为:dsh fails closed(拒绝执行,不降级直跑),agent 按系统提示词自动升级权限 → 用户批准 → 命令以 `danger-full-access` 直跑成功
- 结论:安全设计,非缺陷;日常使用多一次"升级+批准"交互

### 3.7 持久终端 (PTY) 装配:terminals 服务缺失 + 同名工具冲突
- 现象一:web profile 默认**没有 `terminals` 服务提供者**(官方 web 不启用持久终端),`tool-bash-persistent` 无法激活
  - 解法:`~/.dsh/profiles/web/plugins/terminals.js`(3 行本地插件,`new TerminalSessionService(ctx)`,Service 构造自动注册服务)+ `cordis.patch.yml` insert `terminals`/`terminal-bash`/`tool-bash-persistent` 三行;`terminal-bash` 的 `shellPath` 默认 `/bin/bash`(Android 没有),须指向 `/data/data/com.termux/files/usr/bin/bash`
- 现象二:`tool-bash-persistent` 注册工具名硬编码为 `bash`,与普通 bash 工具**同名** → NamedEntries 重名冲突,持久版被普通版静默覆盖(agent 拿到的 schema 含 `run_in_background`,是普通版)
  - 解法:改名一行补丁 `"bash"` → `"bash_persistent"`(见 5.5)
- 现象三:`bash_persistent` 在 `workspace-write` 预设下被沙箱拒绝(SandboxUnavailableError)
  - 解法:权限预设切 `danger-full-access`(web GUI 权限选择器,或 `DSH_PERMISSION_MODE=danger-full-access` 环境变量)
- 验证:跨调用保留 `MY_VAR`/`ANOTHER_VAR` 等环境变量与 cwd;普通 `bash` 每次全新 shell 不共享状态
- 附:agent 曾用 tmux 3.7b 自建持久会话(`tmux new-session -d -s persist` + send-keys/capture-pane),作为内置工具不可用时的 fallback,亦可长期使用

### 3.8 杂项
- `pkill -f "bin.js web"` 会匹配自身命令行导致会话自杀 → 用 `pkill -f "[b]in.js web"`(字符类技巧)
- termux 无 `which` 命令,用 `command -v`
- strace 默认不记录网络 syscall,查 DNS 行为要显式 `-e trace=sendto,recvfrom`
- npm 输出重定向后是块缓冲,长时间无输出不代表卡死;建议 `stdbuf -oL` + 后台运行 + 轮询日志
- npm 安装偶发 SIGTERM(疑 Android 后台管理),用 `setsid nohup ... & disown` 脱离会话
- pnpm/全局 CLI 的 shebang `#!/usr/bin/env node` 在 Android 全部失效,dsh 的 plugin 管理器 spawnSync 不走 shell,须提供 pnpm wrapper

---

## 4. 测试进度

| # | 项目 | 状态 | 验证方式 |
|---|---|---|---|
| 1 | glibc node 运行 | ✅ | `grun node --version` → v24.19.0 |
| 2 | process.platform | ✅ | 输出 `linux`(dsh 所有 linux 分支直接走通) |
| 3 | DNS 解析 | ✅ | node dns.lookup baidu → 183.2.172.177 |
| 4 | koffi 加载 | ✅ | require 成功,version 3.1.5 |
| 5 | node-pty | ✅ | 编译通过 + spawn bash 输出 PTY_OK |
| 6 | dsh web 服务 | ✅ | HTTP 200 @ 127.0.0.1:3080 |
| 7 | 移动端 UI 插件 | ✅ | dsh-mobile-nav 入 bundle,HTTP 200 |
| 8 | **会话持久化** | ✅ 已修复并验证 | "你好"消息落盘 `session.jsonl.zstd`(19.9KB,完整事件流);dsh 重启后文件仍在 |
| 9 | **沙箱降级** | ✅ 行为符合设计 | 首次调用被拒(SandboxUnavailableError)→ agent 自动升级 → 批准后 pwd 成功 |
| 10 | **持久终端 (bash_persistent)** | ✅ 装配 + 验证 | 见 3.8;跨调用保留环境变量/工作目录;普通 bash 不共享状态(对比测试) |
| 11 | 打开链接/路径 (host-apiproxy) | ✅ 优雅降级(维持官方禁用) | 打开路径:canOpenNativePath() 检测无桌面 → UI 不暴露按钮(纯文本);web_fetch:官方 `fetch: false` + 无 provider 是有意 SSRF 防护;抓取用 firecrawl 替代 |
| 12 | **升级流程** | ✅ 演练完成,结论明确 | 全局重装会**刷新 profile 依赖树,两个补丁全部丢失**(实测);重打 + 重启验证通过;官方无自动更新机制 |

---

## 5. 维护注意事项(必读)

### 5.1 升级 = 补丁全丢(2026-08-17 实测)
- `npm install -g @deepseek-ai/dsh` 重装会**刷新 profile 依赖树(pnpm 硬链接)**,两个补丁全部丢失:link→rename 持久化补丁、bash_persistent 改名补丁
- dsh 处于 developer preview,破坏性变更频繁;**官方无自动更新机制**(无 update 子命令、无启动时/后台版本检查),更新完全手动
- **升级流程**:① `npm install -g @deepseek-ai/dsh@<新版本>` ② 重打 patches/ 下补丁(`patch -p1` 于对应包目录 + sed 改名)③ 重启 ④ 发一条消息确认 JSONL 落盘 ⑤ 确认 bash_persistent 存在
- 新版本补丁可能 context drift(打不上但无报错),`patch --dry-run` 先检查

### 5.2 DNS 三要素(缺一不可)
1. dns53 常驻(手机重启后需重启,建议加开机自启)
2. `/usr/etc/resolv.conf` 指向 127.0.0.1(dns-bootstrap.js 重写后需重写)
3. 症状:npm EAI_AGAIN,不明确报错

### 5.3 进程保活
- dsh web 无开机自启;建议 `termux-wake-lock` 防止后台被杀
- 启动脚本:本目录 `scripts/run_dsh_web.sh`(内容见 2.7)

### 5.4 数据备份
- 全部数据在 `~/.dsh/`(profiles + sessions + settings),备份这一个目录即可
- 恢复 = 重装组件 + 重打补丁 + 还原 `~/.dsh`

### 5.5 持久终端 (bash_persistent) 维护要点
- **profile 专属补丁(升级全局 dsh 不影响)**:`dsh-tool-bash-persistent` 只在 profile 依赖树,不在全局;改名 `bash` → `bash_persistent` 在 `~/.dsh/profiles/node_modules/@deepseek-ai/dsh-tool-bash-persistent/lib/index.js:325`,重装 profile 插件后需重打
- **权限模式**:`bash_persistent` 走沙箱策略,主机无沙箱后端时仅在 `danger-full-access` 预设下可用;模式由 `DSH_PERMISSION_MODE` 环境变量或 web GUI 权限选择器控制(配置见 cordis.yml 的 sandbox-policy / approval / permission-presets 行)
- **fallback 方案**:tmux(agent 已掌握:new-session -d -s persist + send-keys + capture-pane),内置工具不可用时同样能提供持久 shell

### 5.6 已知未解决问题
- 沙箱不可用:安全降级,命令需升级批准后直跑(切 danger-full-access 预设可免除审批)
- 打开链接(web_fetch):官方有意禁用(SSRF 防护设计,无 fetch provider),抓取内容用 firecrawl / web_search 替代
- 工具链(clang-glibc 等)占数百 MB,勿随意 autoremove(编译 node-pty 需要)

---

## 6. 关键路径速查

```
glibc 运行时        /data/data/com.termux/files/usr/glibc/
glibc node          /data/data/com.termux/files/usr/glibc/opt/node-v24.19.0-linux-arm64/
wrapper 目录        /data/data/com.termux/files/usr/glibc/opt/bin/{node,pnpm}
全局 dsh            /data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/
profile + 数据      ~/.dsh/
dns53 日志          ~/.codex/dns53.log
启动脚本(副本)      ~/deepseek-harness-termux/scripts/run_dsh_web.sh
持久化补丁(副本)    ~/deepseek-harness-termux/patches/02-session-persistence-link-rename.patch
```

## 7. 版本记录

| 组件 | 版本 |
|---|---|
| @deepseek-ai/dsh | 0.1.0-rc.7 |
| Node.js (glibc) | 24.19.0 (nodejs.org linux-arm64) |
| npm | 11.17.0 |
| koffi | 3.1.5(预编译 @koromix/koffi-linux-arm64) |
| node-pty | 源码编译 |
| glibc | 2.44 |
| glibc-runner | 2.0-3 |
| dsh-web-mobile | github:mexiaosqwq/dsh-web-mobile |

## 8. 参考来源

本方案安装过程中使用的第三方仓库/项目(按用途分类):

### 软件源
- **termux-glibc 仓库**:`https://packages-cf.termux.dev/apt/termux-glibc/`(glibc 运行时、glibc-runner、clang-glibc 等工具链来源,termux/termux-glibc-packages)
- **Termux 官方仓库**:`https://packages.termux.dev/`(基础环境,`pkg`/`apt` 自带镜像自动选择 `select_mirror`)
- **termux-root-repo**:`https://packages-cf.termux.dev/apt/termux-root/`(`sudo` 等 root 工具,随安装脚本添加)

### 软件包
- **Node.js**:`https://nodejs.org/dist/v24.19.0/node-v24.19.0-linux-arm64.tar.xz`(官方 glibc linux-arm64 构建,经 `grun` 运行)
- **@deepseek-ai/dsh**:`https://www.npmjs.com/package/@deepseek-ai/dsh`(DeepSeek Harness 本体,版本固定 0.1.0-rc.7)
- **pnpm**:`https://www.npmjs.com/package/pnpm`(dsh profile 依赖管理,Termux 仓库无此包,经 npm 安装)

### 项目参考
- **dsh-web-mobile**:`https://github.com/mexiaosqwq/dsh-web-mobile`(移动端 web UI 插件,`dsh plugin --profile web add github:mexiaosqwq/dsh-web-mobile`)
- **Vengisk/deepseek-harness-termux**:`https://github.com/Vengisk/deepseek-harness-termux`(社区补丁路线,与本项目对照评估后未采用,见第 0 节对比表)

### 镜像源(install.sh 测速候选,仅旧版 pkg 使用)
- packages.termux.dev(官方)
- mirrors.aliyun.com/termux(阿里云)
- mirrors.tuna.tsinghua.edu.cn/termux(清华 TUNA)
- mirrors.ustc.edu.cn/termux(中科大 USTC)
- mirrors.tencentyun.com/termux(腾讯云)
- mirrors.huaweicloud.com/termux(华为云)
