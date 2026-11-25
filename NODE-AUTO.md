# 手动安装教程：当一键脚本用不上时

一键脚本适合「普通服务器」：有完整的 shell 环境、出站网络通畅、端口自己说了算。
但现实里常遇到三类环境，一键脚本要么跑不动、要么跑起来也保不住进程，只能手动装。
本教程按环境类型讲手动流程的原理与步骤顺序。

先说三类环境共同的底层逻辑，后面不再重复：

- **手动流程用的程序包就是配套项目 yunting**（https://github.com/lnant/sing-box-auto/tree/main/yunting）：
  把该仓的文件整套取下来，传到目标环境里你新建的应用目录根下即可。
  这个目录里就这些东西：主程序 `app.js`（入口，服务本体）、依赖清单 `package.json`
  （只依赖 ws 一个包）、几个静态页面与 `poems/` 目录（站点页面内容）、
  `Dockerfile`（面板主机构建时用）。后文各节说的「程序文件」指的就是这一套；
  配置与证书不在仓里，按各节说明在目标环境现生成或自备。
- 程序本体是一个跑在 Node.js 运行时上的单文件服务，不带任何代理类二进制；
  机器上有没有预装运行时不重要，可以由脚本自带，也可以手动准备。
- 一套安装由这几样东西构成：运行时、程序文件、依赖包、一份配置
  （标识符、对外地址、端口都记在里面）、一张证书（仅加密实例需要）、
  一个负责「掉了就拉起来」的守护。
- 配置是整套东西的命根子：标识符和端口都由它决定。配置在、证书在，
  换台机器照着重装，客户端那边的链接一条都不用改。
- 服务本身不记连接日志；守护只记「什么时候把服务拉起来过」这类事件。

示例里出现的标识符、端口、地址全是占位写法（如 `<标识符>`、`<高位端口甲>`、
`node.example.com`），照着替换成你自己的即可。

---

## 〇、普通服务器：一键装之前先看这几条

普通服务器上用一键脚本时，有五件事先说清：

- **选口**：端口不指定时，脚本先从 CDN 的代理名单口里挑——加密侧是
  443、8443、2053、2083、2087、2096，明文侧是 8080、2052、2082、2086、2095；
  名单口全被占了才随机挑高位口。安装流程里会当场说明最终落在哪个口、属于哪一类。
  注意：不是 root 运行时，低于本机非特权下限（通常是 1024）的名单口绑不了，
  脚本选口时会自动跳过它们（比如非 root 时加密侧从 8443 起挑）。
  脚本默认以运行它的身份直接安装，不自动提权：自动选口绑不了就自动绕开；
  只有你明确指定了这类特权口、或非 root 时明确指定了 systemd 保活，
  这类直接装办不到的事，脚本才会先出声提示、再经管理员提权（sudo）
  以 root 身份落地，并在输出里说清用了提权——绝不静默提权；提权不可用时，
  特权口会如实报错、systemd 会回落成巡检守护并说明。装完脚本还会自检
  实例是否真在目标口应答，没起来如实报错、不会报「安装完成」。
- **黄云与灰云**：落在名单口的，装完后域名可以开 CDN 代理（黄云）；
  其中加密链要在 CDN 侧把加密模式设为完整模式（源站是自签证书，严格验证过不了）。
  落在随机口的，域名只能用仅解析（灰云）模式——CDN 只转发名单内的端口，
  开了代理也到不了随机口。
- **重跑菜单**：已经装好的机器，在终端里不带任何参数重跑脚本，进一个数字菜单：
  1 看链接、2 改域名（重签证书并重出链接，标识符与端口不变）、3 重启服务、
  4 卸载、0 退出。带参数或非交互的调用不进菜单，照常走安装流程。
