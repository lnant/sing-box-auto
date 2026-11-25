const os = require('os');
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const net = require('net');
const { exec, execSync } = require('child_process');
function ensureModule(name) {
    try {
        require.resolve(name);
    } catch (e) {
        console.log(`Module '${name}' not found. Installing...`);
        execSync(`npm install ${name}`, { stdio: 'inherit' });
    }
}
ensureModule('ws');
const { WebSocket, createWebSocketStream } = require('ws');
const NAME = process.env.NAME || os.hostname();
async function getVariableValue(variableName, defaultValue) {
    const envValue = process.env[variableName];
    if (envValue) {
        return envValue; 
    }
    if (defaultValue) {
        return defaultValue; 
    }
  let input = '';
  while (!input) {
    input = await ask(`请输入${variableName}: `);
    if (!input) {
      console.log(`${variableName}不能为空，请重新输入!`);
    }
  }
  return input;
}
function ask(question) {
    const rl = require('readline').createInterface({ input: process.stdin, output: process.stdout });
    return new Promise(resolve => rl.question(question, ans => { rl.close(); resolve(ans.trim()); }));
}
async function main() {
    const UUID = await getVariableValue('UUID', '');

    const PORT = await getVariableValue('PORT', '');

    const DOMAIN = await getVariableValue('DOMAIN', '');

    const LINK_HOST = process.env.LINK_HOST || DOMAIN;
    const LINK_PORT = process.env.LINK_PORT || '443';
    const LINK_SECURITY = process.env.LINK_SECURITY || 'tls';
    const LINK_SNI = process.env.LINK_SNI || LINK_HOST;
    const LINK_WSHOST = process.env.LINK_WSHOST || LINK_HOST;
    function buildLink(addr) {
        const sec = LINK_SECURITY === 'tls' ? `security=tls&sni=${LINK_SNI}&fp=chrome` : 'security=none';
        return `vless://${UUID}@${addr}:${LINK_PORT}?encryption=none&${sec}&type=ws&host=${LINK_WSHOST}&path=%2F#Vl-ws-${LINK_SECURITY}-${NAME}`;
    }
    const CERT_FILE = process.env.CERT_FILE || '';
    const KEY_FILE = process.env.KEY_FILE || '';

    // 静态页面白名单：只有这些路径按 HTML 文件输出，其余一律 404，不做目录遍历。
    const PAGES = new Set(['/about.html', '/poems.html',
        '/poems/shuidiaogetou.html', '/poems/shengshengman.html', '/poems/qingyuan.html',
        '/poems/yinjiu.html', '/poems/denggao.html']);
    // 读文件并输出；文件不存在返回 false，调用方自行决定回落或 404。
    const serveFile = (res, file) => {
        try {
            const body = fs.readFileSync(path.join(__dirname, file));
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end(body);
            return true;
        } catch { return false; }
    };

    const requestHandler = (req, res) => {
        const u = decodeURIComponent(req.url.split('?')[0]);
        if (u === '/') {
            // 新站首页 index.html；旧包（无该文件）仍回落到 game.html，装机流程不受影响
            if (!serveFile(res, 'index.html')) serveFile(res, 'game.html');
        } else if (PAGES.has(u)) {
            if (!serveFile(res, u.slice(1))) {
                res.writeHead(404, { 'Content-Type': 'text/plain' });
                res.end('Not Found\n');
            }
        } else if (u === `/${UUID}`) {
            let vlessURL;
            if (NAME.includes('server') || NAME.includes('hostypanel')) {
                vlessURL = [LINK_HOST, '104.16.0.0', '104.17.0.0', '104.18.0.0', '104.19.0.0', '104.20.0.0', '104.21.0.0', '104.22.0.0', '104.24.0.0', '104.25.0.0', '104.26.0.0', '104.27.0.0', '[2606:4700::]', '[2400:cb00:2049::]'].map(a => buildLink(a)).join('\n');
            } else {
                vlessURL = buildLink(LINK_HOST);
            }
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end(vlessURL + '\n');
        } else {
            res.writeHead(404, { 'Content-Type': 'text/plain' });
            res.end('Not Found\n');
        }
    };

    const httpServer = (CERT_FILE && KEY_FILE)
        ? https.createServer({ cert: fs.readFileSync(CERT_FILE), key: fs.readFileSync(KEY_FILE) }, requestHandler)
        : http.createServer(requestHandler);

    httpServer.listen(PORT, () => {
        console.log(`${CERT_FILE && KEY_FILE ? 'HTTPS' : 'HTTP'} Server is running on port ${PORT}`);
    });

    const wss = new WebSocket.Server({ server: httpServer });
    const uuid = UUID.replace(/-/g, "");
    wss.on('connection', ws => {
        let buf = Buffer.alloc(0);
        let settled = false;
        const fail = () => {
            if (settled) return;
            settled = true;
            try { ws.close(); } catch (e) { }
        };
        const tryParseHeader = () => {
            if (buf.length < 18) return null;
            const version = buf[0];
            for (let k = 0; k < 16; k++) {
                if (buf[1 + k] != parseInt(uuid.substr(k * 2, 2), 16)) return -1;
            }
            let i = 18 + buf[17];
            if (buf.length < i + 4) return null;
            if (buf[i] !== 1) return -1;
            const port = buf.readUInt16BE(i + 1);
            const atyp = buf[i + 3];
            i += 4;
            let host;
            if (atyp === 1) {
                if (buf.length < i + 4) return null;
                host = buf.slice(i, i + 4).join('.');
                i += 4;
            } else if (atyp === 2) {
                if (buf.length < i + 1) return null;
                const len = buf[i];
                if (len === 0 || buf.length < i + 1 + len) return null;
                host = new TextDecoder().decode(buf.slice(i + 1, i + 1 + len));
                i += 1 + len;
            } else if (atyp === 3) {
                if (buf.length < i + 16) return null;
                const parts = [];
                for (let k = 0; k < 16; k += 2) parts.push(buf.readUInt16BE(i + k).toString(16));
                host = parts.join(':');
                i += 16;
            } else {
                return -1;
            }
            if (!host) return -1;
            return { version, host, port, rest: buf.slice(i) };
        };
        const onMessage = msg => {
            try {
                if (settled) return;
                if (!Buffer.isBuffer(msg)) msg = Buffer.from(msg);
                buf = buf.length ? Buffer.concat([buf, msg]) : msg;
                if (buf.length > 4096) return fail();
                const parsed = tryParseHeader();
                if (parsed === null) return;
                if (parsed === -1) return fail();
                settled = true;
                ws.removeListener('message', onMessage);
                ws.send(new Uint8Array([parsed.version, 0]));
                const duplex = createWebSocketStream(ws);
                net.connect({ host: parsed.host, port: parsed.port }, function () {
                    if (parsed.rest.length) this.write(parsed.rest);
                    duplex.on('error', () => { }).pipe(this).on('error', () => { }).pipe(duplex);
                }).on('error', () => { });
            } catch (e) {
                fail();
            }
        };
        ws.on('message', onMessage).on('error', () => { });
    });
}
main();
