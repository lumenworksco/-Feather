#!/usr/bin/env python3
"""Real-key WebAuthn test. Serves a page on http://localhost:8766 that registers a credential on the YubiKey and signs in with it,
and verifies both results with Yubico's python-fido2 (an implementation independent from Feather's):
origin, challenge, rpIdHash, flags and signature. Needs the key plugged in and two touches.

  python3 -m venv /tmp/fidoenv && /tmp/fidoenv/bin/pip install fido2
  /tmp/fidoenv/bin/python tests/webauthn-test.py [--uv]      # then Feather opens http://localhost:8766/ (the script launches it)
"""
import json, os, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from fido2.server import Fido2Server
from fido2.webauthn import PublicKeyCredentialRpEntity, PublicKeyCredentialUserEntity

UV = "required" if "--uv" in sys.argv else "discouraged"
PORT = 8766
ORIGIN = f"http://localhost:{PORT}"
server = Fido2Server(PublicKeyCredentialRpEntity(id="localhost", name="Feather test"), verify_origin=lambda o: o == ORIGIN)
state, credentials, results = {}, [], {}
done = threading.Event()

PAGE = """<!doctype html><title>webauthn test</title><body style="font:16px system-ui;padding:2em"><h3 id=s>starting</h3><pre id=log></pre>
<script>
const log = m => { document.getElementById('log').textContent += m + "\\n"; };
async function post(path, body) { const r = await fetch(path, {method: 'POST', body: JSON.stringify(body || {})}); return r.json(); }
(async () => {
  try {
    const UV = %UV%;
    let o = (await post('/begin-register')).publicKey; o.challenge = fromB64(o.challenge); o.user.id = fromB64(o.user.id);
    o.authenticatorSelection = Object.assign({}, o.authenticatorSelection, {userVerification: UV});
    document.title = 'webauthn: touch 1 (register)'; document.getElementById('s').textContent = 'Touch the key to REGISTER';
    while (!document.hasFocus()) await new Promise(r => setTimeout(r, 300));
    const cred = await navigator.credentials.create({publicKey: o});
    log('registered; instanceof PublicKeyCredential=' + (cred instanceof PublicKeyCredential) + ' transports=' + cred.response.getTransports());
    log('register verdict: ' + JSON.stringify(await post('/finish-register', cred.toJSON())));
    let a = (await post('/begin-auth')).publicKey; a.challenge = fromB64(a.challenge); a.allowCredentials.forEach(c => c.id = fromB64(c.id));
    a.userVerification = UV;
    document.title = 'webauthn: touch 2 (sign in)'; document.getElementById('s').textContent = 'Touch the key to SIGN IN';
    const as = await navigator.credentials.get({publicKey: a});
    log('signed in; userHandle=' + as.response.userHandle + ' ext=' + JSON.stringify(as.getClientExtensionResults()));
    log('auth verdict: ' + JSON.stringify(await post('/finish-auth', as.toJSON())));
    document.title = 'webauthn: finished'; document.getElementById('s').textContent = 'Finished';
  } catch (e) { log('ERROR ' + e.name + ': ' + e.message); document.title = 'webauthn: error ' + e.name; await post('/error', {name: e.name, message: e.message}); }
})();
function fromB64(s) { s = s.replace(/-/g,'+').replace(/_/g,'/'); while (s.length %% 4) s += '='; return Uint8Array.from(atob(s), c => c.charCodeAt(0)); }
</script>"""

def jsonable(x):
    return json.loads(json.dumps(dict(x), default=lambda b: __import__('base64').urlsafe_b64encode(bytes(b)).rstrip(b'=').decode()))

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, obj, code=200):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(PAGE.replace('%UV%', json.dumps(UV)).replace('%%', '%').encode())
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        try:
            if self.path == '/begin-register':
                opts, state['reg'] = server.register_begin(PublicKeyCredentialUserEntity(id=b'\x01\x02\x03\x04', name='tester', display_name='Tester'), user_verification=UV)
                self.reply(jsonable(opts))
            elif self.path == '/finish-register':
                auth = server.register_complete(state['reg'], body)
                credentials.append(auth.credential_data); results['register'] = 'VERIFIED (origin, challenge, rpIdHash, flags)'
                self.reply({'ok': True})
            elif self.path == '/begin-auth':
                opts, state['auth'] = server.authenticate_begin(credentials, user_verification=UV)
                self.reply(jsonable(opts))
            elif self.path == '/finish-auth':
                server.authenticate_complete(state['auth'], credentials, body); results['sign-in'] = 'VERIFIED (origin, challenge, rpIdHash, flags, signature)'
                self.reply({'ok': True}); done.set()
            elif self.path == '/error':
                results['error'] = body; self.reply({}); done.set()
        except Exception as e:
            results[self.path] = f'REJECTED by python-fido2: {type(e).__name__}: {e}'; self.reply({'ok': False, 'error': str(e)}); done.set()

httpd = HTTPServer(('127.0.0.1', PORT), H)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
app = os.environ.get('FEATHER_APP', 'build/Build/Products/Debug/Feather.app')
subprocess.Popen(['open', '-n', app, '--args', '--fresh', f'--open={ORIGIN}/'])
# Security-key requests are only accepted from the page in front, so bring this test copy to the front (as a user's click would).
def front():
    for _ in range(20):
        time.sleep(0.5)
        pid = subprocess.run(['pgrep', '-f', 'Debug/Feather.app/Contents/MacOS/Feather'], capture_output=True, text=True).stdout.split()
        if pid:
            subprocess.run(['osascript', '-e', f'tell application "System Events" to set frontmost of (first process whose unix id is {pid[0]}) to true'], capture_output=True)
            return
threading.Thread(target=front, daemon=True).start()
print(f'Feather opened {ORIGIN}/ , uv={UV}. Touch the key when it blinks (twice)...', flush=True)
done.wait(timeout=150)
time.sleep(1)
print(json.dumps(results, indent=1) if results else 'NO RESULT (timed out)')
subprocess.run(['pkill', '-9', '-f', 'Debug/Feather.app/Contents/MacOS/Feather'])
sys.exit(0 if results.get('register') and results.get('sign-in') else 1)