- **公网 IP 不落在网卡上的云主机**：有些云主机有自己独占的公网 IP，
  但这个地址并不落在网卡上——在机器里看网卡，只能看到一个内网地址，
  公网 IP 的对应关系在机器外面。注意这和共享 IP、只映射几个端口的
  小机器是两回事：这种云主机是全端口都归它，只是机器自己不知道
  自己的公网 IP 而已，用管理员身份进机器也一样看不到。
  校验域名解析时，脚本的顺序是「能直接获得的，就直接过」：
  先比对网卡地址，再向机器自身的元数据服务（一个 link-local 地址）
  问一句本机公网地址、一并纳入比对，问不到就短超时跳过、不卡安装；
  任一路命中就直接用域名，不多问一句。用裸地址出链接时也优先用
  问到的这个公网地址。全程只比对本机地址集合，不经过任何第三方
  查询站点。对外地址（进证书与链接的那个）只认公网 IP：内网、回环、
  链路本地地址一律不算数，域名校验的本机地址集合也只收公网地址
  （再加手填的）。要是网卡与元数据都给不出公网地址，脚本不会拿
  内网地址顶上：交互安装会当场请你手填公网 IP（为什么要填、填了
  用在哪，提示里都写明；空输入、超时、格式不对、填的是内网地址
  都算错一次、每次提示已错几次，满 3 次就退出安装），非交互则
  直接报错退出、写明重跑时加 `--ip <公网地址>`。手填对的 IP 会
  存进配置，以后不用再填。还有一种断不准的情形：探测到的地址
  落在 100.64.0.0/10（运营商级 NAT）段里——它不在内网段里、又没
  法光凭地址断定是公网，脚本不会硬判：交互安装会请你输入确认，
  提示里写明输入的必须是服务器的公网 IP；你输入的与探测到的完
  全一致，就按你确认是公网接受，输入别的地址则照常验公私（内
  网、回环照旧不算数），空输入、超时、输错同样计次、满 3 次退
  出安装；非交互则报错退出、写明加 `--ip` 重跑。用 `--ip` 或之
  前存进配置的地址就是这个段里的，等于你已经确认过，不再多问。
  交互安装里有一个输入域名的步骤，域名与公网 IP 是前后两道判断，
  每轮输入都限时 20 秒，照着屏幕提示一步步走就能走通：
  - **第一步，定域名（可以跳过）**：没有域名、或还没弄好解析的，
    直接回车（或 20 秒不输入）跳过，不算错——用本机地址出链接、
    照常往下装，域名以后随时能加。有自己的域名就在这一步输入
    完整域名，接下来脚本会把要加的解析记录原样打印出来（类型、
    名称、内容、代理状态、TTL 都写全），你照着去域名面板把这条
    记录加上——记录由你自己加，脚本不碰任何解析后台、不要任何
    令牌；特别注意代理状态要关（仅解析），不要开黄云：开了黄云，
    解析到的是 CDN 的地址，和本机地址永远对不上。记录加好后脚本
    会轮询约 1 分钟等解析生效，验过就用域名出链接、证书也签给它。
  - **验不过怎么办**：脚本会把实际查到的解析原样打出来（查到了
    哪些地址、还是压根没有任何记录），并计 1 次错。这时不用重输
    域名：直接回车就是复查同一个域名（刚加的记录可能只是还没
    生效，稍等一会儿复查即可）；输入一个新域名就是换一个再查；
    20 秒不输入也算 1 次错；输的域名格式不对只会提醒重输、不计
    次。满 3 次错，就不用域名了、用本机地址出链接把安装走完。
    域名后期随时可改：装完重跑脚本、用菜单 2 改域名，或带新域名
    重跑都行，标识符与端口不变。
  - **第二步，确认公网 IP（只在特定情况下出现）**：只有域名解析
    到了、只是脚本自动确认不了它是不是本机（就是上面说的公网 IP
    不落在网卡上、元数据也问不到的机器）时，才多出这一步。提示
    里会说清为什么要手填、去哪里看这个 IP（云厂商控制台／服务商
    面板）。先把域名解析指向本机公网地址，再在这一步把公网 IP
    填进去，脚本拿它重新比对，命中后照常重签证书、出域名链接。
    空填、格式不对、与域名解析对不上、超时没输完都算失败；满
    3 次直接报错、退出安装——先去控制台把本机公网 IP 确认准了
    再重跑，重跑时也可以直接用参数给（见下一段）。填对的 IP 会
    记进配置，之后普通重跑也沿用，不用每次都填。
  菜单里改域名也是同一套：菜单里只输入新域名，接下来的校验、
  复查、确认公网 IP 都由安装流程按上面同样的步骤接管，照提示走
  即可；验不过会改用本机地址出链接把这次走完，之后随时能再改。
  不是交互安装（比如一条命令带齐参数跑完）时没有输入步骤、不会
  提问，就用参数兜底：重跑脚本、用 `--ip <公网地址>` 把公网地址
  手填给脚本、同时带上 `--domain <域名>`，效果一样；参数也没给、
  又确认不了的，就先改用裸 IP 出链接装完，之后再带参数重跑切换
  成域名。只给 `--ip` 不给域名时，直接用它出链接。

- **FreeBSD 机器**：一键脚本也可以装。Node 官方不发布 FreeBSD 的
  二进制包，所以这类机器不走「脚本自拉运行时」：系统里有 Node 18
  以上（一般是 pkg / ports 装的）就直接用系统的，不下载、也不在
  安装目录里另备一份；系统没有 Node、或版本不够，先装一个
  （如 `pkg install node22`），或把 Node 包传进机器、用
  `--node-tarball` 指定给脚本，再运行安装。其余装法、保活（巡检
  守护）、重跑菜单都与 Linux 相同。实际用的 Node 来源与路径记在
  安装目录的 `config.env` 里（`NODE_SOURCE` / `NODE_BIN` 两项）；
  卸载只删安装目录，不会动系统的 Node。

一句总说明：**测试环境有限，不保证实际环境安装效果。**

---

## 一、某些不支持二进制的共享服务器

这类环境的特征：多人共用一台机器，每人一个受限账号；不给 root，
不给 systemd；明令禁止落地来历不明的二进制程序，但脚本语言运行时通常不管；
端口由平台预先分配给你几个，只能用分到的；进程总数有上限。

**在哪用**：全部命令在你登录进这台共享服务器后的 shell 里执行
（SSH 登录，或平台给的网页终端），工作目录是你的账号主目录 `~`；
整套东西只装在 `~/yunting/` 一个目录里，不写系统目录、不需要 root。

### 前置条件（用啥）

- **端口**：平台已分配至少一个入站端口（一个口起一个实例；
  两个口可加密、明文各一）。先把分到的端口清单记下来，后面全围着它转。
- **工具**：POSIX sh 与 tar（解 `.tar.gz` 还要 gzip，一般都在）；
  任意一种下载工具。先自查一遍，哪个有输出就用哪个：

  ```sh
  command -v curl wget fetch python3 perl tar
  ```

- **文件**：本仓 `yunting/` 目录的整套文件（见开头）；Node.js 运行时官方压缩包
  （`.tar.gz` 格式，下载方式见步骤 4）。
- **出站**：能访问 nodejs.org（下运行时）与 registry.npmjs.org（装依赖）。
  两处都到不了的，走步骤 4、5 的「本地包」路线：在自己电脑上备齐再送进来。

### 目录布局（在哪用）

装完后 `~/yunting/` 里长这样，后文命令里的路径都以此为准：

```text
~/yunting/
├── node/                 自带 Node 运行时（bin/node、bin/npm）
├── app/                  yunting 程序文件（从仓库放进来）
│   ├── app.js            入口，服务本体
│   ├── package.json      依赖清单（只依赖 ws）
│   ├── index.html  game.html  about.html  poems.html
│   ├── poems/            五个词页 html（子目录，保持原样）
│   └── node_modules/ws/  步骤 5 装出的依赖
├── tools/                证书生成小工具（gen-cert.js，步骤 8 用）
├── cert.pem  key.pem     自签证书与私钥（仅加密实例需要）
├── config.env            配置（权限 600，字段见步骤 7）
├── start.sh              启动器：缺谁补谁（步骤 9 给全文）
├── guard.sh              守护：30 秒巡检（步骤 9 给全文）
├── stop.sh               停止：停守护与实例，不删文件
├── run/                  tls.pid / plain.pid / guard.pid
└── logs/                 tls.log / plain.log / guard.log（拉起事件）/ guard.out（守护自身输出）
```

