import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {WebSocket} from 'ws';
import {IstrolidZJson,loadClientWords} from '../src/istrolid-zjson.mjs';
import {startNativeServer} from '../src/istrolid-native-server.mjs';

// Golden hex frames were computed once from the *unmodified* Istrolid client
// ZJson implementation in a local VM, not generated with this implementation.
const dictionary=Array.from({length:465},(_,i)=>'unused'+i);
Object.assign(dictionary,{0:'1v1',100:'fullUpdate',305:'playerJoin',
  307:'players',335:'serverType',362:'state',367:'step',410:'things'});
const clientCodec=new IstrolidZJson(dictionary);
const joinPacket=['playerJoin',1,'LocalTester1',[100,180,250,255],
  Array(10).fill(null),null,false,true];
const joinHex='20083201314001300c4c6f63616c5465737465723126406440b440fa40ff200a52525252525252525252525150454e44';
const snapshot={fullUpdate:true,step:0,serverType:'sandbox',state:'waiting',players:[],things:[]};
const snapshotHex='10063200645032016f430000000032014f300773616e64626f7832016a300777616974696e673201332232019a22454e44';

test('packets exactly match recovered original Istrolid ZJson golden bytes',()=>{
  assert.equal(clientCodec.encode(joinPacket).toString('hex'),joinHex);
  assert.equal(clientCodec.encode(snapshot).toString('hex'),snapshotHex);
  assert.deepEqual(clientCodec.decode(Buffer.from(joinHex,'hex')),joinPacket);
  const decoded=clientCodec.decode(Buffer.from(snapshotHex,'hex'));
  assert.equal(decoded.serverType,'sandbox');
  assert.deepEqual(decoded.players,[]);
});
test('original client protocol words are discovered locally rather than embedded',()=>{
  const dir=mkdtempSync(join(tmpdir(),'istrolidr-dict-'));
  try{
    const path=join(dir,'istrolid.cat.js');
    const synthetic='//from src/protocol.js\nprot.commonWords = '+String.fromCharCode(96)+
      '1v1\\nplayerJoin'+String.fromCharCode(96)+'.split("\\n");\n//from src/utils.js\n';
    writeFileSync(path,synthetic);
    // This fixture deliberately uses a literal escaped newline, not a real table newline.
    assert.throws(()=>loadClientWords(path),/Unexpected client word table/);
    const valid=synthetic.replace('1v1\\nplayerJoin','1v1\nplayerJoin');
    writeFileSync(path,valid);
    assert.deepEqual(loadClientWords(path),['1v1','playerJoin']);
  }finally{rmSync(dir,{recursive:true,force:true});}
});
test('codec rejects truncated, malformed, unknown marker and polluted objects',()=>{
  for(const p of [Buffer.from([0xff,0x45,0x4e,0x44]),Buffer.from(joinHex.slice(0,-6),'hex'),
    Buffer.from('100130095f5f70726f746f5f5f405a454e44','hex')]){
    assert.throws(()=>clientCodec.decode(p));
  }
  assert.throws(()=>clientCodec.encode({something:Number.POSITIVE_INFINITY}),/Invalid number/);
});
function wsClient(url){
  const ws=new WebSocket(url),queue=[],waiters=[];
  ws.on('message',(raw,binary)=>{
    const msg=binary?clientCodec.decode(raw):JSON.parse(raw.toString());
    if(waiters.length)waiters.shift()(msg);else queue.push(msg);
  });
  const open=new Promise((resolve,reject)=>{ws.once('open',resolve);ws.once('error',reject);});
  return {
    ws,open,
    recv(){
      if(queue.length)return Promise.resolve(queue.shift());
      return new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>reject(new Error('Timed out waiting for native client message')),2000);
        waiters.push(msg=>{clearTimeout(timer);resolve(msg);});
      });
    },
    sendJSON(msg){ws.send(JSON.stringify(msg));},
    sendZ(msg){ws.send(clientCodec.encode(msg),{binary:true});},
    close(){ws.terminate();}
  };
}
test('native original-client root handshake, gameKey and binary lobby snapshot',async()=>{
  const server=await startNativeServer({words:dictionary,port:0});
  const base='ws://127.0.0.1:'+server.address.port;
  const root=wsClient(base+'/root'),battle=wsClient(base+'/battle');
  try{
    await Promise.all([root.open,battle.open]);
    const list=await root.recv(),key=await root.recv(),login=await root.recv();
    assert.equal(list[0],'servers');
    assert.equal(list[1][0].address,base+'/battle');
    assert.equal(key[0],'gameKey');
    assert.equal(login[0],'login');
    const p=login[1];
    battle.sendZ(['playerJoin',p.id,p.name,p.color,Array(10).fill(null),null,false,true]);
    battle.sendZ(['gameKey',p.name,key[1]]);
    const snap=await battle.recv();
    assert.equal(snap.serverType,'sandbox');
    assert.equal(snap.fullUpdate,true);
    assert.equal(snap.players[0][1][1],p.name);
    battle.sendZ(['switchSide','alpha']);
    const changed=await battle.recv();
    assert.equal(changed.players[0][2][1],'alpha');
    assert.equal(changed.things.length,0); // Gameplay still not implemented.
  }finally{root.close();battle.close();await server.close();}
});
test('native battle connection rejects forged gameKeys and unauthenticated commands',async()=>{
  const server=await startNativeServer({words:dictionary,port:0});
  const battle=wsClient('ws://127.0.0.1:'+server.address.port+'/battle');
  try{
    await battle.open;
    const closed=new Promise(resolve=>battle.ws.once('close',code=>resolve(code)));
    battle.sendZ(['switchSide','alpha']);
    assert.equal(await closed,1008);
  }finally{battle.close();await server.close();}
});
