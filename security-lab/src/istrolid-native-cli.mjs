import { resolve, dirname } from 'node:path';
import { mkdirSync, appendFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { startNativeServer } from './istrolid-native-server.mjs';
import { loadClientWords } from './istrolid-zjson.mjs';

const args=process.argv.slice(2);
const options={plugins:[]};let bundle=null;
for(let i=0;i<args.length;i++){
  if(args[i]==='--bundle')bundle=args[++i];
  else if(args[i]==='--port')options.port=Number(args[++i]);
  else if(args[i]==='--plugin')options.plugins.push(args[++i]);
  else throw Error('Unsupported option: '+args[i]);
}
if(!bundle)throw Error('Supply --bundle PATH pointing to locally extracted js/istrolid.cat.js');
if(!existsSync(bundle))throw Error('Missing original installed game bundle: '+bundle);
if(options.port!==undefined&&(!Number.isInteger(options.port)||options.port<1024||options.port>65535))throw Error('Port out of range');
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
options.pluginDirectory=resolve(root,'plugins');
options.words=loadClientWords(bundle);
const auditPath=resolve(root,'.build/native-audit.jsonl');
mkdirSync(dirname(auditPath),{recursive:true});
options.audit=event=>appendFileSync(auditPath,JSON.stringify(event)+'\n',{mode:0o600});
const server=await startNativeServer(options);
const address='127.0.0.1:'+server.address.port;
console.log('IstrolidR Native Test Server');
console.log('ZJson binary battle protocol: active (dictionary entries: '+options.words.length+')');
console.log('Original root JSON message shapes: active');
console.log('Server-owned gameKey handshake: active');
console.log('Authoritative combat / full original multiplayer: NOT IMPLEMENTED');
console.log('Root: ws://'+address+'/root');
console.log('Battle: ws://'+address+'/battle');
console.log('Local security plugins: '+(options.plugins.join(', ')||'none'));
console.log('Only loopback connections accepted; production Istrolid services are not contacted.');
console.log('Ctrl+C to stop.');
let closing=false;
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,async()=>{
  if(closing)return;closing=true;
  await server.close();process.exit(0);
});