### 关键步骤顺序（怎么用）

1. **记端口、定分工**：把平台分给你的端口写下来，先定好哪个当加密口
   （下文 `<高位端口甲>`）、哪个当明文口（`<高位端口乙>`）。
   只有一个口时二选一：要加密就只起加密实例，要省事就只起明文实例。

2. **建目录**：

   ```sh
   mkdir -p ~/yunting/app ~/yunting/tools ~/yunting/run ~/yunting/logs
   ```

3. **放程序文件**：把本仓 `yunting/` 目录的文件放进 `~/yunting/app/`——
   能直连仓库且有 git 时，执行
   `git clone https://github.com/lnant/sing-box-auto`，把克隆结果里 `yunting/`
   目录下的文件放进 `~/yunting/app/`；
   没有 git 时，在机器上直接下载仓库压缩包、只解开其中的 `yunting/`
   目录（`--strip-components 2` 是剥掉包里顶层两层目录，正好落进 app/）：

   ```sh
   curl -fsSL https://github.com/lnant/sing-box-auto/archive/refs/heads/main.tar.gz | tar -xz -C ~/yunting/app --strip-components 2 sing-box-auto-main/yunting
   # 没有 curl 时：wget -qO- https://github.com/lnant/sing-box-auto/archive/refs/heads/main.tar.gz | tar -xz -C ~/yunting/app --strip-components 2 sing-box-auto-main/yunting
   ```

   连仓库也直连不了时，在自己电脑上下载仓库压缩包、解开后把文件上传到这个目录。
   放完核对：`app.js`、`package.json`、四个 html、`poems/` 子目录都在，
   少哪个页面哪个路径就打不开。

4. **准备 Node 运行时**（装到 `~/yunting/node/`，自带、不依赖系统）：

   先看系统有没有现成的：`node --version` 有 v18 以上输出也可以直接用，
   后面命令里的 `~/yunting/node/bin/node` 换成 `node` 即可；没有就自拉：

   ```sh
   uname -m    # 先确认架构，下一步的包名要用：x86_64→x64，aarch64→arm64，armv7l→armv7l
   # 查当前 v22 最新版号（记下输出，如 v22.23.5；查不到就用这个已知版本）
   curl -fsSL https://nodejs.org/dist/index.json | grep -o 'v22\.[0-9]*\.[0-9]*' | head -n 1
   # 下载（以 x64 为例，arm64 把 x64 换成 arm64；版本号换成上一步查到的）
   curl -fL -o ~/node.tar.gz https://nodejs.org/dist/v22.23.5/node-v22.23.5-linux-x64.tar.gz
   # 没有 curl 时任选其一：
   wget -O ~/node.tar.gz https://nodejs.org/dist/v22.23.5/node-v22.23.5-linux-x64.tar.gz
   python3 -c 'import urllib.request; urllib.request.urlretrieve("https://nodejs.org/dist/v22.23.5/node-v22.23.5-linux-x64.tar.gz", "node.tar.gz")'
   # 解压（--strip-components 1 是把包里顶层目录剥掉，正好落进 node/）
   tar -xzf ~/node.tar.gz -C ~/yunting/node --strip-components 1
   ~/yunting/node/bin/node --version    # 应输出 v22.x.x
   ```

   包的格式只挑 `.tar.gz`：它只依赖 tar 与 gzip，几乎所有环境都解得开；
   `.tar.xz` 还需要 xz 工具，精简环境里常常没有，选错了会卡在解压这一步。
   **连下载工具都没有时**：在自己电脑上按上面的地址下载 `.tar.gz` 包，
   用平台允许的任意方式（文件管理、SFTP 等）送进账号主目录，
   再从解压那一步接着做。

5. **装依赖（只在安装期装这一次）**：`app/package.json` 的内容就是仓库里那份，
   核心是把 ws 锁在 8.18.3：

   ```json
   {
     "name": "yunting",
     "version": "1.0.0",
     "private": true,
     "description": "云汀 · 诗词小读",
     "dependencies": {
       "ws": "8.18.3"
     }
   }
   ```

   ```sh
   cd ~/yunting/app && ~/yunting/node/bin/npm install --no-audit --no-fund
   ls ~/yunting/app/node_modules/ws    # 有输出才算装好
   ```

   出站到不了 npm 时：在自己电脑上对同一份文件跑一遍 `npm install`，
   把生成的 `node_modules/` 整个打包送进 `~/yunting/app/` 解开，效果一样。
   不要指望运行时再自动装包——受限环境里现装既慢又容易被进程上限卡死。

6. **生成标识符**（二选一，有输出即可），把结果记下来：

   ```sh
   cat /proc/sys/kernel/random/uuid
   ~/yunting/node/bin/node -e 'console.log(require("crypto").randomUUID())'
   ```

7. **写配置 `~/yunting/config.env`**（逐项字段，值换成你自己的）：

   ```ini
   UUID=<标识符>            # 步骤 6 生成的那个；生成后不要改，改了客户端链接全变
   DOMAIN=<对外域名或地址>   # 链接与证书用的对外地址：你的域名，或平台给的对外地址
   TLS_PORT=<高位端口甲>     # 加密实例监听口；不起加密实例就留空
   PLAIN_PORT=<高位端口乙>   # 明文实例监听口；不起明文实例就留空
   CERT_DOMAIN=<对外域名或地址>  # 证书签给谁，一般与 DOMAIN 相同；与 DOMAIN 不一致时要重签证书
   KEEPALIVE=guard          # 无 systemd 的环境固定写 guard
   PUBLIC_IP=               # 仅「公网 IP 不落在网卡上」的机器手填，没有就留空
   PLAIN_LINK_HOST=         # 以下四项一般留空；只有给明文实例单独换链接形态时才填（第二节步骤 5）
   PLAIN_LINK_PORT=
   PLAIN_LINK_SECURITY=
   PLAIN_LINK_SNI=
   ```

   写完收紧权限：`chmod 600 ~/yunting/config.env`。
   这份文件就是日后重装、迁移、恢复的依据，另在机器外留一份副本。
   说明：start.sh 实际读取的是 UUID、DOMAIN、TLS_PORT、PLAIN_PORT 与
   PLAIN_LINK_* 这几项；CERT_DOMAIN 只是给日后重签证书时对照的记录
   （证书实际签给谁，以步骤 8 生成证书时填的为准），KEEPALIVE 与
   PUBLIC_IP 是备忘字段，改它们不会改变这几个脚本的行为。

