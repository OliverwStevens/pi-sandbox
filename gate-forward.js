// Minimal TCP forwarder: gate-forward.js <listenPort> <targetHost> <targetPort>
// The only path from the sandbox network to the outside: one host:port, nothing else.
const net = require('net');
const [listenPort, host, port] = process.argv.slice(2);
net.createServer((client) => {
  const upstream = net.connect(Number(port), host);
  const close = () => { client.destroy(); upstream.destroy(); };
  client.on('error', close); upstream.on('error', close);
  client.on('close', close); upstream.on('close', close);
  client.pipe(upstream).pipe(client);
}).listen(Number(listenPort), '0.0.0.0');
