// Istrolid 2023 client-compatible WebSocket TRANSPORT and lobby, not a full
// authoritative simulation. Only bind to loopback for security testing.
import { createServer } from 'node:http';
import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { IstrolidZJson } from './istrolid-zjson.mjs';
import { PluginHost, resolvePluginNames } from './plugins.mjs';

function equal(a,b) {
  if(typeof a!=='string'||typeof b!=='string')return false;
  const x=Buffer.from(a),y=Buffer.from(b);
  return x.length===y.length&&timingSafeEqual(x,y);
}
function json(ws,...args){if(ws.readyState===WebSocket.OPEN)ws.send(JSON.stringify(args));}
function validSide(side){return ['alpha','beta','spectators'].includes(side);}
function nick(name){return typeof name==='string'&&name.length>0&&name.length<=40&&/^[\w .-]+$/.test(name);}
const ARRAY_COMMANDS=new Set(['playerJoin','gameKey','switchSide','startGame','configGame',
  'playerEdit','moveOrder','followOrder','stopOrder','holdPositionOrder','selfDestructOrder',
  'setRallyPoint','mouseMove','playerSelected','buildRq','buildQ','kickPlayer','addAi']);
const SENSITIVE=new Set(['configGame','kickPlayer','addAi']);
export async function startNativeServer({
  words,host='127.0.0.1',port=8765,plugins=[],pluginDirectory, audit=()=>{}
}={}) {
  if(!['127.0.0.1','::1'].includes(host))throw Error('Native test server is loopback-only');
  if(!Array.isArray(words)||!words.includes('playerJoin'))throw Error('Client protocol dictionary required');
  const codec=new IstrolidZJson(words);
  const pluginPaths=plugins.length?resolvePluginNames(pluginDirectory,plugins):[];
  const hostPlugins=new PluginHost(pluginPaths);
  const roots=new Map(),clients=new Map();
  const record=(kind,session,code)=>{try{audit({kind,session:session?.id??null,code:code??null,time:new Date().toISOString()});}catch{}};
  const http=createServer((req,res)=>{
    if(req.url==='/health'){
      res.writeHead(200,{'content-type':'application/json','cache-control':'no-store'});
      res.end(JSON.stringify({service:'IstrolidR native test server',transport:'Istrolid ZJson',gameplay:'lobby only',clients:clients.size}));
    }else{res.writeHead(404);res.end();}
  });
  const wss=new WebSocketServer({noServer:true,maxPayload:256*1024,perMessageDeflate:false});
  http.on('upgrade',(req,socket,head)=>{
    const route=req.url;
    if(!['/root','/battle'].includes(route)||roots.size+clients.size>=24){
      socket.write('HTTP/1.1 503 Service Unavailable\r\n\r\n');socket.destroy();return;
    }
    wss.handleUpgrade(req,socket,head,ws=>wss.emit('connection',ws,route));
  });
  const allPlayers=()=>[...clients.values()].filter(s=>s.authenticated).map((s)=>[
    ['playerNumber',s.number],['name',s.name],['side',s.side],['afk',false],['host',s.number===0],
    ['money',2000],['connected',true],['color',s.color],['mouse',[0,0]],
    ['action',0],['buildQ',[]],['validBar',Array(10).fill(false)],['ai',false]
  ]);
  function snapshot(full=true){
    return {serverType:'sandbox',step:0,state:'waiting',fullUpdate:full,players:allPlayers(),things:[]};
  }
  function sendSnapshot(session){
    if(session.ws.readyState===WebSocket.OPEN){
      session.ws.send(codec.encode(snapshot()));
    }
  }
  function broadcast(){for(const s of clients.values())if(s.authenticated)sendSnapshot(s);}
  function serverList(){
    const address='ws://'+(host==='::1'?'[::1]':host)+':'+http.address().port+'/battle';
    return [{name:'IstrolidR Test Room',address,serverType:'sandbox',
      players:[...clients.values()].filter(x=>x.authenticated).map(x=>x.name),state:'waiting'}];
  }
  function notifyRoots(){for(const r of roots.values())json(r.ws,'servers',serverList());}
  let nextNumber=0;
  wss.on('connection',(ws,route)=>{
    const session={ws,id:randomUUID(),route,authenticated:false};
    record('connect',session,route);
    ws.on('error',()=>{});
    let frameCount=0,windowStart=Date.now();
    const timeout=setTimeout(()=>{if(!session.authenticated)ws.close(1008,'Authentication timeout');},10000);
    if(route==='/root'){
      const number=nextNumber++;
      session.id=number+1;session.name='LocalTester'+(number+1);
      session.key=randomBytes(20).toString('hex');
      session.authenticated=true;roots.set(session.key,session);
      // These are the real RootConnection message names and shapes.
      // Local temporary account data must never be sent to a production host.
      json(ws,'servers',serverList());
      json(ws,'gameKey',session.key);
      json(ws,'login',{id:session.id,name:session.name,color:[100,180,250,255],
        buildBar:Array(10).fill(''),fleet:{},challenges:{},galaxy:{},settings:{},friends:{},mutes:{}});
      clearTimeout(timeout);
    }else{
      session.number=-1;session.side='spectators';session.ws=ws;
      session.playerJoin=null;session.key=null;
      clients.set(ws,session);
    }
    ws.on('close',()=>{
      clearTimeout(timeout);
      if(route==='/root')roots.delete(session.key);
      else{clients.delete(ws);if(session.authenticated){broadcast();notifyRoots();}}
      record('close',session);
    });
    let task=Promise.resolve();
    async function handle(frame,isBinary){
      if(ws.readyState!==WebSocket.OPEN)return;
      if(route==='/root'){
        if(isBinary){ws.close(1003,'Expected root JSON');return;}
        let msg;
        try{msg=JSON.parse(frame.toString());}catch{ws.close(1007,'Invalid JSON');return;}
        if(!Array.isArray(msg)||typeof msg[0]!=='string'){ws.close(1008,'Invalid root command');return;}
        switch(msg[0]){
          case 'setMode':case 'ping':break;
          // Never accept original account tokens/passwords in a test service.
          case 'authSignIn':json(ws,'authError','Private test servers use local guest profiles');break;
          case 'savePlayer':break;
          default:record('root-ignored',session,msg[0]);
        }
        return;
      }
      if(!isBinary){ws.close(1003,'Expected Istrolid ZJson binary');return;}
      let msg;
      try{msg=codec.decode(frame);}catch{record('reject',session,'BAD_ZJSON');ws.close(1007,'Malformed ZJson');return;}
      if(!Array.isArray(msg)||msg.length===0||msg.length>10||typeof msg[0]!=='string'||
          !ARRAY_COMMANDS.has(msg[0])){record('reject',session,'BAD_COMMAND');ws.close(1008,'Invalid command');return;}
      const name=msg[0],args=msg.slice(1);
      if(name==='playerJoin'){
        if(args.length<6||args.length>7||!nick(args[2])||!Array.isArray(args[4])||args[4].length!==10){
          record('reject',session,'BAD_JOIN');ws.close(1008,'Invalid join');return;
        }
        session.playerJoin={id:args[1],name:args[2],color:args[3],buildBar:args[4]};
      }else if(name==='gameKey'){
        const [name,key]=args,root=roots.get(key);
        if(!root||!equal(root.key,key)||root.name!==name||!session.playerJoin||
            session.playerJoin.name!==name||session.playerJoin.id!==root.id){
          record('reject',session,'BAD_GAME_KEY');ws.close(1008,'Bad key');return;
        }
        if(session.authenticated){ws.close(1008,'Duplicate gameKey');return;}
        session.authenticated=true;session.name=name;session.side='spectators';
        session.number=[...clients.values()].filter(s=>s.authenticated&&s!==session).length;
        session.color=Array.isArray(session.playerJoin.color)&&session.playerJoin.color.length===4?
          session.playerJoin.color:[100,180,250,255];
        clearTimeout(timeout);record('join',session);
        broadcast();notifyRoots();
      }else{
        if(!session.authenticated){record('reject',session,'UNAUTHENTICATED');ws.close(1008,'Key required');return;}
        if(SENSITIVE.has(name)&&session.number!==0){record('reject',session,'NOT_HOST');return;}
        if(name==='switchSide'){
          if(args.length!==1||!validSide(args[0])){record('reject',session,'INVALID_SIDE');return;}
          session.side=args[0];broadcast();return;
        }
        if(name==='startGame'||name==='configGame'){
          // No authoritative simulation is wired up yet; do not fake an active game.
          record('not-implemented',session,name);return;
        }
        const decision=await hostPlugins.onCommand({session:{id:session.id,role:'player',joined:true},
          command:{name,args:structuredClone(args)}});
        if(!decision.allow){record('plugin-reject',session,decision.code);return;}
        record('accepted-transport-only',session,name);
      }
    }
    ws.on('message',(frame,binary)=>{
      const now=Date.now();if(now-windowStart>=1000){windowStart=now;frameCount=0;}
      if(++frameCount>30){ws.close(1008,'Rate limit');return;}
      task=task.then(()=>handle(frame,binary)).catch(()=>{record('failure',session);ws.close(1011,'Internal error');});
    });
  });
  try{
    await new Promise((resolve,reject)=>{http.once('error',reject);http.listen(port,host,resolve);});
  }catch(error){await hostPlugins.close();throw error;}
  return {address:http.address(),codec,
    async close(){for(const r of roots.values())r.ws.terminate();for(const c of clients.values())c.ws.terminate();
      await hostPlugins.close();await new Promise(resolve=>wss.close(resolve));
      await new Promise(resolve=>http.close(resolve));}
  };
}