8. **生成自签证书**（仅起加密实例时需要，二选一）：

   有 openssl 时最省事（域名版；对外地址是 IP 时把
   `subjectAltName=DNS:<对外域名>` 换成 `subjectAltName=IP:<公网地址>`）：

   ```sh
   openssl req -x509 -newkey rsa:2048 -nodes \
     -keyout ~/yunting/key.pem -out ~/yunting/cert.pem -days 3650 \
     -subj "/CN=<对外域名>" -addext "subjectAltName=DNS:<对外域名>"
   chmod 600 ~/yunting/key.pem
   ```

   没有 openssl 时用纯 JS 路线（只依赖一个 npm 包，不碰系统工具）：
   先在 `~/yunting/tools/` 放一份 `package.json`：
   `{"name":"cert-tools","private":true,"dependencies":{"selfsigned":"^5.2.0"}}`，
   在该目录跑 `~/yunting/node/bin/npm install --no-audit --no-fund`，
   再把下面这段存为 `~/yunting/tools/gen-cert.js`：

   ```js
   // 用法：node gen-cert.js <域名或IP> [天数] [输出目录] → 写出 cert.pem / key.pem
   const fs = require('fs');
   const path = require('path');
   const selfsigned = require('selfsigned');
   async function main() {
     const domain = process.argv[2] || 'localhost';
     const days = parseInt(process.argv[3] || '3650', 10);
     const outDir = process.argv[4] || path.join(__dirname, '..');
     const isIp = /^\d{1,3}(\.\d{1,3}){3}$/.test(domain);
     const altNames = isIp ? [{ type: 7, value: domain }] : [{ type: 2, value: domain }];
     const pems = await selfsigned.generate([{ name: 'commonName', value: domain }], {
       days, keySize: 2048, algorithm: 'sha256',
       extensions: [
         { name: 'basicConstraints', cA: false },
         { name: 'keyUsage', keyCertSign: false, digitalSignature: true, keyEncipherment: true },
         { name: 'extKeyUsage', serverAuth: true },
         { name: 'subjectAltName', altNames }
       ]
     });
     fs.writeFileSync(path.join(outDir, 'cert.pem'), pems.cert);
     fs.writeFileSync(path.join(outDir, 'key.pem'), pems.private, { mode: 0o600 });
     console.log(`Wrote cert.pem and key.pem for ${domain} (${days} days)`);
   }
   main().catch(e => { console.error(e); process.exit(1); });
   ```

   ```sh
   ~/yunting/node/bin/node ~/yunting/tools/gen-cert.js <对外域名> 3650 ~/yunting
   ```

   这类环境没有标准验证端口，正规证书的常规验证走不通，自签是常态；
   代价是客户端导入时要选「允许不安全证书」。

9. **写三个脚本**（存到 `~/yunting/` 下，`chmod +x ~/yunting/*.sh`；
   占位符不用改，脚本自己读 config.env）：

   `start.sh`——确保实例都在跑，缺谁补谁，只在真正拉起时输出一行：

   ```sh
   #!/bin/sh
   set -u
   DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
   [ -f "$DIR/config.env" ] || exit 0
   UUID=''; DOMAIN=''; TLS_PORT=''; PLAIN_PORT=''
   PLAIN_LINK_HOST=''; PLAIN_LINK_PORT=''; PLAIN_LINK_SECURITY=''; PLAIN_LINK_SNI=''
   . "$DIR/config.env"
   NODE="$DIR/node/bin/node"
   [ -x "$NODE" ] || NODE=$(command -v node)
   mkdir -p "$DIR/run" "$DIR/logs"
   if command -v setsid >/dev/null 2>&1; then LAUNCH=setsid; else LAUNCH=nohup; fi

   pid_alive() { # $1=pid 文件：记录在、进程在、且确实是 app.js 才算活
     [ -f "$1" ] || return 1
     pid=$(cat "$1" 2>/dev/null)
     [ -n "$pid" ] || return 1
     if [ -r "/proc/$pid/cmdline" ]; then
       tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'app\.js'
       return $?
     fi
     kill -0 "$pid" 2>/dev/null
   }

   start_one() { # $1=标签 $2=端口 $3=tls|none
     pf="$DIR/run/$1.pid"
     pid_alive "$pf" && return 0
     cd "$DIR/app" || return 1
     if [ "$3" = tls ]; then
       $LAUNCH env NAME=yunting UUID="$UUID" PORT="$2" DOMAIN="$DOMAIN" \
         LINK_HOST="$DOMAIN" LINK_PORT="$2" LINK_SECURITY=tls LINK_SNI="$DOMAIN" \
         CERT_FILE="$DIR/cert.pem" KEY_FILE="$DIR/key.pem" \
         "$NODE" app.js >> "$DIR/logs/$1.log" 2>&1 </dev/null &
     else
       $LAUNCH env NAME=yunting UUID="$UUID" PORT="$2" DOMAIN="$DOMAIN" \
         LINK_HOST="${PLAIN_LINK_HOST:-$DOMAIN}" LINK_PORT="${PLAIN_LINK_PORT:-$2}" \
         LINK_SECURITY="${PLAIN_LINK_SECURITY:-none}" LINK_SNI="${PLAIN_LINK_SNI:-$DOMAIN}" \
         "$NODE" app.js >> "$DIR/logs/$1.log" 2>&1 </dev/null &
     fi
     echo $! > "$pf"
     printf 'started %s on port %s (pid %s)\n' "$1" "$2" "$!"
   }

   [ -n "$TLS_PORT" ] && start_one tls "$TLS_PORT" tls
   [ -n "$PLAIN_PORT" ] && start_one plain "$PLAIN_PORT" none
   exit 0
   ```

   其中传给 app.js 的环境变量就是它的全部配置入口，逐项含义：
   `UUID` 标识符、`PORT` 本实例监听口、`DOMAIN` 对外地址、
   `LINK_HOST/LINK_PORT/LINK_SECURITY/LINK_SNI` 决定它在 `/<标识符>`
   路径下吐出的链接长什么样（地址、端口、是否加密、SNI），
   `CERT_FILE/KEY_FILE` 两项都给了它才走加密监听、缺了就是明文。
   明文实例的 LINK_* 默认按直连形态生成；config.env 里填了
   PLAIN_LINK_* 时改用那组值（用途见第二节步骤 5），守护补拉与
   停机恢复走的都是同一份配置，参数不会丢。

   `guard.sh`——每 30 秒巡检，掉了补拉，只记拉起事件：

   ```sh
   #!/bin/sh
   set -u
   DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
   mkdir -p "$DIR/run" "$DIR/logs"
   PF="$DIR/run/guard.pid"
   if [ -f "$PF" ]; then
     old=$(cat "$PF" 2>/dev/null)
     [ -n "$old" ] && kill -0 "$old" 2>/dev/null && exit 0  # 已有守护在跑，不重复起
   fi
   echo $$ > "$PF"
   trap 'rm -f "$PF"' 0
   trap 'exit 0' INT TERM
   while true; do
     out=$(sh "$DIR/start.sh" 2>&1)
     [ -n "$out" ] && printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$out" >> "$DIR/logs/guard.log"
     sleep 30 & wait $!  # 用 wait 等 sleep：收到 TERM 能立刻退出，不睡死
   done
   ```

   `stop.sh`——停守护与全部实例，不删任何文件：

   ```sh
   #!/bin/sh
   set -u
   DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
   for tag in guard tls plain; do
     pf="$DIR/run/$tag.pid"
     if [ -f "$pf" ]; then
       pid=$(cat "$pf" 2>/dev/null)
       rm -f "$pf"
       if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
         kill "$pid" 2>/dev/null
         i=0; while [ $i -lt 6 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
         kill -9 "$pid" 2>/dev/null
       fi
     fi
   done
   exit 0
   ```

