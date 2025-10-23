const http = require('http');
const WebSocket = require('ws');

const PORT = process.env.PORT || 8080;

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('WebSocket signaling server is running');
});

const wss = new WebSocket.Server({ server });

// rooms: roomName -> [clients]
const rooms = new Map();

function broadcastToRoom(roomName, fromClient, messageObj) {
  const peers = rooms.get(roomName) || [];
  for (const peer of peers) {
    if (peer !== fromClient && peer.readyState === WebSocket.OPEN) {
      peer.send(JSON.stringify(messageObj));
    }
  }
}

function getPeer(roomName, client) {
  const peers = rooms.get(roomName) || [];
  return peers.find(p => p !== client);
}

wss.on('connection', (ws) => {
  ws.id = Math.random().toString(36).slice(2);
  ws.room = null;
  ws.role = null; // 'caller' or 'callee'

  ws.on('message', (data) => {
    let msg;
    try {
      msg = JSON.parse(data);
    } catch (e) {
      console.error('Invalid JSON', e);
      return;
    }

    const { type } = msg;

    if (type === 'join') {
      const { room } = msg;
      if (!room) return;

      const peers = rooms.get(room) || [];
      rooms.set(room, peers);

      if (peers.length >= 2) {
        ws.send(JSON.stringify({ type: 'room_full', room }));
        return;
      }

      peers.push(ws);
      ws.room = room;
      ws.role = peers.length === 1 ? 'caller' : 'callee';

      ws.send(JSON.stringify({ type: 'joined', room, role: ws.role }));

      // notify existing peer someone joined
      broadcastToRoom(room, ws, { type: 'peer_joined', room });

      // When room has two participants, nudge caller to start negotiation
      if (peers.length === 2) {
        const caller = peers[0];
        if (caller && caller.readyState === WebSocket.OPEN) {
          caller.send(JSON.stringify({ type: 'start_negotiation', room }));
        }
      }
    }

    else if (type === 'signal') {
      const { room, payload } = msg;
      if (!room || !ws.room || ws.room !== room) return;
      // forward signaling payload to the other peer
      const other = getPeer(room, ws);
      if (other && other.readyState === WebSocket.OPEN) {
        other.send(JSON.stringify({ type: 'signal', payload }));
      }
    }

    else if (type === 'leave') {
      const { room } = msg;
      if (room && ws.room === room) {
        const peers = rooms.get(room) || [];
        rooms.set(room, peers.filter(p => p !== ws));
        broadcastToRoom(room, ws, { type: 'peer_left', room });
        ws.room = null;
        ws.role = null;
      }
    }
  });

  ws.on('close', () => {
    if (ws.room) {
      const peers = rooms.get(ws.room) || [];
      rooms.set(ws.room, peers.filter(p => p !== ws));
      broadcastToRoom(ws.room, ws, { type: 'peer_left', room: ws.room });
    }
  });
});

server.listen(PORT, () => {
  console.log(`Signaling server listening on http://localhost:${PORT}`);
});