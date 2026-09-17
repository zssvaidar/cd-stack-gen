const http = require('http');

const PORT = process.env.PORT || 3000;
const SERVICE_NAME = 'node-app';

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', service: SERVICE_NAME }));
    return;
  }

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end(`Hello from ${SERVICE_NAME} (project-9 CD stack)\n`);
});

server.listen(PORT, () => {
  console.log(`${SERVICE_NAME} listening on :${PORT}`);
});