10. **先手动起实例、自查，再挂守护**（顺序别反：实例没验好就挂守护，
    只会把错误状态反复补拉）：

    ```sh
    sh ~/yunting/start.sh        # 输出 started ... 两行（起了几个实例就几行）
    curl -s http://127.0.0.1:<高位端口乙>/ | head -n 3        # 明文口：应回站点首页 html
    curl -sk https://127.0.0.1:<高位端口甲>/ | head -n 3      # 加密口：同上（-k 是接受自签）
    curl -s http://127.0.0.1:<高位端口乙>/<标识符>             # 应吐出一行 vless:// 链接
    ```

    三条都对了再挂守护（注意：start.sh 只管实例、不带守护，必须单独拉）：

    ```sh
    setsid sh ~/yunting/guard.sh >> ~/yunting/logs/guard.out 2>&1 </dev/null &
    # 没有 setsid 时用：nohup sh ~/yunting/guard.sh >> ~/yunting/logs/guard.out 2>&1 &
    ```

    挂完演练一次：`kill $(cat ~/yunting/run/plain.pid)`，
    等 30–60 秒，看 `logs/guard.log` 是否多了一行补拉记录、
    明文口是否恢复应答。若平台还给了 cron，可再加一层兜底
    （guard.sh 自带防重复，重复调用安全）：
    `* * * * * sh ~/yunting/guard.sh >/dev/null 2>&1`。

11. **从另一台机器做真实连接测试**：用上一步 `/<标识符>` 吐出的链接导入客户端，
    能打开页面不算数，要以客户端实际连通为准；自签链路记得选「允许不安全证书」。

12. **备份命根子**：把 `config.env`、`cert.pem`、`key.pem` 三件拷到机器外保存。
    机器没了，照这三件重装，客户端链接一条都不用改。

### 易踩的坑（注意啥）

- **进程上限**：双实例加守护就是三个常驻进程，先数清楚平台给的上限再决定起几个实例；
  上限只够两个时，砍掉一个实例（只起明文或只起加密），不要砍守护。
- **平台回收进程**：这类平台可能不定期清掉后台进程，守护也可能被一起清掉。
  对策是再在机器外放一个定时检查：从外面登录进来探活，缺谁补谁
  （命令就是 `ssh <账号>@<主机> 'sh ~/yunting/start.sh'` 再加一步补守护）；
  探活只认「登录进来在本机查」的结果，不要拿公网能不能打开当故障依据
  （中间网络抖动会造成假报警）。
- **陈旧的进程记录**：守护或实例异常退出后，run/ 里可能留着旧 pid；
  若这个 pid 恰好被别的程序复用，pid 判断会误判「已经在跑」而什么都不做。
  手动恢复时先删记录再拉：`rm -f ~/yunting/run/*.pid` 后跑 start.sh 与守护。
- **不要用文件锁做守护互斥**：残锁会把恢复流程整个挡死；用进程记录文件判断即可。
- **守护与实例要分开拉**：手动恢复时最容易漏掉守护这一步——实例拉起来了，
  没人看着，下次掉了就再也起不来。恢复顺序永远是：先 start.sh、再单独拉 guard.sh。
- **顺序错了的后果**：依赖没装好就起实例，app.js 会在运行时现装包，
  慢且可能被进程上限卡死；证书没生成就起加密实例，实例直接报错退出，
  看 `logs/tls.log` 第一行就知道。

---

## 二、某些游戏托管型沙盒平台

这类环境的特征：平台本是给游戏服务器用的，顺带能跑任意应用；
控制台在网页上，启停都要在控制台操作；整机被平台停掉后不会自己恢复；
没有 systemd，也没有定时任务；端口不是自己挑的。

**在哪用**：两个地方来回切换——网页控制台（建应用、买端口、绑平台域名、
看状态、点启动）和应用环境的 shell（控制台给出 SSH 入口，登录进去之后
装法与第一节同构，应用目录建在登录账号的主目录下，下文以 `~/yunting/` 为例）。

### 前置条件（用啥）

