const http = require('http');

const PORT = process.env.PORT || 3000;

const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Nigerian National Anthem</title>
  <style>
    body {
      font-family: Georgia, serif;
      background-color: #f5f5f0;
      color: #1a1a1a;
      display: flex;
      justify-content: center;
      align-items: center;
      height: 100vh;
      margin: 0;
    }
    .anthem-card {
      background: #ffffff;
      border-top: 6px solid #008751;
      border-bottom: 6px solid #008751;
      padding: 40px 50px;
      max-width: 480px;
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
      text-align: center;
    }
    h1 {
      font-size: 1.4rem;
      margin-bottom: 5px;
      color: #008751;
    }
    h2 {
      font-size: 1rem;
      font-weight: normal;
      color: #555;
      margin-top: 0;
      margin-bottom: 25px;
    }
    p {
      font-size: 1.2rem;
      line-height: 1.9;
      margin: 0;
    }
  </style>
</head>
<body>
  <div class="anthem-card">
    <h1>National Anthem of Nigeria</h1>
    <h2>"Nigeria, We Hail Thee" &mdash; First Stanza</h2>
    <p>
      Nigeria, we hail thee,<br>
      Our own dear native land,<br>
      Though tribes and tongues may differ,<br>
      In brotherhood, we stand,<br>
      Nigerians all, are proud to serve<br>
      Our sovereign Motherland.
    </p>
  </div>
</body>
</html>`;

const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Content-Security-Policy': "default-src 'self'; style-src 'unsafe-inline'",
  'Referrer-Policy': 'no-referrer',
  'Permissions-Policy': 'geolocation=(), camera=(), microphone=()',
  'Strict-Transport-Security': 'max-age=63072000; includeSubDomains'
};

const server = http.createServer((req, res) => {
  // Only GET/HEAD are meaningful for this app; reject everything else outright.
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { 'Content-Type': 'text/plain', ...SECURITY_HEADERS });
    res.end('Method Not Allowed');
    return;
  }

  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'text/plain', ...SECURITY_HEADERS });
    res.end('OK');
    return;
  }

  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', ...SECURITY_HEADERS });
  res.end(req.method === 'HEAD' ? undefined : html);
});

// Mitigate slow-request (Slowloris-style) connection exhaustion.
server.headersTimeout = 20_000;
server.requestTimeout = 20_000;
server.keepAliveTimeout = 5_000;

// Don't let an unexpected error take the whole process down silently.
server.on('error', (err) => {
  console.error('Server error:', err);
});

server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
