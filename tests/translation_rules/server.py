"""Loopback-only fake SSE. No production endpoint, account or meeting data."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, sys, time
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        chunk=body['chunk']; previous=body.get('previous','')
        assert len(chunk.encode('utf-16-le'))//2 <= 160
        assert len(previous.encode('utf-16-le'))//2 <= 160
        if chunk == 'SLOW': time.sleep(0.4)
        text = previous+'|'+chunk
        events=[{'choices':[{'delta':{'content':text}}]}]
        if chunk!='DROP': events.append({'choices':[{'delta':{},'finish_reason':'length' if chunk=='TRUNCATE' else 'stop'}]})
        data=''.join('data: '+json.dumps(e)+'\n\n' for e in events)
        if chunk!='DROP': data+='data: [DONE]\n\n'
        data=data.encode()
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
with open(sys.argv[1],'w') as f: f.write(str(server.server_port))
server.serve_forever()