- 平台账号已开通应用额度（这类平台通常限制每个账号能建的应用数量）。
- 已拿到平台分配的端口：这类平台的端口往往要单独购买或开通槽位
  （一次性买断居多），系统随机分配外部端口、没有内外映射这一层——
  分到哪个口，程序就直接监听哪个口。至少买两个：加密、明文各一。
- 手里有能登录该应用环境的密钥或凭据（控制台会给 SSH 的地址、端口与登录方式）。
- 本地先备好 Node 运行时 `.tar.gz` 包：这类环境通常连下载工具都很精简，
  运行时靠从外面送进去（包格式挑 `.tar.gz`，理由见第一节前置条件）。

### 关键步骤顺序（怎么用）

1. **控制台建应用**：进控制台 → 应用列表 → 新建应用 →
   选通用 Linux 系统镜像那类（不是某个具体游戏的模板）→
   名字填 `<应用名>` → 创建。建好后记下应用的节点地址
   （SSH 命令一般在应用详情页直接给出，形如
   `ssh <用户>@<应用节点地址> -p <SSH端口>`）。

2. **开端口槽位**：应用详情页 → 网络／端口一栏 → 购买或添加端口槽位 ×2 →
   系统随机分配，把两个端口号记准：`<高位端口甲>` 给加密实例、
   `<高位端口乙>` 给明文实例。槽位增减之后第一件事永远是回来核对这份清单。

3. **把运行时送进去**：先在自己电脑上下载运行时包
   （地址与版本查法见第一节步骤 4，架构先在沙盒里 `uname -m` 确认），
   再用 scp 送进应用主目录——注意 `-P` 后面跟的是 **SSH 端口**，
   不是刚买的应用端口，填错了连不上：

   ```sh
   scp -P <SSH端口> node-v22.23.5-linux-x64.tar.gz <用户>@<应用节点地址>:~/
   ```

   平台带网页文件管理时，用它上传到主目录效果一样。

4. **登录进去装机**：SSH 登录后，流程与第一节步骤 2–10 相同，逐项对应：
   建 `~/yunting/` 目录（布局同第一节的示例树）→ 程序文件放 `app/`
   （仓库能直连就 clone，不能就照第 3 步的方式把文件包送进来）→
   运行时解压到 `node/`：`tar -xzf ~/node-v22.23.5-linux-x64.tar.gz -C ~/yunting/node --strip-components 1` →
   装依赖 → 生成标识符 → 写 `config.env`（TLS_PORT 与 PLAIN_PORT
   填第 2 步买到的两个端口，其余字段同第一节步骤 7）→ 生成自签证书 →
   写 start.sh／guard.sh／stop.sh（全文同第一节步骤 9）→
   先 `sh ~/yunting/start.sh` 起实例、本机 curl 自查，再单独 setsid 拉守护。
   两个沙盒特有的变通：
   - 机内出站到不了 npm 时，在自己电脑上把 `node_modules/` 预装好，
     连同程序文件一起打包送进来解开（ws 是纯 JS 包，不挑架构；
     但运行时包必须与沙盒架构一致，以 `uname -m` 为准）。
   - 机内没有 openssl 是常态，证书直接走第一节步骤 8 的纯 JS 路线。

5. **绑平台域名，解决「网址带端口很难用」**：控制台 → 应用 →
   网络／域名一栏 → 添加域名 → 类型选 **HTTPS**（平台终结加密那种）→
   目标端口选 `<高位端口乙>`（明文实例）→ 保存，平台会给一个子域名，
   记作 `<平台子域名>`。原理是平台边缘在标准 443 上替你终结加密、
   配上正规证书，再在内网把流量转给你的明文口。
   然后让明文实例改吐这条链的链接。不要手工拼启动命令——把链接参数
   写进 `~/yunting/config.env` 里预留的 PLAIN_LINK_* 四项（见第一节步骤 7），
   start.sh 拉起明文实例时就会改用这组值，守护补拉、停机恢复之后也不会变回去：

   ```ini
   PLAIN_LINK_HOST=<平台子域名>
   PLAIN_LINK_PORT=443
   PLAIN_LINK_SECURITY=tls
   PLAIN_LINK_SNI=<平台子域名>
   ```

   改完重启明文实例让新参数生效（守护在跑时也可以什么都不做，
   等它 30 秒内补拉）：

   ```sh
   kill $(cat ~/yunting/run/plain.pid) 2>/dev/null
   sh ~/yunting/start.sh
   curl -s http://127.0.0.1:<高位端口乙>/<标识符>   # 应吐出 443 端口、tls 形态的链接
   ```

   这样这个实例在 `/<标识符>` 吐出的就是免端口、真证书的链接，
   客户端「允许不安全证书」选否。代价要先想清：这个实例就不再吐
   明文直连链接了——两条链都想要，就再买一个端口槽、多起一个实例
   专走平台域名（多占一个端口和一个进程）。与自签直连的加密链
   并行存在、互不影响。

6. **把「平台会停机」当常态做预案**：整机停掉后，应用环境里的一切
   都不会自启。恢复顺序固定四步，顺序错了白忙：
   1. 去控制台看应用状态——确认是「已停止」才点 **启动**，只点一次，
      然后等它排队起来（状态变运行中之前反复点没有用）。
   2. 状态变运行中后，SSH 登录进去。
   3. 先补实例：`sh ~/yunting/start.sh`。
   4. 再补守护：先删陈旧记录 `rm -f ~/yunting/run/guard.pid`，
      再 `setsid sh ~/yunting/guard.sh >> ~/yunting/logs/guard.out 2>&1 </dev/null &`。
   最后 curl 两个口与 `/<标识符>` 复查一遍才算恢复完。

