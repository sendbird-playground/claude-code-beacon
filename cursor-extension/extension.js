const vscode = require('vscode');
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');

const REGISTRY_DIR = path.join(os.homedir(), '.beacon-ide');
const REGISTRY_FILE = path.join(REGISTRY_DIR, 'registry.json');

// Unique ID for this window instance
const WINDOW_ID = `window-${process.pid}-${Date.now()}`;

let server;
let serverPort;
let registrationInterval;

/**
 * Detect which IDE is running (Cursor, VS Code, etc.)
 */
function detectAppName() {
    const appName = vscode.env.appName || '';
    if (appName.toLowerCase().includes('cursor')) return 'Cursor';
    if (appName.toLowerCase().includes('code')) return 'Visual Studio Code';
    return appName || 'Unknown';
}

function activate(context) {
    server = http.createServer((req, res) => {
        handleRequest(req, res).catch(err => {
            console.error('Beacon: request error:', err);
            res.writeHead(500);
            res.end(err.message);
        });
    });

    server.listen(0, '127.0.0.1', () => {
        serverPort = server.address().port;
        const appName = detectAppName();
        console.log(`Beacon Terminal Navigator: app=${appName} window=${WINDOW_ID} port=${serverPort}`);
        registerInstance();
    });

    // Re-register periodically (cleans stale entries) and on terminal changes
    registrationInterval = setInterval(registerInstance, 30000);

    context.subscriptions.push(
        vscode.window.onDidOpenTerminal(() => setTimeout(registerInstance, 500)),
        vscode.window.onDidCloseTerminal(() => setTimeout(registerInstance, 500))
    );

    context.subscriptions.push({
        dispose: () => {
            clearInterval(registrationInterval);
            unregisterInstance();
            if (server) server.close();
        }
    });
}

async function handleRequest(req, res) {
    if (req.method === 'GET' && req.url === '/health') {
        res.writeHead(200);
        res.end('ok');
        return;
    }

    if (req.method === 'GET' && req.url === '/info') {
        const info = await getWindowInfo();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(info));
        return;
    }

    if (req.method === 'POST' && req.url === '/focus') {
        let body = '';
        req.on('data', chunk => (body += chunk));
        req.on('end', async () => {
            try {
                // Focus terminal panel — this also brings the window to front
                await vscode.commands.executeCommand('workbench.action.terminal.focus');
                res.writeHead(200);
                res.end('ok');
            } catch (err) {
                res.writeHead(500);
                res.end(err.message);
            }
        });
        return;
    }

    res.writeHead(404);
    res.end('not found');
}

async function getWindowInfo() {
    const workspaceFolders =
        vscode.workspace.workspaceFolders?.map(f => f.uri.fsPath) || [];

    // Collect terminal shell PIDs
    const terminalPids = [];
    for (const terminal of vscode.window.terminals) {
        try {
            const pid = await terminal.processId;
            if (pid) terminalPids.push(pid);
        } catch {}
    }

    return {
        windowId: WINDOW_ID,
        appName: detectAppName(),
        port: serverPort,
        pid: process.pid,
        workspaceFolders,
        terminalCount: vscode.window.terminals.length,
        terminalPids
    };
}

async function registerInstance() {
    if (!serverPort) return;

    let registry = [];
    try {
        fs.mkdirSync(REGISTRY_DIR, { recursive: true });
        if (fs.existsSync(REGISTRY_FILE)) {
            const content = fs.readFileSync(REGISTRY_FILE, 'utf8');
            registry = JSON.parse(content);
        }
    } catch {}

    // Remove our old entry
    registry = registry.filter(e => e.pid !== process.pid);

    // Remove stale entries (process no longer alive)
    registry = registry.filter(entry => {
        try {
            process.kill(entry.pid, 0);
            return true;
        } catch {
            return false;
        }
    });

    // Add our current entry
    const info = await getWindowInfo();
    registry.push(info);

    try {
        fs.writeFileSync(REGISTRY_FILE, JSON.stringify(registry, null, 2));
    } catch (err) {
        console.error('Beacon: failed to write registry:', err);
    }
}

function unregisterInstance() {
    try {
        if (fs.existsSync(REGISTRY_FILE)) {
            let registry = JSON.parse(fs.readFileSync(REGISTRY_FILE, 'utf8'));
            registry = registry.filter(e => e.pid !== process.pid);
            fs.writeFileSync(REGISTRY_FILE, JSON.stringify(registry, null, 2));
        }
    } catch {}
}

function deactivate() {
    clearInterval(registrationInterval);
    unregisterInstance();
    if (server) server.close();
}

module.exports = { activate, deactivate };