7. **在机器外放一个定时检查**：找一台常开的机器，先在沙盒里放一个
   恢复脚本 `~/yunting/recover.sh`（补实例＋补守护合一）：

   ```sh
   #!/bin/sh
   sh ~/yunting/start.sh
   PF=~/yunting/run/guard.pid
   if [ ! -f "$PF" ] || ! kill -0 "$(cat "$PF" 2>/dev/null)" 2>/dev/null; then
     rm -f "$PF"
     setsid sh ~/yunting/guard.sh >> ~/yunting/logs/guard.out 2>&1 </dev/null &
   fi
   ```

   外部机器的 crontab 加一行（每 30 分钟登录进来跑一次恢复脚本）：

   ```text
   */30 * * * * ssh -p <SSH端口> <用户>@<应用节点地址> 'sh ~/yunting/recover.sh' >> ~/yunting-watchdog.log 2>&1
   ```

   SSH 登录不进去时不要反复重试轰炸：先去控制台看状态，
   确认整机被停了才按第 6 步点启动，起来后再让定时检查接手补拉。

### 易踩的坑（注意啥）

- **停机不自恢复**：这是这类平台最容易误判的一点——服务「昨天还好好的」，
  很可能只是整机被平台停了，不是程序坏了。先看控制台状态，再谈修程序。
- **端口是买来的、随机的**：任何文档、链接、配置里写死的端口，
  都要以控制台当前显示的分配为准；槽位增减后第一件事是核对端口清单。
- **scp 的端口别填错**：送文件用的是 SSH 端口，与应用端口是两回事，
  这是第 3 步最常见的连不上原因。
- **平台域名的类型别选错**：要选「平台终结加密」的那种类型并指向明文口；
  指向加密口或选成透传类型，要么打不开、要么白白绕回自签慢路径。
- **加密直连在某些线路上明显慢**：这类环境里加密实例自己终结加密时，
  个别跨网线路速度会掉得很厉害；日常优先走平台域名那条（平台终结加密）或明文链，
  自签直连留作备用。这个现象与机器性能无关，别在机器上瞎找原因。
- **控制台入口只认官方地址直达**：不要通过搜索引擎找控制台入口，
  仿冒与过期入口都有风险。

---

## 三、某些 Web 面板主机

这类环境的特征：面向网站与 Web 应用的托管面板，部署方式是
「连一个 Git 仓库，平台自动拉代码构建并运行」；没有传统的登录式 shell 运维，
配置靠环境变量传；平台自带正规证书与域名体系。

**在哪用**：两个网站来回操作——代码仓库站（建仓、放文件）和面板站
（新建服务、环境变量、域名、日志四个页面）；本地只需要 git 和浏览器，
没有 shell 步骤，装机动作全部由平台构建完成。

### 前置条件（用啥）

- 一个代码仓库账号，仓库里放着这套服务的源码与构建说明（文件清单见步骤 1），
  平台能读取它（私有仓库需先授权平台访问）。
- 已选好套餐档位：免费档通常给一个很小的计算规格，够跑这套服务；
  部分平台建服务前要求先绑定支付方式做验证，哪怕走免费额度也一样。
- 想清楚配置怎么传：标识符、对外形态等都通过面板里的环境变量下发（步骤 4 逐项列），
  不要把真实配置写死进仓库——仓库里不放 config.env、不放证书与私钥。

### 关键步骤顺序（怎么用）

1. **建仓放文件**：仓库根目录就放这些，多一层目录平台就找不到构建文件：

   ```text
   <仓库根>/
   ├── Dockerfile        构建说明（步骤 2 给全文）
   ├── app.js            入口，服务本体
   ├── package.json      依赖清单（只依赖 ws@8.18.3）
   ├── index.html  game.html  about.html  poems.html
   └── poems/            五个词页 html（子目录原样放）
   ```

   本地推上去就是一组普通 git 操作：

   ```sh
   git init && git add -A && git commit -m "init" && git remote add origin <你的仓库地址> && git push -u origin main
   ```

2. **写 Dockerfile**（放仓库根目录，文件名就叫 `Dockerfile`，无后缀），
   直接用本仓 `yunting/` 目录里这份，全文如下：

   ```dockerfile
   FROM node:22-alpine
   WORKDIR /app
   COPY package.json ./
   RUN npm install --omit=dev
   COPY app.js game.html index.html about.html poems.html ./
   COPY poems/ ./poems/
   ENV PORT=3000
   EXPOSE 3000
   CMD ["node", "app.js"]
   ```

   逐行在干什么：
   - `FROM node:22-alpine`：基础镜像自带 Node 22 运行时，不用自己装。
   - `WORKDIR /app`：容器内的工作目录，**在哪用**的答案——程序最后跑在 `/app` 里。
   - `COPY package.json ./` + `RUN npm install --omit=dev`：先只拷清单装依赖
     （锁版本，只装 ws），这一步单独在前是为了用构建缓存，改页面不会重装依赖。
   - `COPY app.js ... ./`：程序与页面文件拷进镜像；
     `COPY poems/ ./poems/` 必须单独一行（原因见易踩的坑的「路径摊平」）。
   - `ENV PORT=3000`：只是本地默认值——平台运行时会注入自己的 PORT 覆盖它
     （见步骤 4），这个数不用改。
   - `CMD ["node", "app.js"]`：启动命令，即用运行时跑入口文件。

3. **在面板里新建服务**：面板 → 新建（New）→ Web 服务 →
   关联仓库（列表里选步骤 1 的仓，私有仓先走授权）→ 逐个字段填：
   - **名称（Name）**：填 `<服务名>`——先想好再建，多数平台建后没有改名入口。
   - **区域（Region）**：选离目标用户较近的区域。
   - **套餐／规格（Plan / Instance）**：选最低够用档；免费档先确认是否常驻不休眠。
   - **构建方式（Build Method）**：选 Docker——面板会自动识别根目录的
     Dockerfile，构建上下文就是仓库根，不用再填构建命令与启动命令。
   填完点创建，面板会先拉代码构建一次；环境变量还没填，这一次构建完
   服务多半起不来（原因见步骤 4 的提醒），先别急着排障。

4. **填环境变量**：服务页 → 设置（Settings）→ 环境变量（Environment）→
   逐行添加（Key 填左列、Value 填右列），保存后平台会自动重新部署：

   | Key | Value 填什么 | 说明 |
   |---|---|---|
   | `UUID` | `<标识符>` | **必填**。与你其他部署共用同一个也行，方便链接统一；自己生成（`cat /proc/sys/kernel/random/uuid` 或任意 UUID 生成器） |
   | `PORT` | 不填 | 平台自动注入监听端口并覆盖 Dockerfile 里的 3000，手填反而会和平台分配冲突 |
   | `DOMAIN` | `<平台默认域名>` | **必填**。先填平台给这个服务的默认域名；绑了自有域名后回来改成自有域名 |
   | `LINK_HOST` | 可省 | 链接里的地址，缺省就等于 DOMAIN |
   | `LINK_PORT` | `443` | 对外走平台终结加密，链接端口固定 443 |
   | `LINK_SECURITY` | `tls` | 链接形态选加密（证书由平台终结、是正规证书） |
   | `LINK_SNI` / `LINK_WSHOST` | 可省 | 缺省都等于 LINK_HOST，一般不用填 |
   | `NAME` | `<标签>`（可选） | 只是链接里的备注名；注意它含 `server` 或 `hostypanel` 字样时，`/<标识符>` 会额外多吐一组优选地址的链接，不要这个行为就避开这两个词 |
   | `CERT_FILE` / `KEY_FILE` | 不填 | 平台在边缘终结加密，应用在容器内只跑明文 HTTP；填了反而会让它去找不存在的证书文件 |

   提醒：`UUID`、`DOMAIN` 是 app.js 启动时一定要读到的
   （`PORT` 由平台注入、不用操心），
   面板环境没有交互输入——`UUID` 或 `DOMAIN` 漏填，进程会卡在
   「等待输入」不动，日志页会停在类似「请输入 DOMAIN」的字样上，
   这不是平台故障，补上变量重新部署即可。

5. **看日志验部署**：服务页 → 日志（Logs）→ 等构建与启动日志刷完，
   看到 `HTTP Server is running on port <平台注入的端口>` 这一行才算进程起来；
   然后打开平台默认域名：根页面能开、访问 `/<标识符>` 能吐出一行
   vless:// 链接，部署成功一半。

6. **从外部机器做真实连接测试**：把上一步的链接导入客户端实测连通
   （标准同前：以实际连通为准）；这条链证书正规，
   客户端问「是否允许不安全证书」时选**否**。

7. **绑自有域名**：两个地方各做一步——
   域名服务商（或 CDN）的解析页：添加一条别名（CNAME）记录，
   主机记录填 `<子域名前缀>`、记录值填 `<平台默认域名>`，
   若解析在 CDN 处管理，把这条记录开代理（黄云）；
   面板侧：服务页 → 域名（Domains / Custom Domains）→ 添加自有域名 →
   填同一个域名保存，平台自动签发正规证书，等状态变生效后，
   回步骤 4 把 `DOMAIN` 改成自有域名触发重新部署，
   再用自有域名复验一次页面与连通性。

8. **留意费用结构**：这类平台免费额度通常是「每月送一笔资源额度」，
   计算与出站流量分开计价。先在面板的账单（Billing）页给账户设一个
   消费上限，再在外部放一个定期查账的小任务（如每周看一次用量页），
   超预期就处理，别等账单出来才发现。

### 易踩的坑（注意啥）

- **服务名与仓库名一旦建了不好改**：有些平台的服务标识创建后没有改名入口，
  名字先想好再建；实在改不了也别为改名重建服务，地址与链接不受影响就行。
- **文件复制的路径摊平问题**：Dockerfile 里把多个文件写在同一行复制时，
  子目录里的内容可能被摊平到根目录，导致子目录页面全部打不开；
  `poems/` 必须像步骤 2 那样单独写一行 `COPY poems/ ./poems/`。
- **漏填变量卡死**：`UUID`/`DOMAIN` 没填，进程卡在等待输入（见步骤 4 提醒）；
  排障先看日志停在哪一行，别先怀疑平台。
- **免费档会休眠的平台要分清**：有些平台免费档长时间没流量就休眠，
  唤醒要等几十秒，不适合当常驻节点；选型时先确认免费档是否常驻不休眠。
- **账单状态字样不等于已绑卡**：面板里显示「支付方式有效」之类的字样，
  不代表支付方式已经绑定成功；以实际走完验证流程为准，别看着状态字样就下结论。
- **证书走平台终结**：这类平台给的都是正规可验证证书，
  客户端问「是否允许不安全证书」时要选否——和自签链路正好相反，混了就连不上。

---

## 附：客户端导入参数（纯客户端视角）

节点链接导入客户端之后，逐项核对的意义如下（值从你自己的配置里抄，这里只讲每一项是什么）：

- **地址与端口**：对外地址（域名或公网地址）加实例端口。
  地址是 IPv6 时，链接里要写成 `[地址]:端口` 的形式（方括号把地址和端口隔开），
  少了方括号客户端会解析错。走平台终结加密的那条链，地址是平台域名、
  端口是标准加密端口，不带自分配的高位端口。
- **标识符（UUID）**：与服务端配置里的标识符逐字一致；错一位就连不上，且服务端那边不会报错提示。
- **传输方式与路径**：传输选 WebSocket 一类，路径填链接里给出的那段，不要自己改。
- **伪装域名（Host）与 SNI**：一般与对外域名相同；经 CDN 代理的链路按链接里给的值填，
  不要自作主张换成源站地址。
- **加密（TLS）开关**：加密实例要开，明文实例要关，开错直接连不上。
- **允许不安全证书**：只在证书是自签时选「是」；平台终结加密、证书正规可验证时选「否」。
  这项选反是最常见的连不上原因之一。
- **指纹（fingerprint）**：链接里带了就照填（常见如 chrome），没带就留默认。

---

## 通用收尾检查（任何一类装完都过一遍）

- 配置与证书已在机器外留副本，机器没了能照原样恢复。
- 页面能开 ≠ 能用，必须以真实客户端连通测试为准。
- 守护在跑，且确认过「杀掉一个实例后能被自动补拉」。
- 若平台会停机/回收：外部定时检查已就位，且演练过一次完整的恢复顺序
  （先起机器、再补实例、最后补守护）。
- 往外发链接、截图或日志求助时，先把自己的真实标识符、端口、地址遮掉再发。
